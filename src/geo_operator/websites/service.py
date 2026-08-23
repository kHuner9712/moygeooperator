from __future__ import annotations

import hashlib
import ipaddress
import socket
import uuid
from collections import deque
from typing import Any
from urllib.parse import urldefrag, urljoin, urlsplit, urlunsplit

import httpx
from bs4 import BeautifulSoup

from geo_operator.core.db import Database
from geo_operator.core.storage import ArtifactStore
from geo_operator.core.time import utc_now


_PROXY_FAKE_IPV4_NETWORK = ipaddress.ip_network("198.18.0.0/15")


def _is_proxy_fake_ip(ip: ipaddress.IPv4Address | ipaddress.IPv6Address) -> bool:
    """Return whether an address is a proxy fake-IP placeholder rather than a real target."""
    if isinstance(ip, ipaddress.IPv6Address):
        mapped = ip.ipv4_mapped
        if mapped is None:
            return False
        ip = mapped
    return ip in _PROXY_FAKE_IPV4_NETWORK


def validate_public_url(url: str) -> str:
    parsed = urlsplit(url)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise ValueError("URL must be an absolute HTTP(S) URL")
    if parsed.username or parsed.password:
        raise ValueError("URL credentials are not allowed")

    # Reject non-public literal IP URLs unconditionally. This keeps direct access to
    # localhost/private/link-local/reserved targets blocked even when a proxy is present.
    try:
        literal_ip = ipaddress.ip_address(parsed.hostname)
    except ValueError:
        literal_ip = None
    if literal_ip is not None:
        if not literal_ip.is_global:
            raise ValueError("Private, local, reserved, or non-global addresses are not allowed")
        return urlunsplit(parsed._replace(fragment=""))

    try:
        addresses = {item[4][0] for item in socket.getaddrinfo(parsed.hostname, parsed.port)}
    except OSError as exc:
        raise ValueError("URL hostname could not be resolved") from exc
    for address in addresses:
        ip = ipaddress.ip_address(address)
        if ip.is_global:
            continue
        # Clash/Mihomo fake-IP mode commonly maps ordinary public hostnames into the
        # RFC 2544 benchmarking range. The local proxy intercepts these placeholders
        # and forwards the request to the real public destination. Only permit this
        # exception for DNS results; a literal 198.18.0.0/15 URL remains blocked above.
        if _is_proxy_fake_ip(ip):
            continue
        raise ValueError("Private, local, reserved, or non-global addresses are not allowed")
    return urlunsplit(parsed._replace(fragment=""))


class WebsiteCrawlerService:
    MAX_PAGE_BYTES = 2 * 1024 * 1024
    MAX_PAGES = 50

    def __init__(self, database: Database, artifacts: ArtifactStore) -> None:
        self.database, self.artifacts = database, artifacts

    async def crawl(
        self,
        tenant_id: str,
        start_url: str,
        max_pages: int = 20,
        client: httpx.AsyncClient | None = None,
    ) -> dict[str, Any]:
        if not self.database.one(
            "SELECT id FROM tenants WHERE id=? AND status='ACTIVE'", (tenant_id,)
        ):
            raise KeyError("Tenant not found")
        start_url = validate_public_url(start_url)
        if not 1 <= max_pages <= self.MAX_PAGES:
            raise ValueError(f"max_pages must be between 1 and {self.MAX_PAGES}")
        crawl_id = uuid.uuid4().hex
        origin = self._origin(start_url)
        queue: deque[str] = deque([start_url])
        visited: set[str] = set()
        owns_client = client is None
        active_client = client or httpx.AsyncClient(
            follow_redirects=True,
            timeout=httpx.Timeout(20.0),
            headers={"User-Agent": "GEO-Operator-V2-Evidence-Crawler/1.0"},
        )
        try:
            while queue and len(visited) < max_pages:
                url = queue.popleft()
                if url in visited:
                    continue
                visited.add(url)
                page = await self._capture_page(active_client, tenant_id, crawl_id, url)
                if page["status"] == "COLLECTED":
                    for link in page.pop("links"):
                        if link not in visited and self._origin(link) == origin:
                            queue.append(link)
                else:
                    page.pop("links", None)
        finally:
            if owns_client:
                await active_client.aclose()
        pages = self.list(tenant_id, crawl_id)
        return {
            "crawl_id": crawl_id,
            "tenant_id": tenant_id,
            "start_url": start_url,
            "requested_max_pages": max_pages,
            "collected": sum(page["status"] == "COLLECTED" for page in pages),
            "failed": sum(page["status"] == "FAILED" for page in pages),
            "pages": pages,
        }

    def list(self, tenant_id: str, crawl_id: str | None = None) -> list[dict[str, Any]]:
        if crawl_id:
            return self.database.all(
                """SELECT * FROM website_pages WHERE tenant_id=? AND crawl_id=?
                   ORDER BY captured_at,id""",
                (tenant_id, crawl_id),
            )
        return self.database.all(
            "SELECT * FROM website_pages WHERE tenant_id=? ORDER BY captured_at,id", (tenant_id,)
        )

    async def _capture_page(
        self, client: httpx.AsyncClient, tenant_id: str, crawl_id: str, url: str
    ) -> dict[str, Any]:
        page_id, captured_at = uuid.uuid4().hex, utc_now()
        try:
            validate_public_url(url)
            response = await client.get(url)
            for redirect in [*response.history, response]:
                validate_public_url(str(redirect.url))
            response.raise_for_status()
            content_type = response.headers.get("content-type", "").lower()
            if "text/html" not in content_type:
                raise ValueError("Only HTML website pages are collected")
            content = response.content
            if len(content) > self.MAX_PAGE_BYTES:
                raise ValueError("Website page exceeds the 2 MiB limit")
            soup = BeautifulSoup(content, "html.parser")
            title = soup.title.get_text(" ", strip=True) if soup.title else ""
            links = self._links(soup, str(response.url))
            for node in soup(["script", "style", "noscript", "template"]):
                node.decompose()
            text = "\n".join(
                line.strip() for line in soup.get_text("\n").splitlines() if line.strip()
            )
            text_bytes = text.encode("utf-8")
            text_path = f"website/text/{page_id}.txt"
            self.artifacts.atomic_write(tenant_id, text_path, text_bytes)
            final_url = str(response.url)
            content_hash = hashlib.sha256(text_bytes).hexdigest()
            status, error = "COLLECTED", None
        except (OSError, ValueError, httpx.HTTPError) as exc:
            final_url, title, text_path, content_hash, links = None, None, None, None, []
            status, error = "FAILED", f"{type(exc).__name__}: {exc}"[:1000]
        with self.database.transaction() as connection:
            connection.execute(
                """INSERT INTO website_pages(
                   id,tenant_id,crawl_id,source_url,final_url,title,text_path,
                   content_sha256,status,error,captured_at)
                   VALUES (?,?,?,?,?,?,?,?,?,?,?)""",
                (
                    page_id,
                    tenant_id,
                    crawl_id,
                    url,
                    final_url,
                    title,
                    text_path,
                    content_hash,
                    status,
                    error,
                    captured_at,
                ),
            )
        return {"id": page_id, "status": status, "links": links}

    @staticmethod
    def _origin(url: str) -> tuple[str, str, int | None]:
        parsed = urlsplit(url)
        return parsed.scheme.lower(), (parsed.hostname or "").lower(), parsed.port

    @staticmethod
    def _links(soup: BeautifulSoup, base_url: str) -> list[str]:
        links: list[str] = []
        for anchor in soup.select("a[href]"):
            candidate, _ = urldefrag(urljoin(base_url, str(anchor.get("href"))))
            parsed = urlsplit(candidate)
            if parsed.scheme in {"http", "https"} and parsed.hostname:
                links.append(candidate)
        return list(dict.fromkeys(links))
