# ============================================================================
# MOY GEO Operator · deterministic local mock services (True n8n E2E gate)
#
# Replaces the real external dependencies of the worker workflows during the
# local True N8N Full-Chain run. It ONLY provides deterministic external
# responses — it never writes to the business database. Every business row is
# written by the n8n workflows themselves.
#
# Endpoints (selected by the container env MOCK_PORT / MOCK_FORCE_FAIL):
#   mock-search  (port 8080)  GET  /search?q=..&format=json  -> SearXNG JSON
#   mock-crawl   (port 8000)  POST /crawl  {url}             -> Crawl4AI JSON
#   mock-engine  (port 8010)  POST /fail                     -> 500 (always)
#                             POST /observe                  -> Ollama-like answer
#   all          -            GET  /healthz                  -> 200 ok
#
# The search results are fixed and deliberately contain TWO authoritative
# surfaces of the E2E entity plus one spam URL, so WF-02 has a deterministic
# candidate pool to classify. MOCK_FORCE_FAIL=1 makes every request return 500
# (used by the WF-99 fault-injection engine TEST_HTTP_FAIL).
# ============================================================================
import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(os.environ.get("MOCK_PORT", "8080"))
FORCE_FAIL = os.environ.get("MOCK_FORCE_FAIL", "0") == "1"

SEARCH_RESULTS = {
    "results": [
        {
            "url": "https://www.shadowe2e-a.example",
            "title": "Shadow E2E Manufacturing Co. - Official Site (SYNTHETIC)",
            "content": "Shadow E2E Manufacturing Co. official company website (SYNTHETIC).",
        },
        {
            "url": "https://www.shadowe2e-a.example/1688",
            "title": "ShadowE2E - B2B Listing on Alibaba 1688 (SYNTHETIC)",
            "content": "ShadowE2E company storefront on Alibaba 1688 (SYNTHETIC).",
        },
        {
            "url": "https://news.example/article/12345",
            "title": "Unrelated industry news article (SYNTHETIC)",
            "content": "General industry news, not an official surface (SYNTHETIC).",
        },
    ]
}

CRAWL_MARKDOWN = (
    "# Shadow E2E Manufacturing Co. (SYNTHETIC)\n"
    "The legal name is Shadow E2E Manufacturing Co. (SYNTHETIC).\n"
    "The brand display name is ShadowE2E.\n"
    "The registration region is Shanghai Songjiang.\n"
    "SE-100 Precision Cylinder rated load is 500 kg.\n"
    "Holds ISO9001:2015 certification valid to 2027-06.\n"
)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # keep the mock quiet
        pass

    def _send(self, code, payload, content_type="application/json"):
        data = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if FORCE_FAIL:
            self._send(500, {"error": "MOCK_FORCE_FAIL injected 500"})
            return
        if self.path.startswith("/healthz"):
            self._send(200, {"ok": True})
        elif self.path.startswith("/search"):
            self._send(200, SEARCH_RESULTS)
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if FORCE_FAIL:
            self._send(500, {"error": "MOCK_FORCE_FAIL injected 500"})
            return
        length = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except Exception:
            body = {}
        if self.path.startswith("/healthz"):
            self._send(200, {"ok": True})
        elif self.path.startswith("/crawl"):
            self._send(200, {"result": {"markdown": CRAWL_MARKDOWN, "url": body.get("url", "")}})
        elif self.path.startswith("/observe"):
            self._send(200, {
                "response": "Shanghai Songjiang is home to several manufacturing companies "
                           "including Shadow E2E Manufacturing Co., whose SE-100 Precision "
                           "Cylinder has a rated load of 500 kg.",
                "model": "mock-engine",
            })
        elif self.path.startswith("/fail"):
            self._send(500, {"error": "injected deterministic 500 from mock-engine"})
        else:
            self._send(404, {"error": "not found"})


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
