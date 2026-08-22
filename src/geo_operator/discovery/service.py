from __future__ import annotations

import hashlib
import json
import os
import tempfile
import uuid
import zipfile
from pathlib import Path
from urllib.parse import urlparse

import httpx
from bs4 import BeautifulSoup
from playwright.async_api import async_playwright

from geo_operator.core.db import Database
from geo_operator.core.storage import ArtifactStore
from geo_operator.core.time import utc_now
from geo_operator.websites import validate_public_url


class PublicDiscoveryService:
    def __init__(self, database: Database, artifacts: ArtifactStore) -> None:
        self.database, self.artifacts = database, artifacts

    def collect(
        self,
        tenant_id: str,
        source_url: str,
        raw_text: str,
        screenshot: bytes,
        source_type: str,
        captured_at: str | None = None,
    ) -> dict[str, object]:
        parsed = urlparse(source_url)
        if parsed.scheme not in {"http", "https"} or not parsed.netloc:
            raise ValueError("source_url must be an absolute HTTP(S) URL")
        if not raw_text.strip() or not screenshot or not source_type.strip():
            raise ValueError("raw_text, screenshot and source_type are required")
        evidence_id = uuid.uuid4().hex
        text_rel = f"discovery/text/{evidence_id}.txt"
        shot_rel = f"discovery/screenshots/{evidence_id}.png"
        _, text_hash = self.artifacts.atomic_write(tenant_id, text_rel, raw_text.encode("utf-8"))
        _, shot_hash = self.artifacts.atomic_write(tenant_id, shot_rel, screenshot)
        with self.database.transaction() as connection:
            connection.execute(
                """INSERT INTO discovery_evidence(
                   id,tenant_id,source_url,captured_at,raw_text_path,screenshot_path,
                   source_type,credibility_status,content_sha256,screenshot_sha256,
                   collection_status,created_at)
                   VALUES (?,?,?,?,?,?,?,'AI_PENDING',?,?,'COLLECTED',?)""",
                (
                    evidence_id,
                    tenant_id,
                    source_url,
                    captured_at or utc_now(),
                    text_rel,
                    shot_rel,
                    source_type.strip(),
                    text_hash,
                    shot_hash,
                    utc_now(),
                ),
            )
        return self.get(evidence_id)

    async def collect_url(
        self,
        tenant_id: str,
        source_url: str,
        source_type: str,
        client: httpx.AsyncClient | None = None,
    ) -> dict[str, object]:
        if not self.database.one("SELECT id FROM tenants WHERE id=?", (tenant_id,)):
            raise KeyError("Tenant not found")
        source_url = validate_public_url(source_url)
        owns_client = client is None
        active_client = client or httpx.AsyncClient(
            follow_redirects=True,
            timeout=httpx.Timeout(20.0),
            headers={"User-Agent": "GEO-Operator-V2-Evidence-Collector/1.0"},
        )
        try:
            response = await active_client.get(source_url)
            for redirect in [*response.history, response]:
                validate_public_url(str(redirect.url))
            response.raise_for_status()
            if len(response.content) > 2 * 1024 * 1024:
                raise ValueError("Discovery source exceeds the 2 MiB limit")
            content_type = response.headers.get("content-type", "").lower()
            if "text/html" not in content_type:
                raise ValueError("Discovery URL must return an HTML page")
            soup = BeautifulSoup(response.content, "html.parser")
            for node in soup(["script", "style", "noscript", "template"]):
                node.decompose()
            raw_text = "\n".join(
                line.strip() for line in soup.get_text("\n").splitlines() if line.strip()
            )
            if not raw_text:
                raise ValueError("Discovery page contains no visible text")
            for node in soup(["link", "iframe", "object", "embed", "img", "video", "audio"]):
                node.decompose()
            for node in soup.select("meta[http-equiv]"):
                if str(node.get("http-equiv", "")).lower() == "refresh":
                    node.decompose()
            screenshot = await self._render_snapshot(str(soup))
            return self.collect(
                tenant_id, str(response.url), raw_text, screenshot, source_type
            )
        finally:
            if owns_client:
                await active_client.aclose()

    @staticmethod
    async def _render_snapshot(html: str) -> bytes:
        async with async_playwright() as playwright:
            browser = await playwright.chromium.launch(
                headless=True, chromium_sandbox=True
            )
            try:
                page = await browser.new_page(viewport={"width": 1440, "height": 1000})
                await page.route("**/*", lambda route: route.abort())
                await page.set_content(html, wait_until="domcontentloaded")
                return await page.screenshot(full_page=True, type="png")
            finally:
                await browser.close()

    def get(self, evidence_id: str) -> dict[str, object]:
        row = self.database.one("SELECT * FROM discovery_evidence WHERE id=?", (evidence_id,))
        if not row:
            raise KeyError("Evidence not found")
        return row

    def list(self, tenant_id: str) -> list[dict[str, object]]:
        return self.database.all(
            "SELECT * FROM discovery_evidence WHERE tenant_id=? ORDER BY captured_at",
            (tenant_id,),
        )

    def export(self, tenant_id: str) -> Path:
        evidence = self.list(tenant_id)
        if not evidence:
            raise ValueError("No public discovery evidence is available")
        export_id = uuid.uuid4().hex
        relative = f"exports/PUBLIC_DISCOVERY_{export_id}.zip"
        target = self.artifacts.resolve(tenant_id, relative)
        handle, temporary = tempfile.mkstemp(prefix=".public-discovery.", dir=target.parent)
        os.close(handle)
        try:
            with zipfile.ZipFile(temporary, "w", zipfile.ZIP_DEFLATED) as archive:
                index: list[str] = []
                files: list[dict[str, object]] = []
                for item in evidence:
                    text_name = f"evidence/text/{item['id']}.txt"
                    shot_name = f"evidence/screenshots/{item['id']}.png"
                    archive.write(
                        self.artifacts.resolve(tenant_id, str(item["raw_text_path"])), text_name
                    )
                    archive.write(
                        self.artifacts.resolve(tenant_id, str(item["screenshot_path"])), shot_name
                    )
                    record = {
                        "evidence_id": item["id"],
                        "tenant_id": tenant_id,
                        "source_url": item["source_url"],
                        "captured_at": item["captured_at"],
                        "source_type": item["source_type"],
                        "raw_text_path": text_name,
                        "screenshot_path": shot_name,
                        "credibility_status": "AI_PENDING",
                        "content_sha256": item["content_sha256"],
                        "screenshot_sha256": item["screenshot_sha256"],
                        "collection_status": item["collection_status"],
                        "collection_error": item["collection_error"],
                    }
                    index.append(json.dumps(record, ensure_ascii=False))
                    files += [
                        {
                            "path": text_name,
                            "sha256": item["content_sha256"],
                            "size": self.artifacts.resolve(
                                tenant_id, str(item["raw_text_path"])
                            ).stat().st_size,
                        },
                        {
                            "path": shot_name,
                            "sha256": item["screenshot_sha256"],
                            "size": self.artifacts.resolve(
                                tenant_id, str(item["screenshot_path"])
                            ).stat().st_size,
                        },
                    ]
                index_content = ("\n".join(index) + "\n").encode()
                archive.writestr("evidence/index.jsonl", index_content)
                files.append(
                    {
                        "path": "evidence/index.jsonl",
                        "sha256": hashlib.sha256(index_content).hexdigest(),
                        "size": len(index_content),
                    }
                )
                archive.writestr(
                    "manifest.json",
                    json.dumps(
                        {
                            "schema_version": "1.0",
                            "package_type": "PUBLIC_DISCOVERY",
                            "tenant_id": tenant_id,
                            "export_id": export_id,
                            "created_at": utc_now(),
                            "credibility_policy": "AI_PENDING",
                            "files": files,
                        },
                        ensure_ascii=False,
                        indent=2,
                    ),
                )
            os.replace(temporary, target)
        except Exception:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass
            raise
        package_hash = self.artifacts.record_existing(tenant_id, relative)
        with self.database.transaction() as connection:
            connection.execute(
                """INSERT INTO exports(id,tenant_id,package_type,relative_path,sha256,created_at)
                   VALUES (?,?,'PUBLIC_DISCOVERY',?,?,?)""",
                (export_id, tenant_id, relative, package_hash, utc_now()),
            )
        return target
