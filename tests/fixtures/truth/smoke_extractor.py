#!/usr/bin/env python3
"""Local smoke test for the truth-extractor service (P0.2)."""
import requests

BASE = "http://127.0.0.1:9000"
ok = True


def check(name, cond, extra=""):
    global ok
    print(("PASS" if cond else "FAIL"), name, extra)
    if not cond:
        ok = False


# PDF extraction
with open("/fix/catalog-text.pdf", "rb") as fh:
    r = requests.post(f"{BASE}/extract/pdf", files={"file": ("catalog-text.pdf", fh, "application/pdf")}, timeout=30)
check("pdf status 200", r.status_code == 200, f"status={r.status_code}")
if r.status_code == 200:
    d = r.json()
    check("pdf parser PDF", d["parser"] == "PDF")
    check("pdf text has 5000 PSI", "5000 PSI" in d["text"], repr(d["text"][:80]))
    check("pdf has checksum", bool(d["checksum"]))
    check("pdf has source_uri", d["source_uri"] == "catalog-text.pdf")

# URL/HTML extraction (serve the fixture over a tiny local http server is not
# available here; instead verify the URL endpoint rejects a non-http scheme and
# that the WEBPAGE path is wired by pointing at a data-like fetch is out of
# scope. We assert the scheme-fail-closed behaviour.)
r = requests.post(f"{BASE}/extract/url", json={"url": "file:///etc/passwd"}, timeout=30)
check("url scheme rejected (fail closed)", r.status_code == 422, f"status={r.status_code}")

print("ALL_OK" if ok else "HAS_FAILURES")
raise SystemExit(0 if ok else 1)