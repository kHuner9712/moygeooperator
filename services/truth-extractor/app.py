# ============================================================================
# MOY GEO Operator · truth-extractor service (P0.2 / P0.9 / P0.10 / P0.11 / P0.12)
# A small, self-hosted, sidecar HTTP service that turns real client inputs
# (PDF files, URLs/web pages) into extractable text for WF-01 Truth intake.
#
# Security posture (Shadow Gate hotfix):
#   P0.9+P0.10  Local file intake is CLIENT-SCOPED. A file may only be extracted
#               from <TRUTH_ROOT>/<client_id>/ and must resolve to a real file
#               under that namespace (path-traversal / absolute-outside-root /
#               symlink-escape / other-client-directory are all rejected).
#   P0.11       URL extraction is SSRF-guarded: DNS is resolved to the final IP
#               and every redirect hop is re-validated. Private / loopback /
#               link-local / multicast / reserved / unspecified / Docker-internal
#               addresses (incl. 169.254.169.254 and IPv6 equivalents) are blocked.
#   P0.12       URL bodies are downloaded with stream=True under a hard byte cap
#               (MAX_RESPONSE_BYTES), with timeouts, a max-redirect cap, and an
#               allow-list of content types (text/html, text/plain, application/pdf).
#
# It is deliberately NOT part of the `default` compose profile — it is started
# with the `tooling` profile, exactly like SearXNG / Crawl4AI. Every extraction
# is deterministic and fail-closed: scanned/image-only PDFs -> 422 PARSE_FAILED.
# It NEVER fabricates content. Output contract:
#   { "text": "...", "parser": "PDF|WEBPAGE|TXT|CSV", "checksum": "<sha256>",
#     "source_uri": "...", "chars": N }
# ============================================================================
import hashlib
import io
import ipaddress
import os
import re
import socket
import urllib.parse
from pathlib import Path

import requests
from bs4 import BeautifulSoup
from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from pypdf import PdfReader

app = FastAPI(title="geo-operator truth-extractor", version="2.0.0")

# --- configuration (env-overridable, bounded by default) --------------------
MAX_TEXT_CHARS = int(os.environ.get("MAX_TEXT_CHARS", "200000"))
MAX_RESPONSE_BYTES = int(os.environ.get("MAX_RESPONSE_BYTES", str(10 * 1024 * 1024)))  # 10 MB
REQUEST_TIMEOUT = int(os.environ.get("REQUEST_TIMEOUT", "25"))  # seconds
MAX_REDIRECTS = int(os.environ.get("MAX_REDIRECTS", "5"))
TRUTH_ROOT = os.environ.get("TRUTH_ROOT", "/data/truth").rstrip("/")
# Allow-list of content types we will download/extract in URL mode.
ALLOWED_CONTENT_TYPES = ("text/html", "text/plain", "application/pdf")


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _ok(text: str, parser: str, source_uri: str | None, raw: bytes) -> dict:
    text = (text or "").strip()
    if not text:
        raise HTTPException(status_code=422, detail="PARSE_FAILED: empty content")
    if len(text) > MAX_TEXT_CHARS:
        text = text[:MAX_TEXT_CHARS]
    return {
        "text": text,
        "parser": parser,
        "checksum": _sha256(raw) if raw else _sha256(text.encode("utf-8")),
        "source_uri": source_uri,
        "chars": len(text),
        "ok": True,
    }


# ============================================================================
# P0.10 — client-scoped file path resolution
# ============================================================================
def _resolve_client_path(client_id: str, rel_path: str) -> Path:
    """Resolve rel_path under TRUTH_ROOT/<client_id>/ and FAIL CLOSED on any
    traversal / absolute-outside-root / symlink-escape / other-client path."""
    if not client_id or not client_id.strip():
        raise HTTPException(status_code=422, detail="CLIENT_DATA_REQUIRED: client_id required")
    if not rel_path or not rel_path.strip():
        raise HTTPException(status_code=422, detail="CLIENT_DATA_REQUIRED: file path required")
    # Reject absolute paths outright (must be relative to the client namespace).
    p = Path(rel_path)
    if p.is_absolute():
        raise HTTPException(status_code=422, detail="RESOURCE_LIMIT_EXCEEDED: absolute path not allowed")
    client_dir = (Path(TRUTH_ROOT) / client_id).resolve()
    target = (client_dir / p).resolve()
    # 1) Must stay inside the client namespace.
    if not target.is_relative_to(client_dir):
        raise HTTPException(status_code=422, detail="RESOURCE_LIMIT_EXCEEDED: path escapes client namespace")
    # 2) Must be an existing regular file (symlink escape is caught by resolve() + is_relative_to).
    if not target.is_file():
        raise HTTPException(status_code=422, detail="PARSE_FAILED: file not found in client namespace")
    return target


def _extract_pdf_bytes(raw: bytes, filename: str, source_uri: str | None) -> dict:
    if not raw:
        raise HTTPException(status_code=422, detail="PARSE_FAILED: empty pdf")
    try:
        reader = PdfReader(io.BytesIO(raw))
        text = "\n".join((page.extract_text() or "") for page in reader.pages)
    except Exception as exc:  # any parse failure fails closed
        raise HTTPException(status_code=422, detail=f"PARSE_FAILED: {exc}")
    return _ok(text, "PDF", source_uri, raw)


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


# ---------------------------------------------------------------------------
# P0.9 — PDF file upload (raw bytes) — unchanged path for direct uploads.
# ---------------------------------------------------------------------------
@app.post("/extract/pdf")
async def extract_pdf(file: UploadFile = File(...)):
    raw = await file.read()
    return JSONResponse(_extract_pdf_bytes(raw, file.filename or "upload.pdf", file.filename))


# ---------------------------------------------------------------------------
# P0.9+P0.10 — CLIENT-SCOPED local file intake from the truth ingestion volume.
# Body: { "client_id": "...", "path": "<relative path under TRUTH_ROOT/<client_id>/>" }
# Only the client's own namespace is reachable; any traversal is rejected.
# ---------------------------------------------------------------------------
class FilePathRequest(BaseModel):
    client_id: str
    path: str


@app.post("/extract/file")
def extract_file(req: FilePathRequest):
    target = _resolve_client_path(req.client_id, req.path)
    raw = target.read_bytes()
    if len(raw) > MAX_RESPONSE_BYTES:
        raise HTTPException(status_code=422, detail="RESOURCE_LIMIT_EXCEEDED: file too large")
    # source_uri echoes the CLIENT-RELATIVE path so WF-01 can re-key the merge
    # against truth_documents.file_path (the absolute path is internal only).
    return JSONResponse(_extract_pdf_bytes(raw, target.name, req.path))


# ============================================================================
# P0.11 — SSRF guard
# ============================================================================
def _ip_is_blocked(ip: str) -> bool:
    try:
        addr = ipaddress.ip_address(ip.split("%")[0])
    except ValueError:
        return True  # unparseable -> block
    # Unwrap IPv4-mapped IPv6 (::ffff:a.b.c.d) so the IPv4 rules apply.
    if addr.version == 6 and addr.ipv4_mapped is not None:
        addr = addr.ipv4_mapped
    if addr.version == 4:
        return (
            addr.is_private
            or addr.is_loopback
            or addr.is_link_local
            or addr.is_multicast
            or addr.is_reserved
            or addr.is_unspecified
            or not addr.is_global  # covers 100.64/10 CGNAT, 192.0.2, 198.51.100, 203.0.113, etc.
        )
    # IPv6
    return (
        addr.is_private          # fc00::/7 ULA
        or addr.is_loopback      # ::1
        or addr.is_link_local    # fe80::/10
        or addr.is_multicast     # ff00::/8
        or addr.is_reserved
        or addr.is_unspecified
        or addr.is_site_local
        or not addr.is_global
    )


def _assert_public_url(url: str) -> None:
    """Resolve the hostname to its final IPs and reject any private/loopback/
    link-local/multicast/reserved address (the cloud-metadata 169.254.169.254 is
    inside link-local / reserved and therefore blocked)."""
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in ("http", "https"):
        raise HTTPException(status_code=422, detail="PARSE_FAILED: unsupported scheme")
    host = parsed.hostname
    if not host:
        raise HTTPException(status_code=422, detail="PARSE_FAILED: no host")
    if host.lower() in ("localhost", "localhost."):
        raise HTTPException(status_code=422, detail="PARSE_FAILED: SSRF: localhost blocked")
    try:
        infos = socket.getaddrinfo(host, None, type=socket.SOCK_STREAM)
    except Exception as exc:
        raise HTTPException(status_code=422, detail=f"PARSE_FAILED: dns error {exc}")
    ips = {info[4][0] for info in infos}
    if not ips:
        raise HTTPException(status_code=422, detail="PARSE_FAILED: dns returned no addresses")
    for ip in ips:
        if _ip_is_blocked(ip):
            raise HTTPException(
                status_code=422,
                detail=f"PARSE_FAILED: SSRF blocked (host {host} resolves to {ip})",
            )


class UrlRequest(BaseModel):
    url: str


# ---------------------------------------------------------------------------
# P0.11+P0.12 — URL extraction with SSRF guard + streamed, size-capped download.
# Redirects are followed manually, re-validating each hop.
# ---------------------------------------------------------------------------
@app.post("/extract/url")
def extract_url(req: UrlRequest):
    url = req.url.strip()
    _assert_public_url(url)
    session = requests.Session()
    session.max_redirects = MAX_REDIRECTS
    current = url
    content = b""
    ctype = ""
    for _ in range(MAX_REDIRECTS + 1):
        _assert_public_url(current)
        try:
            # stream the body so we can enforce the byte cap without buffering it all.
            with session.get(
                current,
                timeout=REQUEST_TIMEOUT,
                allow_redirects=False,
                stream=True,
                headers={"User-Agent": "geo-operator/truth-extractor"},
            ) as resp:
                if resp.status_code in (301, 302, 303, 307, 308):
                    loc = resp.headers.get("location")
                    if not loc:
                        raise HTTPException(status_code=422, detail="PARSE_FAILED: redirect without location")
                    current = urllib.parse.urljoin(current, loc)
                    continue
                if resp.status_code != 200:
                    raise HTTPException(status_code=422, detail=f"PARSE_FAILED: http {resp.status_code}")
                ctype = resp.headers.get("content-type", "").lower().split(";")[0].strip()
                if ctype and ctype not in ALLOWED_CONTENT_TYPES:
                    raise HTTPException(status_code=422, detail=f"RESOURCE_LIMIT_EXCEEDED: content-type {ctype} not allowed")
                for chunk in resp.iter_content(chunk_size=65536):
                    content += chunk
                    if len(content) > MAX_RESPONSE_BYTES:
                        raise HTTPException(status_code=422, detail="RESOURCE_LIMIT_EXCEEDED: response exceeds byte cap")
                break
        except HTTPException:
            raise
        except Exception as exc:
            raise HTTPException(status_code=422, detail=f"PARSE_FAILED: fetch error {exc}")
    else:
        raise HTTPException(status_code=422, detail="PARSE_FAILED: too many redirects")

    # A URL pointing at a PDF is parsed as a PDF (uniform extraction for WF-01).
    if "pdf" in ctype or content[:4] == b"%PDF":
        return JSONResponse(_extract_pdf_bytes(content, "url-doc.pdf", current))
    if "html" in ctype or b"<html" in content[:2000].lower() or b"<!doctype" in content[:2000].lower():
        soup = BeautifulSoup(content, "html.parser")
        for tag in soup(["script", "style", "noscript", "header", "footer", "nav"]):
            tag.decompose()
        title = soup.title.get_text(strip=True) if soup.title else ""
        body = soup.get_text(separator="\n")
        text = (title + "\n\n" + body) if title else body
        text = re.sub(r"\n{3,}", "\n\n", text)
        parser = "WEBPAGE"
    else:
        try:
            text = content.decode("utf-8", errors="replace")
        except Exception:
            text = ""
        parser = "URL"
    return JSONResponse(_ok(text, parser, current, content))