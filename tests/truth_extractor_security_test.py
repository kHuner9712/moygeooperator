#!/usr/bin/env python3
"""Offline security unit tests for the truth-extractor service (P0.9/P0.10/P0.11/P0.12).

Runs WITHOUT a live server and WITHOUT network: socket.getaddrinfo and
requests.Session are monkeypatched so the SSRF guard and the streaming byte cap
are exercised deterministically. Deps: see services/truth-extractor/requirements.txt.
"""
import io
import json
import os
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path

# Point TRUTH_ROOT at a temp dir before importing the app module.
_TMP = tempfile.TemporaryDirectory()
os.environ["TRUTH_ROOT"] = _TMP.name
os.environ["MAX_RESPONSE_BYTES"] = "65536"  # 64 KB for the cap tests

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "services", "truth-extractor"))
import app  # noqa: E402


class FakeResponse:
    def __init__(self, status=200, headers=None, chunks=None, location=None):
        self.status_code = status
        self.headers = headers or {}
        self._chunks = chunks or []
        self._location = location

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def iter_content(self, chunk_size=65536):
        for c in self._chunks:
            yield c


class FakeSession:
    def __init__(self, resp):
        self._resp = resp
        self.max_redirects = 5

    def get(self, *a, **k):
        return self._resp


class ExtractUrlBase(unittest.TestCase):
    def setUp(self):
        self._dns = {}
        self._session = None

    def _patch(self):
        p1 = mock.patch.object(app.socket, "getaddrinfo", side_effect=self._fake_dns)
        p2 = mock.patch.object(app.requests, "Session", side_effect=lambda: self._session)
        p1.start()
        p2.start()
        self.addCleanup(p1.stop)
        self.addCleanup(p2.stop)

    def _fake_dns(self, host, *a, **k):
        if host in self._dns:
            return [(2, 1, 6, "", (self._dns[host], 0))]
        raise app.socket.gaierror("no addr")

    def _req(self, url, resp):
        self._session = FakeSession(resp)
        self._patch()
        return app.extract_url(app.UrlRequest(url=url))


class IPBlockedTest(unittest.TestCase):
    BLOCKED = [
        "127.0.0.1", "127.0.0.2", "10.0.0.1", "10.255.255.255",
        "172.16.0.1", "172.31.255.255", "192.168.0.1", "192.168.255.255",
        "169.254.169.254", "169.254.0.1", "0.0.0.0", "255.255.255.255",
        "224.0.0.1", "240.0.0.1", "100.64.0.1", "192.0.2.1", "198.51.100.1",
        "203.0.113.1", "0.0.0.0", "::1", "::", "fe80::1", "fc00::1",
        "fd12:3456::1", "ff02::1", "::ffff:127.0.0.1", "::ffff:10.0.0.1",
    ]
    ALLOWED = ["8.8.8.8", "1.1.1.1", "93.184.216.34", "2606:4700:4700::1111"]

    def test_blocked(self):
        for ip in self.BLOCKED:
            self.assertTrue(app._ip_is_blocked(ip), f"expected blocked: {ip}")

    def test_allowed(self):
        for ip in self.ALLOWED:
            self.assertFalse(app._ip_is_blocked(ip), f"expected allowed: {ip}")


class PathScopingTest(unittest.TestCase):
    def setUp(self):
        self.root = Path(_TMP.name)
        # Clean any stale dirs/files from a previous setUp (module-level temp dir).
        for child in self.root.iterdir():
            try:
                if child.is_symlink():
                    child.unlink()
                elif child.is_dir() and not child.is_symlink():
                    import shutil
                    shutil.rmtree(child, ignore_errors=True)
                else:
                    child.unlink()
            except OSError:
                pass
        (self.root / "clientA").mkdir()
        (self.root / "clientB").mkdir()
        (self.root / "clientA" / "doc.pdf").write_bytes(b"%PDF-1.4 fake")
        (self.root / "clientB" / "secret.pdf").write_bytes(b"%PDF-1.4 secret")
        # symlink escaping the namespace
        try:
            (self.root / "clientA" / "escape").symlink_to(self.root / "clientB")
        except OSError:
            pass

    def test_ok_inside_namespace(self):
        p = app._resolve_client_path("clientA", "doc.pdf")
        self.assertEqual(p, (self.root / "clientA" / "doc.pdf").resolve())

    def test_rejects_absolute(self):
        with self.assertRaises(app.HTTPException):
            app._resolve_client_path("clientA", "/etc/passwd")

    def test_rejects_traversal(self):
        with self.assertRaises(app.HTTPException):
            app._resolve_client_path("clientA", "../../clientB/secret.pdf")

    def test_rejects_other_client(self):
        with self.assertRaises(app.HTTPException):
            app._resolve_client_path("clientA", "../clientB/secret.pdf")

    def test_rejects_symlink_escape(self):
        with self.assertRaises(app.HTTPException):
            app._resolve_client_path("clientA", "escape/secret.pdf")

    def test_rejects_missing_file(self):
        with self.assertRaises(app.HTTPException):
            app._resolve_client_path("clientA", "nope.pdf")


class SsrfTest(ExtractUrlBase):
    def test_blocks_metadata_ip(self):
        self._dns = {"host.local": "169.254.169.254"}
        with self.assertRaises(app.HTTPException) as cm:
            self._req("http://host.local/page", FakeResponse())
        self.assertIn("SSRF", cm.exception.detail)

    def test_blocks_loopback(self):
        self._dns = {"self.local": "127.0.0.1"}
        with self.assertRaises(app.HTTPException):
            self._req("http://self.local/page", FakeResponse())

    def test_blocks_localhost_name(self):
        with self.assertRaises(app.HTTPException):
            self._req("http://localhost/page", FakeResponse())

    def test_blocks_private(self):
        self._dns = {"int.local": "10.0.0.5"}
        with self.assertRaises(app.HTTPException):
            self._req("http://int.local/page", FakeResponse())


class SizeCapTest(ExtractUrlBase):
    def test_exceeds_byte_cap(self):
        self._dns = {"ok.example": "8.8.8.8"}
        big = b"x" * (app.MAX_RESPONSE_BYTES + 100)
        resp = FakeResponse(status=200, headers={"content-type": "text/plain"}, chunks=[big])
        with self.assertRaises(app.HTTPException) as cm:
            self._req("http://ok.example/x", resp)
        self.assertIn("RESOURCE_LIMIT_EXCEEDED", cm.exception.detail)

    def test_rejects_disallowed_content_type(self):
        self._dns = {"ok.example": "8.8.8.8"}
        resp = FakeResponse(status=200, headers={"content-type": "application/octet-stream"}, chunks=[b"x"])
        with self.assertRaises(app.HTTPException):
            self._req("http://ok.example/x", resp)

    def test_ok_small_text(self):
        self._dns = {"ok.example": "8.8.8.8"}
        resp = FakeResponse(status=200, headers={"content-type": "text/plain"}, chunks=[b"hello world"])
        out = self._req("http://ok.example/x", resp)
        data = json.loads(out.body)  # FastAPI JSONResponse has no .json()
        self.assertEqual(data["text"], "hello world")
        self.assertEqual(data["parser"], "URL")


if __name__ == "__main__":
    unittest.main(verbosity=2)