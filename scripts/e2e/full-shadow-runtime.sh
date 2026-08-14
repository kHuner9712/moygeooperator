#!/usr/bin/env bash
# =============================================================================
# geo-operator — Full Shadow Runtime E2E (P0.17)
#
# Reproducible local driver proving the WF-01..WF-08 runtime chain against the
# REAL stack (PostgreSQL + n8n + Ollama + truth-extractor). Layers:
#   L0  stack sanity (all four services healthy)
#   L1  migrations + views + seeds (idempotent; proves a clean rebuild)
#   L2  truth-extractor security unit tests (offline, same gate as CI)
#   L3  DB-contract E2E  (tests/integration/shadow_runtime_e2e.sql) —
#       WF-01..WF-08 function contracts + tenant isolation + job lifecycle
#   L4  n8n workflow registry: 9 workflows imported, WF-99 error binding present
#   L5  REAL n8n WF-01 run: synthetic client-scoped PDF -> webhook ->
#       truth-extractor -> Ollama -> import_truth_pack -> parsed_at
#   L6  artifact JSON (artifacts/shadow-runtime-e2e.json) + verdict
#
# Idempotent and safe to re-run: every stage is deterministic or dedup-keyed.
#
# Usage:
#   bash scripts/e2e/full-shadow-runtime.sh
# Env (optional): N8N_PORTMAP (default 5678), TRUTH_HOST_DIR (default ./data/truth)
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# Docker client: under WSL/git-bash the native `docker` may not reach the
# Docker Desktop engine (WSL integration off). Fall back to the Windows client
# (docker.exe is on PATH and resolves without spaces).
if docker info >/dev/null 2>&1; then
  COMPOSE="docker compose"
else
  command -v docker.exe >/dev/null 2>&1 && COMPOSE="docker.exe compose" || COMPOSE="docker compose"
fi

PSQL="${COMPOSE} exec -T postgres psql -U geo_operator -d geo_operator -v ON_ERROR_STOP=1 -qAt"
PSQLX="${COMPOSE} exec -T postgres psql -U geo_operator -d geo_operator -v ON_ERROR_STOP=1"
N8N="${COMPOSE} exec -T n8n"
N8N_PORT="${N8N_PORTMAP:-5678}"
ARTIFACT_DIR="artifacts"
ARTIFACT="${ARTIFACT_DIR}/shadow-runtime-e2e.json"
RUN_ID="$(date +%Y%m%d%H%M%S)"
STAGES_FILE="$(mktemp)"
FAIL_COUNT=0

say()  { printf '\n\x1b[1;36m== %s ==\x1b[0m\n' "$*"; }
pass() { echo "  [PASS] $*"; printf '{"name":"%s","ok":true}\n' "$1" >> "$STAGES_FILE"; }
fail() { echo "  [FAIL] $*"; FAIL_COUNT=$((FAIL_COUNT + 1)); printf '{"name":"%s","ok":false}\n' "$1" >> "$STAGES_FILE"; }
verdict() { if [ "$FAIL_COUNT" -eq 0 ]; then echo "SHADOW_RUN_READY"; else echo "SHADOW_RUN_BLOCKED"; fi; }

# -----------------------------------------------------------------------------
# L0 — stack sanity
# -----------------------------------------------------------------------------
say "L0: stack sanity"
${COMPOSE} ps --format '{{.Name}} {{.Status}}' | tee /tmp/e2e-ps.txt >/dev/null
for svc in postgres n8n ollama truth-extractor; do
  if ! grep -q "geo-operator-${svc}.*healthy" /tmp/e2e-ps.txt; then
    echo "  >> starting ${svc} (tooling profile for truth-extractor)"
    ${COMPOSE} --profile tooling up -d "${svc}" >/dev/null
  fi
done
sleep 5
${COMPOSE} ps --format '{{.Name}} {{.Status}}' | tee /tmp/e2e-ps.txt >/dev/null
ok=1
for svc in postgres n8n ollama truth-extractor; do
  grep -q "geo-operator-${svc}.*healthy" /tmp/e2e-ps.txt || { echo "  !! ${svc} not healthy"; ok=0; }
done
[ "$ok" -eq 1 ] && pass "L0_stack_sanity" || fail "L0_stack_sanity"

# -----------------------------------------------------------------------------
# L1 — DB reproducibility: migrations + views + seeds (all idempotent)
# -----------------------------------------------------------------------------
say "L1: migrations + views + seeds"
${COMPOSE} exec -T -e PGUSER=geo_operator -e PGDATABASE=geo_operator postgres bash /srv/db/run-migrations.sh >/dev/null 2>&1 \
  && ${COMPOSE} exec -T -e PGUSER=geo_operator -e PGDATABASE=geo_operator postgres bash /srv/db/apply-views.sh >/dev/null 2>&1 \
  && ${COMPOSE} exec -T -e PGUSER=geo_operator -e PGDATABASE=geo_operator postgres bash /srv/db/run-seeds.sh >/dev/null 2>&1 \
  && pass "L1_db_reproducible" || fail "L1_db_reproducible"

# -----------------------------------------------------------------------------
# L2 — truth-extractor security unit tests (offline; same gate as CI)
# -----------------------------------------------------------------------------
say "L2: truth-extractor security unit tests"
if ${COMPOSE} exec -T truth-extractor mkdir -p /tmp/e2e/services /tmp/e2e/tests >/dev/null 2>&1 \
   && ${COMPOSE} cp services/truth-extractor truth-extractor:/tmp/e2e/services/ >/dev/null 2>&1 \
   && ${COMPOSE} cp tests/truth_extractor_security_test.py truth-extractor:/tmp/e2e/tests/ >/dev/null 2>&1 \
   && ${COMPOSE} exec -T truth-extractor python /tmp/e2e/tests/truth_extractor_security_test.py >/tmp/e2e-sec.log 2>&1; then
  pass "L2_security_unit_tests"
else
  fail "L2_security_unit_tests"
  tail -n 20 /tmp/e2e-sec.log 2>/dev/null | sed 's/^/    /'
fi

# -----------------------------------------------------------------------------
# L3 — DB-contract E2E (WF-01..WF-08 contracts + isolation + runtime)
# -----------------------------------------------------------------------------
say "L3: DB-contract E2E (shadow_runtime_e2e.sql)"
if ${PSQLX} -q -f /srv/tests/integration/shadow_runtime_e2e.sql >/tmp/e2e-db.log 2>&1; then
  pass "L3_db_contract_e2e"
  grep 'PASS' /tmp/e2e-db.log | sed 's/^/    /'
else
  fail "L3_db_contract_e2e"
  grep -E 'ERROR|NOTICE' /tmp/e2e-db.log | head -n 30 | sed 's/^/    /'
fi

# -----------------------------------------------------------------------------
# L4 — n8n workflow registry + WF-99 error binding
# -----------------------------------------------------------------------------
say "L4: n8n workflow registry + WF-99 error binding"
n8n_list="$(${N8N} n8n list:workflow 2>/dev/null || true)"
n8n_count="$(printf '%s\n' "$n8n_list" | grep -c '|' || true)"
if [ "${n8n_count:-0}" -ge 9 ]; then
  pass "L4_n8n_registry"
else
  fail "L4_n8n_registry (count=$n8n_count)"
fi

# Apply the WF-99 error binding (deploy.sh Stage 4b logic, idempotent): every
# worker workflow must reference WF-99 as its errorWorkflow, else a worker
# failure never reaches fail_job(). Settings live in the n8n DB; the binding is
# loaded by n8n on restart (L5 restarts n8n, so it is live by then).
# Done as ONE psql call (UPDATE; then count in the same transaction) — under
# git-bash the `$(docker.exe ...)` substitution is flaky when invoked repeatedly
# in a loop, and a data-modifying CTE's changes are not visible to the main
# SELECT of the same statement, so UPDATE and count are separate statements.
N8N_PSQL="${COMPOSE} exec -T postgres psql -U geo_operator -d n8n -qAt"
bound="$({ ${N8N_PSQL} -c "UPDATE workflow_entity we
SET settings = jsonb_set(COALESCE(we.settings,'{}')::jsonb, '{errorWorkflow}', to_jsonb(err.id::text))
FROM (SELECT id FROM workflow_entity WHERE lower(name) LIKE '%wf-99%' LIMIT 1) err
WHERE lower(we.name) ~ 'wf-0[4-8]'
  AND COALESCE(we.settings->>'errorWorkflow','') <> err.id::text;
SELECT count(*) FROM workflow_entity
WHERE settings->>'errorWorkflow' IS NOT NULL AND lower(name) ~ 'wf-0[4-8]';" 2>/dev/null || true; } | tail -n 1)"
if [ "${bound:-0}" -ge 5 ]; then
  pass "L4_wf99_error_binding"
else
  fail "L4_wf99_error_binding (bound=$bound)"
fi

# -----------------------------------------------------------------------------
# L5 — REAL n8n WF-01 run (synthetic client-scoped PDF -> webhook -> extractor
#      -> Ollama -> import_truth_pack -> parsed_at)
# -----------------------------------------------------------------------------
say "L5: real n8n WF-01 run"
client_uuid="$(${PSQL} -c "SELECT id::text FROM clients WHERE code='SHADOW-E2E-A';")"
pdf_rel="synthetic-e2e-${RUN_ID}.pdf"
doc_key="E2E-PDF-${RUN_ID}"
import_marker="SYNTH-${doc_key}-"
if [ -z "$client_uuid" ]; then
  fail "L5_wf01_run (SHADOW-E2E-A client missing)"
else
  # 5.1 — write a REAL, extractable-text PDF into the client's truth namespace.
  ${COMPOSE} exec -T truth-extractor python - "$client_uuid" "$pdf_rel" <<'PY'
import sys
from pathlib import Path
from pypdf import PdfWriter
from pypdf.generic import DictionaryObject, NameObject, NumberObject, StreamObject

cid, rel = sys.argv[1], sys.argv[2]
out = Path("/data/truth") / cid / rel
out.parent.mkdir(parents=True, exist_ok=True)

lines = [
    b"Shadow E2E Manufacturing Co. Company Profile (SYNTHETIC)",
    b"The legal name is Shadow E2E Manufacturing Co.",
    b"The brand display name is ShadowE2E",
    b"The registration region is Shanghai Songjiang",
    b"SE-100 Precision Cylinder rated load is 500 kg",
    b"Holds ISO9001:2015 certification valid to 2027-06",
]
content = b"BT\n/F1 20 Tf\n72 740 Td\n" + b"".join(
    b"(" + l + b") Tj\n0 -32 Td\n" for l in lines
) + b"ET\n"

writer = PdfWriter()
page = writer.add_blank_page(width=612, height=792)
font_obj = writer._add_object(DictionaryObject({
    NameObject("/Type"): NameObject("/Font"),
    NameObject("/Subtype"): NameObject("/Type1"),
    NameObject("/BaseFont"): NameObject("/Helvetica"),
}))
resources = DictionaryObject({NameObject("/Font"): DictionaryObject({NameObject("/F1"): font_obj})})
page[NameObject("/Resources")] = resources
stream = StreamObject()
stream.set_data(content)
stream[NameObject("/Length")] = NumberObject(len(content))
page[NameObject("/Contents")] = writer._add_object(stream)
with open(out, "wb") as fh:
    writer.write(fh)
print(f"wrote {out}")
PY

  # 5.2 — register the raw Truth doc (RECEIVED, no content) so WF-01 picks it up.
  ${PSQL} -c "INSERT INTO truth_documents(client_id, import_key, document_type, title, source_uri, file_path, status, provided_by)
    VALUES ('${client_uuid}', '${doc_key}', 'PDF', 'Synthetic E2E Profile ${RUN_ID}', NULL, '${pdf_rel}', 'RECEIVED', 'e2e')
    ON CONFLICT (import_key) WHERE import_key IS NOT NULL DO NOTHING;" >/dev/null

  # 5.3 — activate wf01 (CLI) + restart n8n so the webhook is live.
  wf01_id="$(${COMPOSE} exec -T postgres psql -U geo_operator -d n8n -v ON_ERROR_STOP=1 -qAt \
    -c "SELECT id FROM workflow_entity WHERE lower(name) LIKE '%wf-01%' LIMIT 1;")"
  if [ -n "$wf01_id" ]; then
    ${N8N} n8n update:workflow --id="$wf01_id" --active=true >/dev/null 2>&1 || true
    ${COMPOSE} restart n8n >/dev/null 2>&1
    sleep 15
  fi

  # 5.4 — fire the webhook (responseMode onReceived -> returns immediately).
  http_code="$(curl -s -o /tmp/e2e-webhook.json -w '%{http_code}' -X POST \
    "http://localhost:${N8N_PORT}/webhook/wf01-intake" \
    -H 'Content-Type: application/json' -d "{\"clientId\":\"${client_uuid}\"}")"

  # 5.5 — poll until the doc is claimed (parsed_at) or the run failed closed.
  doc_status=""
  for i in $(seq 1 30); do
    doc_status="$(${PSQL} -c "SELECT status FROM truth_documents WHERE import_key='${doc_key}';")"
    parsed_at="$(${PSQL} -c "SELECT (parsed_at IS NOT NULL)::text FROM truth_documents WHERE import_key='${doc_key}';")"
    [ "$parsed_at" = "t" ] && break
    sleep 5
  done
  claims_imported="$(${PSQL} -c "SELECT count(*) FROM claims WHERE client_id='${client_uuid}' AND import_key LIKE '${import_marker}%';")"
  failed_exc="$(${PSQL} -c "SELECT count(*) FROM exceptions WHERE client_id='${client_uuid}' AND exception_type='CLAIM_EXTRACTION_FAILED' AND status='OPEN';")"

  # parsed_at is ONLY set by the "Mark docs parsed" node, which sits downstream
  # of Import Truth Pack — so parsed_at NOT NULL proves import_truth_pack ran.
  parsed_at="$(${PSQL} -c "SELECT (parsed_at IS NOT NULL)::text FROM truth_documents WHERE import_key='${doc_key}';")"
  exec_ev="$(${COMPOSE} exec -T postgres psql -U geo_operator -d n8n -qAt -c "SELECT id || ':' || status FROM execution_entity WHERE \"workflowId\" = '$wf01_id' ORDER BY \"startedAt\" DESC LIMIT 1;" 2>/dev/null || true)"
  if [ "$http_code" = "200" ] && [ "$doc_status" = "PARSED" ] && [ "$parsed_at" = "true" ]; then
    pass "L5_wf01_run"
    echo "    webhook=$http_code doc=$doc_status n8n_exec=$exec_ev claims_imported=$claims_imported"
  else
    fail "L5_wf01_run (webhook=$http_code doc=$doc_status parsed=$parsed_at claims=$claims_imported failed_exc=$failed_exc)"
    echo "    !! WF-01 did not complete the chain; tail of n8n webhook response:"
    head -c 500 /tmp/e2e-webhook.json 2>/dev/null | sed 's/^/    /' || true
  fi

  # 5.6 — restore the conservative default: deactivate wf01.
  if [ -n "$wf01_id" ]; then
    ${N8N} n8n update:workflow --id="$wf01_id" --active=false >/dev/null 2>&1 || true
    ${COMPOSE} restart n8n >/dev/null 2>&1 || true
  fi
fi

# -----------------------------------------------------------------------------
# L6 — artifact + verdict
# -----------------------------------------------------------------------------
say "L6: artifact + verdict"
VERDICT="$(verdict)"
mkdir -p "${ARTIFACT_DIR}"
TS_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
PS_TXT="$(tr '\n' ';' < /tmp/e2e-ps.txt)"
if command -v jq >/dev/null 2>&1; then
  jq -n --arg ts "$TS_UTC" --arg run_id "$RUN_ID" --arg verdict "$VERDICT" \
    --argjson stages "$(jq -s . "$STAGES_FILE")" --arg ps "$PS_TXT" \
    '{schema_version:1, run_id:$run_id, started_at:$ts, verdict:$verdict, stages:$stages, stack:$ps,
      notes:"SYNTHETIC shadow-runtime E2E. L3 = DB-contract WF-01..WF-08; L5 = real n8n WF-01 webhook run. All data fictional (SHADOW-E2E-A/B)."}' \
    > "${ARTIFACT}"
else
  python3 - "$STAGES_FILE" "$ARTIFACT" "$RUN_ID" "$TS_UTC" "$VERDICT" "$PS_TXT" <<'PY'
import json, sys
stages_f, out, run_id, ts, verdict, ps = sys.argv[1:]
stages = [json.loads(l) for l in open(stages_f, encoding="utf-8") if l.strip()]
json.dump({
  "schema_version": 1, "run_id": run_id, "started_at": ts, "verdict": verdict,
  "stages": stages, "stack": ps,
  "notes": "SYNTHETIC shadow-runtime E2E. L3 = DB-contract WF-01..WF-08; L5 = real n8n WF-01 webhook run. All data fictional (SHADOW-E2E-A/B).",
}, open(out, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
fi
echo "    verdict: ${VERDICT}"
echo "    artifact: ${ARTIFACT}"
rm -f "$STAGES_FILE"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
echo ">> full shadow runtime E2E done."
