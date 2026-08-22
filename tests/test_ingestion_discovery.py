import io
import json
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import AsyncMock, patch

import httpx
from docx import Document
from fastapi.testclient import TestClient
from openpyxl import Workbook

from geo_operator.api import create_app
from geo_operator.core.config import Settings
from geo_operator.core.db import Database
from geo_operator.core.storage import ArtifactStore
from geo_operator.discovery import PublicDiscoveryService
from geo_operator.sources import SourceIngestionService
from geo_operator.tenants import TenantService
from geo_operator.websites import WebsiteCrawlerService, validate_public_url


class IngestionTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.database = Database(root / "operator.sqlite3")
        self.database.initialize()
        self.artifacts = ArtifactStore(root / "data")
        self.tenant = TenantService(self.database, self.artifacts).create("资料测试")
        self.sources = SourceIngestionService(self.database, self.artifacts)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_text_word_excel_and_image_are_preserved_and_parsed(self) -> None:
        text = self.sources.ingest(self.tenant["id"], "notes.txt", "客户原文".encode())
        self.assertEqual(text["extraction_status"], "EXTRACTED")
        extracted = self.artifacts.resolve(
            self.tenant["id"], text["extracted_text_path"]
        ).read_text(encoding="utf-8")
        self.assertEqual(extracted, "客户原文")

        document = Document()
        document.add_paragraph("Word 客户资料")
        word_stream = io.BytesIO()
        document.save(word_stream)
        word = self.sources.ingest(self.tenant["id"], "资料.docx", word_stream.getvalue())
        self.assertEqual(word["extraction_status"], "EXTRACTED")

        workbook = Workbook()
        workbook.active.append(["品牌", "KZQ"])
        excel_stream = io.BytesIO()
        workbook.save(excel_stream)
        excel = self.sources.ingest(self.tenant["id"], "资料.xlsx", excel_stream.getvalue())
        self.assertEqual(excel["metadata"]["sheets"], ["Sheet"])

    def test_unsupported_type_and_private_url_fail_closed(self) -> None:
        with self.assertRaises(ValueError):
            self.sources.ingest(self.tenant["id"], "payload.exe", b"bad")
        with self.assertRaises(ValueError):
            validate_public_url("http://127.0.0.1/private")
        with self.assertRaises(ValueError):
            validate_public_url("file:///etc/passwd")


class CollectionTestCase(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.database = Database(root / "operator.sqlite3")
        self.database.initialize()
        self.artifacts = ArtifactStore(root / "data")
        self.tenant = TenantService(self.database, self.artifacts).create("抓取测试")

    async def asyncTearDown(self) -> None:
        self.temp.cleanup()

    async def test_website_crawl_is_same_origin_and_persists_text(self) -> None:
        def handler(request: httpx.Request) -> httpx.Response:
            pages = {
                "/": '<html><title>首页</title><body>官网首页<a href="/about">关于</a><a href="https://other.example/x">外链</a></body></html>',
                "/about": "<html><body>关于客户</body></html>",
            }
            return httpx.Response(
                200, text=pages[request.url.path],
                headers={"content-type": "text/html"}, request=request,
            )

        async with httpx.AsyncClient(
            transport=httpx.MockTransport(handler), follow_redirects=True
        ) as client:
            with patch(
                "geo_operator.websites.service.validate_public_url",
                side_effect=lambda value: value,
            ):
                result = await WebsiteCrawlerService(
                    self.database, self.artifacts
                ).crawl(self.tenant["id"], "https://site.example/", 10, client)
        self.assertEqual(result["collected"], 2)
        self.assertEqual(result["failed"], 0)
        stored = self.artifacts.resolve(
            self.tenant["id"], result["pages"][0]["text_path"]
        ).read_text(encoding="utf-8")
        self.assertIn("官网首页", stored)

    async def test_discovery_url_produces_raw_evidence_not_profile(self) -> None:
        def handler(request: httpx.Request) -> httpx.Response:
            return httpx.Response(
                200, text="<html><body>公开原始事实</body></html>",
                headers={"content-type": "text/html"}, request=request,
            )

        service = PublicDiscoveryService(self.database, self.artifacts)
        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            with (
                patch(
                    "geo_operator.discovery.service.validate_public_url",
                    side_effect=lambda value: value,
                ),
                patch.object(service, "_render_snapshot", AsyncMock(return_value=b"png")),
            ):
                evidence = await service.collect_url(
                    self.tenant["id"], "https://search.example/item", "SEARCH_RESULT", client
                )
        self.assertEqual(evidence["credibility_status"], "AI_PENDING")
        self.assertIsNone(
            self.database.one(
                "SELECT id FROM client_profiles WHERE tenant_id=?", (self.tenant["id"],)
            )
        )


class ProfilePackageContractTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.client = TestClient(create_app(Settings(root / "data", root / "db.sqlite3")))
        self.tenant = self.client.post("/api/tenants", json={"name": "契约测试"}).json()

    def tearDown(self) -> None:
        self.client.close()
        self.temp.cleanup()

    def test_profile_package_includes_uploaded_sources_and_website_index(self) -> None:
        uploaded = self.client.post(
            f"/api/tenants/{self.tenant['id']}/sources",
            content="正式客户资料".encode(),
            headers={"Content-Type": "text/plain", "X-Filename": "brief.txt"},
        )
        self.assertEqual(uploaded.status_code, 201)
        database = self.client.app.state.services["database"]
        artifacts = self.client.app.state.services["artifacts"]
        page_id = "page-contract"
        text_path = f"website/text/{page_id}.txt"
        _, digest = artifacts.atomic_write(self.tenant["id"], text_path, "官网正文".encode())
        with database.transaction() as connection:
            connection.execute(
                """INSERT INTO website_pages(
                   id,tenant_id,crawl_id,source_url,final_url,title,text_path,
                   content_sha256,status,error,captured_at)
                   VALUES (?,?,?,?,?,?,?,?,?,?,?)""",
                (
                    page_id, self.tenant["id"], "crawl-contract", "https://example.com",
                    "https://example.com", "官网", text_path, digest, "COLLECTED", None,
                    "2026-08-23T00:00:00+00:00",
                ),
            )
        profile_response = self.client.post(
            f"/api/tenants/{self.tenant['id']}/profile/build"
        )
        self.assertEqual(profile_response.status_code, 201)
        profile = profile_response.json()
        self.assertFalse(profile["profile"]["public_discovery_included"])
        artifacts = database.all(
            "SELECT * FROM artifacts WHERE tenant_id=?", (self.tenant["id"],)
        )
        self.assertGreaterEqual(len(artifacts), 3)
        approved = self.client.post(
            f"/api/approvals/{profile['approval_id']}/decision",
            json={"approved": True, "actor": "tester", "note": ""},
        )
        self.assertEqual(approved.status_code, 200)
        response = self.client.post(f"/api/profiles/{profile['id']}/export")
        self.assertEqual(response.status_code, 200)
        with zipfile.ZipFile(io.BytesIO(response.content)) as archive:
            names = set(archive.namelist())
            manifest = json.loads(archive.read("manifest.json"))
            pages = archive.read("website/pages.jsonl").decode()
        self.assertIn("profile/client_profile.json", names)
        self.assertIn("website/pages.jsonl", names)
        self.assertIn(f"website/text/{page_id}.txt", names)
        self.assertTrue(any(name.startswith("source/") for name in names))
        self.assertIn(page_id, pages)
        self.assertTrue(all({"path", "sha256", "size"} <= set(item) for item in manifest["files"]))


if __name__ == "__main__":
    unittest.main()
