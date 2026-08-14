#!/usr/bin/env bash
# =============================================================================
# geo-operator — TRUE N8N Full-Chain Shadow Runtime (P0.18)
#
# FIRST REAL CLIENT SHADOW RUN 前最后一个验收阶段。唯一目标:
# 用同一个 synthetic tenant (N8N-E2E-A) + 同一条因果数据链，让 WF-01..WF-08
# 全部由真实 n8n workflow 实际执行，并通过业务结果断言 —— 不是 DB function
# contract 冒充，不是 HTTP 200 冒充，不是 seed 预置业务结果。
#
# 分层:
#   L0  stack health (postgres/n8n/ollama/truth-extractor + e2e mocks)
#   L1  clean DB (drop schema -> recreate)
#   L2  migrations + views (idempotent, clean rebuild proof)
#   L3  seeds (minimal system config; N8N-E2E tenants carry NO business data)
#   L4  import workflows (Git JSON is source of truth)
#   L5  bind WF-99 error handler to worker workflows (wf04..wf08)
#   L6  activate wf01..wf08 webhooks
#   L7  verify ZERO business-chain state for N8N-E2E-A
#   L8  run WF-01 (real PDF -> truth-extractor -> Ollama -> import)
#   L9  assert WF-01 (claims>=1 evidence>=1 entity_id NOT NULL)
#   L10 run WF-02 (mock SearXNG/Crawl4AI via real workflow nodes)
#   L11 assert WF-02 (surfaces>=1 resources>=1 evidence>=1)
#   L12 run WF-03 (intents + queries + schedule_observation_jobs)
#   L13 assert WF-03 (intents>=1 queries>=1 ENGINE_OBSERVATION jobs>=1)
#   L14 run WF-04 (resolve adapter -> Ollama -> record_observation)
#   L15 assert WF-04 (observation>=1 query from WF-03)
#   L16 run WF-05 (claim GAP_ANALYSIS -> analyze_gaps -> plan_actions)
#   L17 assert WF-05 (gaps>=1 actions>=1 CONTENT_FACTORY jobs>=1)
#   L18 run WF-06 (brief -> generation -> fact/compliance gate -> closure)
#   L19 assert WF-06 (canonical+adapted READY_TO_PUBLISH, tasks>=1, jobs>=1)
#   L20 run WF-07 (dispatch -> MANUAL_REQUIRED -> WAITING_APPROVAL)
#   L21 assert WF-07 (WAITING_APPROVAL, no records, no external_id)
#   L22 run WF-08 (claim REPORT -> generate_report)
#   L23 assert WF-08 (report>=1, metrics from A observations)
#   L24 WF-99 real fault injection (TEST_HTTP_FAIL -> 500 -> WF-99 -> fail_job)
#   L25 cross-client WF-07 runtime attack (A job -> B task -> CROSS_CLIENT)
#   L26 max_attempts=3 real runtime exhaustion (3x fail -> FAILED)
#   L27 artifact (artifacts/true-n8n-shadow-runtime.json)
#   L28 deactivate workflows
#   L29 verdict (SHADOW_RUN_READY / SHADOW_RUN_BLOCKED)
#
# Usage:
#   bash scripts/e2e/true-n8n-shadow-runtime.sh
# Env: N8N_PORTMAP (default 5678), TRUTH_HOST_DIR (default ./data/truth)
# =============================================================================
set -euo pipefail

# Disable MSYS/git-bash POSIX path conversion so container paths like
# /srv/db/run-migrations.sh and /home/node/workflows pass through verbatim.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

if docker info >/dev/null 2>&1; then
  COMPOSE="docker compose -f docker-compose.yml -f docker-compose.e2e.yml"
else
  command -v docker.exe >/dev/null 2>&1 && COMPOSE="docker.exe compose -f docker-compose.yml -f docker-compose.e2e.yml" || COMPOSE="docker compose -f docker-compose.yml -f docker-compose.e2e.yml"
fi
BASE_COMPOSE="docker compose -f docker-compose.yml"
PSQL="${BASE_COMPOSE} exec -T postgres psql -U geo_operator -d geo_operator -v ON_ERROR_STOP=1 -qAt"
PSQLX="${BASE_COMPOSE} exec -T postgres psql -U geo_operator -d geo_operator -v ON_ERROR_STOP=1"
N8NPSQL="${BASE_COMPOSE} exec -T postgres psql -U geo_operator -d n8n -v ON_ERROR_STOP=1 -qAt"
N8N="${BASE_COMPOSE} exec -T n8n"
N8N_PORT="${N8N_PORTMAP:-5678}"
ARTIFACT_DIR="artifacts"
ARTIFACT="${ARTIFACT_DIR}/true-n8n-shadow-runtime.json"
RUN_ID="$(date +%Y%m%d%H%M%S)"
TENANT="N8N-E2E-A"
TENANT_B="N8N-E2E-B"
MARKER="E2E-PDF-${RUN_ID}"
STAGES_FILE="$(mktemp)"
FAIL_COUNT=0
A_UUID=""

# ---- collected lineage ids --------------------------------------------------
EXEC_WF01=""; EXEC_WF02=""; EXEC_WF03=""; EXEC_WF04=""; EXEC_WF05=""
EXEC_WF06=""; EXEC_WF07=""; EXEC_WF08=""
N_ENTITIES=0; N_CLAIMS=0; N_EVIDENCE=0
N_SURFACES=0; N_INTENTS=0; N_QUERIES=0; N_OBS=0; N_GAPS=0; N_ACTIONS=0
N_CANONICAL=0; N_ADAPTED=0; N_PUBJOBS=0; N_WAITING=0; N_PUBREC=0; N_REPORTS=0
WF04_FAIL_EXEC=""; WF99_EXEC=""; RETRY_JOB_STATUS=""; RETRY_ATTEMPTS=0
CROSS_JOB_STATUS=""

say()   { printf '\n\x1b[1;36m== %s ==\x1b[0m\n' "$*"; }
pass()  { echo "  [PASS] $*"; printf '{"name":"%s","ok":true}\n' "$1" >> "$STAGES_FILE"; }
fail()  { echo "  [FAIL] $*"; FAIL_COUNT=$((FAIL_COUNT + 1)); printf '{"name":"%s","ok":false}\n' "$1" >> "$STAGES_FILE"; }
verdict(){ if [ "$FAIL_COUNT" -eq 0 ]; then echo "SHADOW_RUN_READY"; else echo "SHADOW_RUN_BLOCKED"; fi; }
st_ok() { grep -q "\"name\":\"$1[^\"]*\",\"ok\":true" "$STAGES_FILE" 2>/dev/null; }

q() { ${PSQL} -c "$1" 2>/dev/null || echo "__ERR__"; }
qn() { ${N8NPSQL} -c "$1" 2>/dev/null || echo "__ERR__"; }

# Resolve an n8n workflow id by number (e.g. 01..08, 99).
wfid() { qn "SELECT id::text FROM workflow_entity WHERE lower(name) LIKE '%wf-$1%' LIMIT 1"; }

wait_exec() {
  # $1 = workflow id, $2 = min startedAt (ISO), $3 = timeout seconds, $4 = label
  local wfid="$1" from="$2" tmo="${3:-180}" label="$4"
  local st=""
  for i in $(seq 1 $((tmo / 3))); do
    st="$(qn "SELECT id || ':' || status FROM execution_entity WHERE \"workflowId\" = '${wfid}' AND \"startedAt\" >= '${from}'::timestamptz ORDER BY id DESC LIMIT 1")"
    case "$st" in
      __ERR__) ;;
      *:success|*:error) echo "$st"; return 0;;
      *) ;;
    esac
    sleep 3
  done
  echo "TIMEOUT:$st"
}

trigger() {
  # $1 = webhook path, $2 = json body -> echoes http code
  curl -s -o /tmp/e2e-webhook-${1}.json -w '%{http_code}' -X POST \
    "http://localhost:${N8N_PORT}/webhook/${1}" \
    -H 'Content-Type: application/json' -d "$2" || echo "CURL_ERR"
}

# ---------------------------------------------------------------------------
# L0 — stack sanity (base + e2e mocks)
# ---------------------------------------------------------------------------
say "L0: stack health"
${BASE_COMPOSE} ps --format '{{.Name}} {{.Status}}' > /tmp/e2e-ps.txt 2>/dev/null || true
for svc in postgres n8n ollama truth-extractor; do
  if ! grep -q "geo-operator-${svc}.*healthy" /tmp/e2e-ps.txt; then
    echo "  >> starting ${svc}"
    ${BASE_COMPOSE} --profile tooling up -d "${svc}" >/dev/null 2>&1 || true
  fi
done
${COMPOSE} up -d --force-recreate n8n mock-search mock-crawl mock-engine >/dev/null 2>&1 || true
echo "  >> n8n recreated with e2e env (SEARCH_BASE_URL/CRAWL_BASE_URL/TEST_FAIL_URL)"
# wait for every service (incl. n8n) to become healthy before the gate check.
hc=""
for i in $(seq 1 45); do
  ${COMPOSE} ps --format '{{.Name}} {{.Status}}' > /tmp/e2e-ps.txt 2>/dev/null || true
  hc="$(cat /tmp/e2e-ps.txt)"
  nok=0
  for svc in postgres n8n ollama truth-extractor mock-search mock-crawl mock-engine; do
    echo "$hc" | grep -q "geo-operator-${svc}.*healthy" || nok=1
  done
  [ "$nok" -eq 0 ] && break
  sleep 3
done
${COMPOSE} ps --format '{{.Name}} {{.Status}}' > /tmp/e2e-ps.txt 2>/dev/null || true
ok=1
for svc in postgres n8n ollama truth-extractor mock-search mock-crawl mock-engine; do
  grep -q "geo-operator-${svc}.*healthy" /tmp/e2e-ps.txt || { echo "  !! ${svc} not healthy"; ok=0; }
done
[ "$ok" -eq 1 ] && pass "L0_stack_sanity" || fail "L0_stack_sanity"

# ---------------------------------------------------------------------------
# L1 — clean DB
# ---------------------------------------------------------------------------
say "L1: clean DB"
${PSQL} -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" >/dev/null 2>&1 && pass "L1_clean_db" || fail "L1_clean_db"

# ---------------------------------------------------------------------------
# L2 — migrations + views
# ---------------------------------------------------------------------------
say "L2: migrations + views"
${BASE_COMPOSE} exec -T -e PGUSER=geo_operator -e PGDATABASE=geo_operator postgres bash /srv/db/run-migrations.sh >/tmp/e2e-mig.log 2>&1 \
  && ${BASE_COMPOSE} exec -T -e PGUSER=geo_operator -e PGDATABASE=geo_operator postgres bash /srv/db/apply-views.sh >/tmp/e2e-views.log 2>&1 \
  && pass "L2_db_reproducible" || { fail "L2_db_reproducible"; tail -n 20 /tmp/e2e-mig.log | sed 's/^/    /'; }

# ---------------------------------------------------------------------------
# L3 — seeds (minimal system config ONLY; N8N-E2E tenants carry NO business data)
# ---------------------------------------------------------------------------
say "L3: seeds (system config only, no business-chain seed)"
# The E2E gate must NOT run the full seed suite: run-seeds.sh pre-loads the
# SYNTH-ACME synthetic business chain (truth/surfaces/intents/observations/
# gaps/content/publication), whose PENDING jobs would be claimed by the worker
# workflows and corrupt the N8N-E2E-A causal chain. Only synthetic_n8n_e2e.sql
# (clients + engine registry/adapters) may run.
${BASE_COMPOSE} exec -T -e PGUSER=geo_operator -e PGDATABASE=geo_operator postgres psql -U geo_operator -d geo_operator -v ON_ERROR_STOP=1 -q -f /srv/db/seeds/synthetic_n8n_e2e.sql >/tmp/e2e-seeds.log 2>&1 \
  && pass "L3_seeds" || { fail "L3_seeds"; tail -n 20 /tmp/e2e-seeds.log | sed 's/^/    /'; }
A_UUID="$(q "SELECT id::text FROM clients WHERE code='${TENANT}';")"
[ -n "$A_UUID" ] && pass "L3_tenant_a" || fail "L3_tenant_a (client missing)"

# ---------------------------------------------------------------------------
# L4 — import workflows (Git JSON is source of truth)
# ---------------------------------------------------------------------------
say "L4: import workflows"
# n8n import:workflow is NOT idempotent by name: repeated imports accumulate
# duplicate workflow rows whose webhook paths collide on activation. The n8n
# metadata DB is a DERIVED artifact, so wipe it (webhooks + workflows + history)
# before importing the Git JSON definitions fresh.
qn "TRUNCATE webhook_entity, workflow_entity, workflow_history CASCADE;" >/dev/null 2>&1 || true
${N8N} n8n import:workflow --input=/home/node/workflows --separate >/tmp/e2e-import.log 2>&1 && pass "L4_import" || { fail "L4_import"; tail -n 20 /tmp/e2e-import.log | sed 's/^/    /'; }
n8n_count="$(qn "SELECT count(*) FROM workflow_entity;")"
echo "    workflows in n8n after import: $n8n_count"
[ "$n8n_count" -ge 9 ] 2>/dev/null && pass "L4_import_count" || fail "L4_import_count (count=$n8n_count)"

# ---------------------------------------------------------------------------
# L5 — bind WF-99 error handler to worker workflows
# ---------------------------------------------------------------------------
say "L5: bind WF-99"
err_id="$(wfid 99)"
bound=0
if [ -n "$err_id" ] && [ "$err_id" != "__ERR__" ]; then
  for num in 04 05 06 07 08; do
    wid="$(wfid "$num")"
    if [ -n "$wid" ] && [ "$wid" != "__ERR__" ]; then
      qn "UPDATE workflow_entity SET settings = jsonb_set(COALESCE(settings,'{}')::jsonb, '{errorWorkflow}', '\"${err_id}\"'::jsonb) WHERE id = '${wid}';" >/dev/null 2>&1 || true
      bound=$((bound + 1))
    fi
  done
fi
if [ "$bound" -ge 5 ]; then pass "L5_wf99_binding"; else fail "L5_wf99_binding (bound=$bound err=$err_id)"; fi

# ---------------------------------------------------------------------------
# L6 — activate wf01..wf08
# ---------------------------------------------------------------------------
say "L6: activate workflows"
act_ok=0
for num in 01 02 03 04 05 06 07 08 99; do
  wid="$(wfid "$num")"
  if [ -n "$wid" ] && [ "$wid" != "__ERR__" ]; then
    ${N8N} n8n update:workflow --id="${wid}" --active=true >/dev/null 2>&1 || true
    act_ok=$((act_ok + 1))
  fi
done
[ "$act_ok" -ge 9 ] && pass "L6_activate" || fail "L6_activate (active=$act_ok)"
${BASE_COMPOSE} restart n8n >/dev/null 2>&1 || true
echo "  >> waiting for n8n (webhooks live)..."
hc=""
for i in $(seq 1 40); do
  hc="$(${BASE_COMPOSE} ps --format '{{.Status}}' n8n 2>/dev/null)"
  echo "$hc" | grep -q healthy && break
  sleep 3
done
echo "$hc" | grep -q healthy && pass "L6_n8n_healthy" || fail "L6_n8n_healthy (${hc})"
sleep 3

# ---------------------------------------------------------------------------
# L7 — verify ZERO business-chain state for N8N-E2E-A
# ---------------------------------------------------------------------------
say "L7: zero business state"
zero=1
for tbl in "entities" "claims" "surfaces" "surface_resources" "intents" "queries" \
           "engine_observations" "geo_gaps" "geo_actions" "content_briefs" \
           "content_assets" "publication_tasks" "publication_records" "reports"; do
  c="$(q "SELECT count(*) FROM ${tbl} WHERE client_id='${A_UUID}'::uuid;")"
  [ "$c" = "0" ] || { echo "  !! ${tbl} = ${c} (expected 0)"; zero=0; }
done
[ "$zero" -eq 1 ] && pass "L7_zero_state" || fail "L7_zero_state"

# ---------------------------------------------------------------------------
# L8/L9 — WF-01 (real PDF -> extractor -> Ollama -> import)
# ---------------------------------------------------------------------------
say "L8: run WF-01 (real PDF intake)"
pdf_rel="synthetic-${MARKER}.pdf"
doc_key="${MARKER}"
# 8.1 — write a REAL extractable-text PDF into the client's truth namespace.
${BASE_COMPOSE} exec -T truth-extractor python - "${A_UUID}" "${pdf_rel}" <<'PY' >/tmp/e2e-pdf.log 2>&1
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
# 8.2 — register the raw Truth doc (RECEIVED, no content) so WF-01 picks it up.
q "INSERT INTO truth_documents(client_id, import_key, document_type, title, source_uri, file_path, status, provided_by)
   VALUES ('${A_UUID}', '${doc_key}', 'PDF', 'True n8n E2E Profile ${RUN_ID}', NULL, '${pdf_rel}', 'RECEIVED', 'e2e')
   ON CONFLICT (import_key) WHERE import_key IS NOT NULL DO NOTHING;" >/dev/null
# 8.3 — fire the webhook (onReceived -> returns immediately).
wf01_id="$(wfid 01)"
TS_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
code="$(trigger "wf01-intake" "{\"clientCode\":\"${TENANT}\"}")"
echo "    webhook=$code"
execv="$(wait_exec "$wf01_id" "$TS_UTC" 420 "wf01")"
echo "    wf01 execution: $execv"
if [ -n "$execv" ] && [ "${execv#*:}" = "success" ]; then
  EXEC_WF01="${execv%%:*}"
else
  EXEC_WF01=""; fail "L8_wf01_execution (${execv})"
fi
# 8.4 — business assertions (the ONLY real proof).
sleep 2
marker="SYNTH-${doc_key}-"
N_CLAIMS="$(q "SELECT count(*) FROM claims WHERE client_id='${A_UUID}' AND import_key LIKE '${marker}%';")"
N_EVIDENCE="$(q "SELECT count(*) FROM evidence_items e JOIN claims c ON c.id=e.claim_id WHERE c.client_id='${A_UUID}' AND c.import_key LIKE '${marker}%';")"
N_ENTITIES="$(q "SELECT count(*) FROM entities WHERE client_id='${A_UUID}';")"
orphan="$(q "SELECT count(*) FROM claims WHERE client_id='${A_UUID}' AND import_key LIKE '${marker}%' AND entity_id IS NULL;")"
doc_status="$(q "SELECT status FROM truth_documents WHERE import_key='${doc_key}';")"
parsed="$(q "SELECT (parsed_at IS NOT NULL)::text FROM truth_documents WHERE import_key='${doc_key}';")"
if [ "${EXEC_WF01:-}" != "" ] && [ "$N_CLAIMS" -ge 1 ] 2>/dev/null \
   && [ "$N_EVIDENCE" -ge 1 ] 2>/dev/null && [ "$N_ENTITIES" -ge 1 ] 2>/dev/null \
   && [ "$orphan" = "0" ] && [ "$doc_status" = "PARSED" ] && [ "$parsed" = "true" ]; then
  pass "L9_wf01_business (claims=$N_CLAIMS entities=$N_ENTITIES evidence=$N_EVIDENCE orphan=$orphan)"
else
  fail "L9_wf01_business (exec=${EXEC_WF01:-none} claims=$N_CLAIMS entities=$N_ENTITIES evidence=$N_EVIDENCE orphan=$orphan doc=$doc_status parsed=$parsed)"
fi

# ---------------------------------------------------------------------------
# L10/L11 — WF-02 (surface discovery via mock search/crawl)
# ---------------------------------------------------------------------------
say "L10: run WF-02"
wf02_id="$(wfid 02)"
TS_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
code="$(trigger "wf02-discovery" "{\"clientCode\":\"${TENANT}\"}")"
echo "    webhook=$code"
execv="$(wait_exec "$wf02_id" "$TS_UTC" 240 "wf02")"
echo "    wf02 execution: $execv"
[ "${execv#*:}" = "success" ] && EXEC_WF02="${execv%%:*}" || { EXEC_WF02=""; fail "L10_wf02_execution (${execv})"; }
sleep 2
N_SURFACES="$(q "SELECT count(*) FROM surfaces WHERE client_id='${A_UUID}';")"
n_res="$(q "SELECT count(*) FROM surface_resources WHERE client_id='${A_UUID}';")"
n_ev="$(q "SELECT count(*) FROM evidence_items WHERE client_id='${A_UUID}' AND evidence_type='SURFACE_PRESENCE';")"
n_cross="$(q "SELECT count(*) FROM surfaces WHERE client_id='${A_UUID}' AND client_id <> (SELECT id FROM clients WHERE code='${TENANT}');")"
if [ "${EXEC_WF02:-}" != "" ] && [ "$N_SURFACES" -ge 1 ] 2>/dev/null \
   && [ "$n_res" -ge 1 ] 2>/dev/null && [ "$n_ev" -ge 1 ] 2>/dev/null && [ "$n_cross" = "0" ]; then
  pass "L11_wf02_business (surfaces=$N_SURFACES resources=$n_res evidence=$n_ev)"
else
  fail "L11_wf02_business (exec=${EXEC_WF02:-none} surfaces=$N_SURFACES resources=$n_res evidence=$n_ev cross=$n_cross)"
fi

# ---------------------------------------------------------------------------
# L12/L13 — WF-03 (intents + queries + scheduler)
# ---------------------------------------------------------------------------
say "L12: run WF-03"
wf03_id="$(wfid 03)"
TS_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
code="$(trigger "wf03-intent" "{\"clientCode\":\"${TENANT}\"}")"
echo "    webhook=$code"
execv="$(wait_exec "$wf03_id" "$TS_UTC" 300 "wf03")"
echo "    wf03 execution: $execv"
[ "${execv#*:}" = "success" ] && EXEC_WF03="${execv%%:*}" || { EXEC_WF03=""; fail "L12_wf03_execution (${execv})"; }
sleep 2
N_INTENTS="$(q "SELECT count(*) FROM intents WHERE client_id='${A_UUID}';")"
N_QUERIES="$(q "SELECT count(*) FROM queries WHERE client_id='${A_UUID}';")"
n_obsjobs="$(q "SELECT count(*) FROM jobs WHERE client_id='${A_UUID}' AND job_type='ENGINE_OBSERVATION' AND status IN ('PENDING','RUNNING','RETRY_WAIT');")"
n_payload_ok="$(q "SELECT count(*) FROM jobs WHERE client_id='${A_UUID}' AND job_type='ENGINE_OBSERVATION' AND (payload_json ? 'query_id') AND (payload_json ? 'engine_id') AND (payload_json ? 'scope') AND (payload_json ? 'run_date');")"
if [ "${EXEC_WF03:-}" != "" ] && [ "$N_INTENTS" -ge 1 ] 2>/dev/null && [ "$N_QUERIES" -ge 1 ] 2>/dev/null \
   && [ "$n_obsjobs" -ge 1 ] 2>/dev/null && [ "$n_payload_ok" -ge 1 ] 2>/dev/null; then
  pass "L13_wf03_business (intents=$N_INTENTS queries=$N_QUERIES obsjobs=$n_obsjobs payload_ok=$n_payload_ok)"
else
  fail "L13_wf03_business (exec=${EXEC_WF03:-none} intents=$N_INTENTS queries=$N_QUERIES obsjobs=$n_obsjobs payload_ok=$n_payload_ok)"
fi

# ---------------------------------------------------------------------------
# L14/L15 — WF-04 (observation via real adapter)
# ---------------------------------------------------------------------------
say "L14: run WF-04"
wf04_id="$(wfid 04)"
TS_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
code="$(trigger "wf04-observe" "{}")"
echo "    webhook=$code"
execv="$(wait_exec "$wf04_id" "$TS_UTC" 300 "wf04")"
echo "    wf04 execution: $execv"
[ "${execv#*:}" = "success" ] && EXEC_WF04="${execv%%:*}" || { EXEC_WF04=""; fail "L14_wf04_execution (${execv})"; }
sleep 2
N_OBS="$(q "SELECT count(*) FROM engine_observations WHERE client_id='${A_UUID}';")"
n_obs_lineage="$(q "SELECT count(*) FROM engine_observations o WHERE o.client_id='${A_UUID}' AND o.query_id IN (SELECT id FROM queries WHERE client_id='${A_UUID}');")"
if [ "${EXEC_WF04:-}" != "" ] && [ "$N_OBS" -ge 1 ] 2>/dev/null && [ "$n_obs_lineage" -ge 1 ] 2>/dev/null; then
  pass "L15_wf04_business (obs=$N_OBS lineage_ok=$n_obs_lineage)"
else
  fail "L15_wf04_business (exec=${EXEC_WF04:-none} obs=$N_OBS lineage_ok=$n_obs_lineage)"
fi

# ---------------------------------------------------------------------------
# L16/L17 — WF-05 (gap analysis + action planning via official scheduler)
# ---------------------------------------------------------------------------
say "L16: run WF-05"
q "SELECT schedule_gap_analysis_jobs('${TENANT}', 70, CURRENT_DATE);" >/dev/null
wf05_id="$(wfid 05)"
TS_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
code="$(trigger "wf05-gap-action" "{}")"
echo "    webhook=$code"
execv="$(wait_exec "$wf05_id" "$TS_UTC" 240 "wf05")"
echo "    wf05 execution: $execv"
[ "${execv#*:}" = "success" ] && EXEC_WF05="${execv%%:*}" || { EXEC_WF05=""; fail "L16_wf05_execution (${execv})"; }
sleep 2
N_GAPS="$(q "SELECT count(*) FROM geo_gaps WHERE client_id='${A_UUID}';")"
N_ACTIONS="$(q "SELECT count(*) FROM geo_actions WHERE client_id='${A_UUID}';")"
n_cjobs="$(q "SELECT count(*) FROM jobs WHERE client_id='${A_UUID}' AND job_type='CONTENT_FACTORY' AND status IN ('PENDING','RUNNING','RETRY_WAIT');")"
if [ "${EXEC_WF05:-}" != "" ] && [ "$N_GAPS" -ge 1 ] 2>/dev/null && [ "$N_ACTIONS" -ge 1 ] 2>/dev/null \
   && [ "$n_cjobs" -ge 1 ] 2>/dev/null; then
  pass "L17_wf05_business (gaps=$N_GAPS actions=$N_ACTIONS content_jobs=$n_cjobs)"
else
  fail "L17_wf05_business (exec=${EXEC_WF05:-none} gaps=$N_GAPS actions=$N_ACTIONS content_jobs=$n_cjobs)"
fi

# ---------------------------------------------------------------------------
# L18/L19 — WF-06 (content factory full closure)
# ---------------------------------------------------------------------------
say "L18: run WF-06"
wf06_id="$(wfid 06)"
TS_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
code="$(trigger "wf06-content" "{}")"
echo "    webhook=$code"
execv="$(wait_exec "$wf06_id" "$TS_UTC" 420 "wf06")"
echo "    wf06 execution: $execv"
[ "${execv#*:}" = "success" ] && EXEC_WF06="${execv%%:*}" || { EXEC_WF06=""; fail "L18_wf06_execution (${execv})"; }
sleep 2
N_CANONICAL="$(q "SELECT count(*) FROM content_assets WHERE client_id='${A_UUID}' AND surface_id IS NULL AND status='READY_TO_PUBLISH' AND fact_check_status='PASSED' AND compliance_status='PASSED';")"
N_ADAPTED="$(q "SELECT count(*) FROM content_assets WHERE client_id='${A_UUID}' AND surface_id IS NOT NULL AND status='READY_TO_PUBLISH' AND fact_check_status='PASSED' AND compliance_status='PASSED';")"
n_tasks="$(q "SELECT count(*) FROM publication_tasks WHERE client_id='${A_UUID}';")"
N_PUBJOBS="$(q "SELECT count(*) FROM jobs WHERE client_id='${A_UUID}' AND job_type='PUBLICATION' AND status IN ('PENDING','RUNNING','RETRY_WAIT');")"
if [ "${EXEC_WF06:-}" != "" ] && [ "$N_CANONICAL" -ge 1 ] 2>/dev/null && [ "$N_ADAPTED" -ge 1 ] 2>/dev/null \
   && [ "$n_tasks" -ge 1 ] 2>/dev/null && [ "$N_PUBJOBS" -ge 1 ] 2>/dev/null; then
  pass "L19_wf06_business (canonical=$N_CANONICAL adapted=$N_ADAPTED tasks=$n_tasks pubjobs=$N_PUBJOBS)"
else
  fail "L19_wf06_business (exec=${EXEC_WF06:-none} canonical=$N_CANONICAL adapted=$N_ADAPTED tasks=$n_tasks pubjobs=$N_PUBJOBS)"
fi

# ---------------------------------------------------------------------------
# L20/L21 — WF-07 (manual publication closure)
# ---------------------------------------------------------------------------
say "L20: run WF-07"
wf07_id="$(wfid 07)"
TS_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
code="$(trigger "wf07-publish" "{}")"
echo "    webhook=$code"
execv="$(wait_exec "$wf07_id" "$TS_UTC" 240 "wf07")"
echo "    wf07 execution: $execv"
[ "${execv#*:}" = "success" ] && EXEC_WF07="${execv%%:*}" || { EXEC_WF07=""; fail "L20_wf07_execution (${execv})"; }
sleep 2
N_WAITING="$(q "SELECT count(*) FROM publication_tasks WHERE client_id='${A_UUID}' AND status='WAITING_APPROVAL';")"
N_PUBREC="$(q "SELECT count(*) FROM publication_records WHERE publication_task_id IN (SELECT id FROM publication_tasks WHERE client_id='${A_UUID}');")"
n_ext="$(q "SELECT count(*) FROM publication_records pr JOIN publication_tasks t ON t.id=pr.publication_task_id WHERE t.client_id='${A_UUID}' AND (pr.external_id IS NOT NULL OR pr.published_at IS NOT NULL);")"
if [ "${EXEC_WF07:-}" != "" ] && [ "$N_WAITING" -ge 1 ] 2>/dev/null && [ "$N_PUBREC" = "0" ] && [ "$n_ext" = "0" ]; then
  pass "L21_wf07_business (waiting=$N_WAITING records=$N_PUBREC ext_or_published=$n_ext)"
else
  fail "L21_wf07_business (exec=${EXEC_WF07:-none} waiting=$N_WAITING records=$N_PUBREC ext_or_published=$n_ext)"
fi

# ---------------------------------------------------------------------------
# L22/L23 — WF-08 (reporting over the real chain)
# ---------------------------------------------------------------------------
say "L22: run WF-08"
q "SELECT enqueue_job('${A_UUID}', 'REPORT', jsonb_build_object('report_type','WEEKLY','period_start',(CURRENT_DATE - 7)::text,'period_end',CURRENT_DATE::text), 50, now(), 3, 'e2e-report:${RUN_ID}');" >/dev/null
wf08_id="$(wfid 08)"
TS_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
code="$(trigger "wf08-report" "{}")"
echo "    webhook=$code"
execv="$(wait_exec "$wf08_id" "$TS_UTC" 240 "wf08")"
echo "    wf08 execution: $execv"
[ "${execv#*:}" = "success" ] && EXEC_WF08="${execv%%:*}" || { EXEC_WF08=""; fail "L22_wf08_execution (${execv})"; }
sleep 2
N_REPORTS="$(q "SELECT count(*) FROM reports WHERE client_id='${A_UUID}' AND period_end >= (CURRENT_DATE - 1);")"
n_obs_metric="$(q "SELECT COALESCE((metrics->>'observations')::int,0) FROM reports WHERE client_id='${A_UUID}' ORDER BY generated_at DESC LIMIT 1;")"
if [ "${EXEC_WF08:-}" != "" ] && [ "$N_REPORTS" -ge 1 ] 2>/dev/null && [ "$n_obs_metric" -ge 1 ] 2>/dev/null; then
  pass "L23_wf08_business (reports=$N_REPORTS obs_metric=$n_obs_metric)"
else
  fail "L23_wf08_business (exec=${EXEC_WF08:-none} reports=$N_REPORTS obs_metric=$n_obs_metric)"
fi

# ---------------------------------------------------------------------------
# L24 — WF-99 real fault injection (TEST_HTTP_FAIL adapter -> 500 -> WF-99)
# ---------------------------------------------------------------------------
say "L24: WF-99 fault injection"
eng_id="$(q "SELECT id::text FROM engines WHERE provider='TEST_HTTP_FAIL' LIMIT 1")"
# Enable the fault engine (system config, E2E window only).
q "UPDATE engines SET enabled=true WHERE id='${eng_id}'::uuid;
   UPDATE engine_adapters SET enabled=true, status='READY' WHERE engine_id='${eng_id}'::uuid AND adapter='TEST_HTTP_FAIL';" >/dev/null 2>&1 || true
q "SELECT schedule_observation_jobs('${TENANT}', 'FAULT_TEST', ARRAY['${eng_id}'::uuid], CURRENT_DATE, 1, 100);" >/dev/null
fault_job="$(q "SELECT id::text FROM jobs WHERE client_id='${A_UUID}' AND payload_json->>'scope'='FAULT_TEST' ORDER BY created_at DESC LIMIT 1;")"
TS_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
code="$(trigger "wf04-observe" "{}")"
echo "    webhook=$code"
execv="$(wait_exec "$wf04_id" "$TS_UTC" 180 "wf04-fault")"
echo "    wf04(fault) execution: $execv"
[ "${execv#*:}" = "error" ] && WF04_FAIL_EXEC="${execv%%:*}" || { WF04_FAIL_EXEC=""; fail "L24_wf04_error (${execv})"; }
sleep 2
# WF-99 should have run and failed the job.
wf99_id="$(wfid 99)"
TS99="$(date -u -d "-120 seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$TS_UTC")"
exec99="$(wait_exec "$wf99_id" "$TS99" 120 "wf99")"
echo "    wf99 execution: $exec99"
[ "${exec99#*:}" = "success" ] && WF99_EXEC="${exec99%%:*}" || { WF99_EXEC=""; fail "L24_wf99_execution (${exec99})"; }
job_status="$(q "SELECT status FROM jobs WHERE id='${fault_job}'::uuid;")"
job_err="$(q "SELECT (last_error IS NOT NULL)::text FROM jobs WHERE id='${fault_job}'::uuid;")"
job_attempts="$(q "SELECT attempts FROM jobs WHERE id='${fault_job}'::uuid;")"
if [ "${WF04_FAIL_EXEC:-}" != "" ] && [ "${WF99_EXEC:-}" != "" ] \
   && [ "$job_status" = "RETRY_WAIT" ] && [ "$job_err" = "true" ] && [ "$job_attempts" -lt 3 ] 2>/dev/null; then
  pass "L24_fault_path (wf04=$WF04_FAIL_EXEC wf99=$WF99_EXEC job=$job_status attempts=$job_attempts)"
else
  fail "L24_fault_path (wf04=${WF04_FAIL_EXEC:-none} wf99=${WF99_EXEC:-none} job=$job_status err=$job_err attempts=$job_attempts)"
fi
# Cleanup: cancel the fault job + disable the fault engine before L26.
q "UPDATE jobs SET status='CANCELLED' WHERE id='${fault_job}'::uuid;
   UPDATE engines SET enabled=false WHERE id='${eng_id}'::uuid;
   UPDATE engine_adapters SET enabled=false, status='UNSUPPORTED' WHERE engine_id='${eng_id}'::uuid AND adapter='TEST_HTTP_FAIL';" >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# L25 — cross-client WF-07 runtime attack
# ---------------------------------------------------------------------------
say "L25: cross-client WF-07 attack"
b_uuid="$(q "SELECT id::text FROM clients WHERE code='${TENANT_B}';")"
b_task="$(q "SELECT id::text FROM publication_tasks WHERE dedup_key='N8N-E2E-B-TASK-ATTACK' LIMIT 1;")"
if [ -z "$b_task" ] || [ "$b_task" = "__ERR__" ]; then
  # Minimal B attack fixture (allowed by the gate: B task only, SYNTHETIC).
  b_surf="$(q "SELECT upsert_surface('${TENANT_B}','WEBSITE','OFFICIAL_SITE',NULL,'https://shadowe2e-b.example',NULL,'MANUAL_REQUIRED',NULL,'N8N-E2E-B-SURF-ATTACK');")"
  b_brief="$(q "INSERT INTO content_briefs(client_id, canonical_angle, required_claim_ids, target_surfaces, status, dedup_key)
    SELECT id, 'B attack fixture angle (SYNTHETIC)', '[]'::jsonb, '[]'::jsonb, 'READY', 'N8N-E2E-B-BRIEF-ATTACK'
    FROM clients WHERE code='${TENANT_B}'
    ON CONFLICT (dedup_key) WHERE dedup_key IS NOT NULL DO NOTHING RETURNING id::text;")"
  [ -z "$b_brief" ] && b_brief="$(q "SELECT id::text FROM content_briefs WHERE dedup_key='N8N-E2E-B-BRIEF-ATTACK' LIMIT 1;")"
  b_asset="$(q "INSERT INTO content_assets(client_id, brief_id, format, title, body, status, fact_check_status, compliance_status, dedup_key)
    SELECT id, '${b_brief}', 'MARKDOWN', 'B attack fixture (SYNTHETIC)', 'B fixture body.', 'READY_TO_PUBLISH', 'PASSED', 'PASSED', 'N8N-E2E-B-ASSET-ATTACK'
    FROM clients WHERE code='${TENANT_B}'
    ON CONFLICT (dedup_key) WHERE dedup_key IS NOT NULL DO NOTHING RETURNING id::text;")"
  [ -z "$b_asset" ] && b_asset="$(q "SELECT id::text FROM content_assets WHERE dedup_key='N8N-E2E-B-ASSET-ATTACK' LIMIT 1;")"
  b_task="$(q "INSERT INTO publication_tasks(client_id, surface_id, content_asset_id, mode, status, dedup_key)
    SELECT id, '${b_surf}', '${b_asset}', 'MANUAL_REQUIRED', 'DRAFT', 'N8N-E2E-B-TASK-ATTACK'
    FROM clients WHERE code='${TENANT_B}'
    ON CONFLICT (dedup_key) WHERE dedup_key IS NOT NULL DO NOTHING RETURNING id::text;")"
  [ -z "$b_task" ] && b_task="$(q "SELECT id::text FROM publication_tasks WHERE dedup_key='N8N-E2E-B-TASK-ATTACK' LIMIT 1;")"
fi
# A job whose payload references B's task.
q "SELECT enqueue_job('${A_UUID}', 'PUBLICATION', jsonb_build_object('task_id','${b_task}'), 100, now(), 3, 'e2e-cross:${RUN_ID}');" >/dev/null
TS_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
code="$(trigger "wf07-publish" "{}")"
echo "    webhook=$code"
execv="$(wait_exec "$wf07_id" "$TS_UTC" 180 "wf07-cross")"
echo "    wf07(cross) execution: $execv"
[ "${execv#*:}" = "success" ] || fail "L25_wf07_cross_execution (${execv})"
sleep 2
CROSS_JOB_STATUS="$(q "SELECT status FROM jobs WHERE unique_key='e2e-cross:${RUN_ID}';")"
b_task_after="$(q "SELECT status FROM publication_tasks WHERE id='${b_task}'::uuid;")"
n_cross_exc="$(q "SELECT count(*) FROM exceptions WHERE client_id='${A_UUID}' AND exception_type='CROSS_CLIENT_REFERENCE';")"
n_rec="$(q "SELECT count(*) FROM publication_records WHERE publication_task_id='${b_task}'::uuid;")"
if [ "${execv#*:}" = "success" ] && [ "$CROSS_JOB_STATUS" != "SUCCEEDED" ] \
   && [ "$b_task_after" = "DRAFT" ] && [ "$n_cross_exc" -ge 1 ] 2>/dev/null && [ "$n_rec" = "0" ]; then
  pass "L25_cross_client (job=$CROSS_JOB_STATUS b_task=$b_task_after exc=$n_cross_exc)"
else
  fail "L25_cross_client (job=$CROSS_JOB_STATUS b_task=$b_task_after exc=$n_cross_exc rec=$n_rec)"
fi
# cleanup: cancel the cross job
q "UPDATE jobs SET status='CANCELLED' WHERE unique_key='e2e-cross:${RUN_ID}';" >/dev/null

# ---------------------------------------------------------------------------
# L26 — max_attempts=3 real runtime exhaustion
# ---------------------------------------------------------------------------
say "L26: max_attempts=3 runtime exhaustion"
q "UPDATE engines SET enabled=true WHERE id='${eng_id}'::uuid;
   UPDATE engine_adapters SET enabled=true, status='READY' WHERE engine_id='${eng_id}'::uuid AND adapter='TEST_HTTP_FAIL';" >/dev/null 2>&1 || true
q "SELECT schedule_observation_jobs('${TENANT}', 'EXHAUST_TEST', ARRAY['${eng_id}'::uuid], CURRENT_DATE, 1, 100);" >/dev/null
ex_job="$(q "SELECT id::text FROM jobs WHERE client_id='${A_UUID}' AND payload_json->>'scope'='EXHAUST_TEST' ORDER BY created_at DESC LIMIT 1;")"
for attempt in 1 2 3; do
  TS_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  code="$(trigger "wf04-observe" "{}")"
  execv="$(wait_exec "$wf04_id" "$TS_UTC" 120 "wf04-exh${attempt}")"
  echo "    attempt ${attempt}: wf04=$execv"
  sleep 2
  # WF-99 fail_job already ran; open the backoff window for the next claim.
  q "UPDATE jobs SET due_at = now() - interval '1 second' WHERE id='${ex_job}'::uuid;" >/dev/null
done
RETRY_ATTEMPTS="$(q "SELECT attempts FROM jobs WHERE id='${ex_job}'::uuid;")"
RETRY_JOB_STATUS="$(q "SELECT status FROM jobs WHERE id='${ex_job}'::uuid;")"
ex_last_err="$(q "SELECT (last_error IS NOT NULL)::text FROM jobs WHERE id='${ex_job}'::uuid;")"
if [ "$RETRY_ATTEMPTS" = "3" ] && [ "$RETRY_JOB_STATUS" = "FAILED" ] && [ "$ex_last_err" = "true" ]; then
  pass "L26_retry_exhaustion (attempts=$RETRY_ATTEMPTS status=$RETRY_JOB_STATUS)"
else
  fail "L26_retry_exhaustion (attempts=$RETRY_ATTEMPTS status=$RETRY_JOB_STATUS last_err=$ex_last_err)"
fi
q "UPDATE engines SET enabled=false WHERE id='${eng_id}'::uuid;
   UPDATE engine_adapters SET enabled=false, status='UNSUPPORTED' WHERE engine_id='${eng_id}'::uuid AND adapter='TEST_HTTP_FAIL';" >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# L27 — artifact
# ---------------------------------------------------------------------------
say "L27: artifact"
VERDICT="$(verdict)"
TS_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
st_ok L24_fault_path  && ERR_ST="PASS" || ERR_ST="FAIL"
st_ok L25_cross_client && ISO_ST="PASS" || ISO_ST="FAIL"
st_ok L26_retry_exhaustion && RET_ST="PASS" || RET_ST="FAIL"
mkdir -p "${ARTIFACT_DIR}"
# jq / python are NOT guaranteed on the host; build the artifact with bash.
# All values here are plain strings/numbers so concatenation is safe.
stages_json="$(tr '\n' ' ' < "$STAGES_FILE" | sed 's/}\s*{/},{/g')"
[ -n "$stages_json" ] && stages_json="[${stages_json}]" || stages_json="[]"
wf01s="missing"; [ -n "$EXEC_WF01" ] && wf01s="success"
{
  printf '{\n  "commit": "%s",\n' "$COMMIT"
  printf '  "run_id": "%s",\n' "$RUN_ID"
  printf '  "tenant": "%s",\n' "$TENANT"
  printf '  "verdict": "%s",\n' "$VERDICT"
  printf '  "started_at": "%s",\n' "$TS_UTC"
  printf '  "wf01": {"execution_id": "%s", "status": "%s", "entities_created": %s, "claims_created": %s, "evidence_created": %s},\n' "$EXEC_WF01" "$wf01s" "$N_ENTITIES" "$N_CLAIMS" "$N_EVIDENCE"
  printf '  "wf02": {"execution_id": "%s", "surfaces_created": %s},\n' "$EXEC_WF02" "$N_SURFACES"
  printf '  "wf03": {"execution_id": "%s", "intents_created": %s, "queries_created": %s},\n' "$EXEC_WF03" "$N_INTENTS" "$N_QUERIES"
  printf '  "wf04": {"execution_id": "%s", "observations_created": %s},\n' "$EXEC_WF04" "$N_OBS"
  printf '  "wf05": {"execution_id": "%s", "gaps_created": %s, "actions_created": %s},\n' "$EXEC_WF05" "$N_GAPS" "$N_ACTIONS"
  printf '  "wf06": {"execution_id": "%s", "canonical_assets": %s, "adapted_assets": %s, "publication_jobs": %s},\n' "$EXEC_WF06" "$N_CANONICAL" "$N_ADAPTED" "$N_PUBJOBS"
  printf '  "wf07": {"execution_id": "%s", "waiting_approval": %s, "publication_records": %s},\n' "$EXEC_WF07" "$N_WAITING" "$N_PUBREC"
  printf '  "wf08": {"execution_id": "%s", "reports_created": %s},\n' "$EXEC_WF08" "$N_REPORTS"
  printf '  "error_path": {"worker_execution_id": "%s", "wf99_execution_id": "%s", "status": "%s"},\n' "$WF04_FAIL_EXEC" "$WF99_EXEC" "$ERR_ST"
  printf '  "tenant_isolation": {"status": "%s", "cross_job_status": "%s"},\n' "$ISO_ST" "$CROSS_JOB_STATUS"
  printf '  "retry_exhaustion": {"attempts": %s, "final_status": "%s", "status": "%s"},\n' "$RETRY_ATTEMPTS" "$RETRY_JOB_STATUS" "$RET_ST"
  printf '  "stages": %s\n' "$stages_json"
  printf '}\n'
} > "${ARTIFACT}"
echo "    verdict: ${VERDICT}"
echo "    artifact: ${ARTIFACT}"
echo "    wf execs: wf01=$EXEC_WF01 wf02=$EXEC_WF02 wf03=$EXEC_WF03 wf04=$EXEC_WF04 wf05=$EXEC_WF05 wf06=$EXEC_WF06 wf07=$EXEC_WF07 wf08=$EXEC_WF08"

# ---------------------------------------------------------------------------
# L28 — deactivate workflows (restore conservative state)
# ---------------------------------------------------------------------------
say "L28: deactivate workflows"
for num in 01 02 03 04 05 06 07 08 99; do
  wid="$(wfid "$num")"
  if [ -n "$wid" ] && [ "$wid" != "__ERR__" ]; then
    ${N8N} n8n update:workflow --id="${wid}" --active=false >/dev/null 2>&1 || true
  fi
done
${BASE_COMPOSE} restart n8n >/dev/null 2>&1 || true
pass "L28_deactivate"

# ---------------------------------------------------------------------------
# L29 — verdict
# ---------------------------------------------------------------------------
say "L29: verdict"
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo ">> TRUE N8N FULL-CHAIN = SHADOW_RUN_READY"
else
  echo ">> TRUE N8N FULL-CHAIN = SHADOW_RUN_BLOCKED (${FAIL_COUNT} failure(s))"
fi
rm -f "$STAGES_FILE"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
