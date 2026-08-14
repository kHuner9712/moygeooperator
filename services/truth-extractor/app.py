# ============================================================================
# MOY GEO Operator · truth-extractor service (P0.2)
# A small, self-hosted, sidecar HTTP service that turns real client inputs
# (PDF files, URLs/web pages) into extractable text for WF-01 Truth intake.
#
# It is deliberately NOT part of the `default` compose profile — it is started
# with the `tooling` profile, exactly like SearXNG / Crawl4AI. Every extraction
# is deterministic and fail-closed:
#   - PDF  -> parse embedded text (scanned PDFs -> 422 PARSE_FAILED; the caller
#             routes to MANUAL_EXTRACTION_REQUIRED)
#   - URL  -> fetch + extract readable text/markdown (non-200 -> 422)
# It NEVER fabricates content. Output contract:
#   { "text": "...", "parser": "PDF|WEBPAGE|TXT|CSV", "checksum": "<sha256>",
#     "source_uri": "...", "chars": N }
#
# Runs unprivileged, no internet egress beyond the target URL (URL mode).
# ============================================================================
import hashlib
import io
import json
import re
import urllib.parse

import requests
from bs4 import BeautifulSoup
from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from pypdf import PdfReader

app = FastAPI(title="geo-operator truth-extractor", version="1.0.0")

# Hard cap on extracted bytes to keep the pipeline bounded and cheap.
MAX_TEXT_CHARS = 200_000


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


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


# ---------------------------------------------------------------------------
# PDF — extract real embedded text. Scanned/image-only PDFs -> 422 PARSE_FAILED.
# ---------------------------------------------------------------------------
@app.post("/extract/pdf")
async def extract_pdf(file: UploadFile = File(...)):
    raw = await file.read()
    if not raw:
        raise HTTPException(status_code=422, detail="PARSE_FAILED: empty pdf")
    try:
        reader = PdfReader(io.BytesIO(raw))
        pages = []
        for page in reader.pages:
            pages.append(page.extract_text() or "")
        text = "\n".join(pages)
    except Exception as exc:  # any parse failure fails closed
        raise HTTPException(status_code=422, detail=f"PARSE_FAILED: {exc}")
    return JSONResponse(_ok(text, "PDF", file.filename, raw))


# ---------------------------------------------------------------------------
# URL / WEBPAGE — fetch and extract readable text (delegates markdown to the
# caller; we hand back clean text). Non-200 or unreadable -> 422 PARSE_FAILED.
# ---------------------------------------------------------------------------
class UrlRequest(BaseModel):
    url: str


@app.post("/extract/url")
def extract_url(req: UrlRequest):
    url = req.url.strip()
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in ("http", "https"):
        raise HTTPException(status_code=422, detail="PARSE_FAILED: unsupported scheme")
    try:
        resp = requests.get(url, timeout=25, headers={"User-Agent": "geo-operator/truth-extractor"})
    except Exception as exc:
        raise HTTPException(status_code=422, detail=f"PARSE_FAILED: fetch error {exc}")
    if resp.status_code != 200:
        raise HTTPException(status_code=422, detail=f"PARSE_FAILED: http {resp.status_code}")
    ctype = resp.headers.get("content-type", "").lower()
    # A URL pointing at a PDF is parsed as a PDF (uniform extraction for WF-01).
    if "pdf" in ctype or resp.content[:4] == b"%PDF":
        try:
            reader = PdfReader(io.BytesIO(resp.content))
            text = "\n".join((p.extract_text() or "") for p in reader.pages)
        except Exception as exc:
            raise HTTPException(status_code=422, detail=f"PARSE_FAILED: {exc}")
        return JSONResponse(_ok(text, "PDF", url, resp.content))
    if "html" in ctype or "<html" in resp.text[:2000].lower():
        soup = BeautifulSoup(resp.content, "html.parser")
        for tag in soup(["script", "style", "noscript", "header", "footer", "nav"]):
            tag.decompose()
        title = soup.title.get_text(strip=True) if soup.title else ""
        body = soup.get_text(separator="\n")
        text = (title + "\n\n" + body) if title else body
        text = re.sub(r"\n{3,}", "\n\n", text)
        parser = "WEBPAGE"
    else:
        text = resp.text
        parser = "URL"
    return JSONResponse(_ok(text, parser, url, resp.content))