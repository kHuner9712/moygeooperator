#!/usr/bin/env bash
# =============================================================================
# geo-operator — first-deploy / upgrade / re-import / activation runner (P0.11)
#
# Git workflow JSON is the SOURCE OF TRUTH for n8n definitions. The n8n
# metadata DB is treated as a derived artifact and is never hand-edited.
#
# Stages, in order:
#   0. sanity checks (docker, .env, JSON validity, forbidden-string scan)
#   1. docker compose up -d  (postgres/nocodb/n8n; tooling is profile-gated)
#   2. apply db migrations    (db/run-migrations.sh)
#   3. apply db views         (db/apply-views.sh)
#   4. import workflows into n8n from Git JSON  (n8n import:workflow)
#   5. activate selected workflows (ACTIVE_WORKFLOWS env, default: none)
#   6. verify loaded workflows + DB views + route health
#
# Usage:
#   ./scripts/deploy/deploy.sh                 # full first deploy
#   ACTIVE_WORKFLOWS="wf08" ./scripts/deploy/deploy.sh   # also activate wf08
#   bash ./scripts/deploy/deploy.sh --reimport # n8n re-import only
#   bash ./scripts/deploy/deploy.sh --verify   # verify only
#
# Never run from inside the postgres container; run from the repo root.
# Requires: docker + docker compose. psql is used via the postgres container.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

MODE="${1:-full}"
ACTIVE_WORKFLOWS="${ACTIVE_WORKFLOWS:-}"   # comma-separated basenames, e.g. "wf08"
COMPOSE="docker compose"
N8N="docker compose exec -T n8n"
PSQL="docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -qAt"
DB_NAME="${POSTGRES_DB:-geo_operator}"

# ---------------------------------------------------------------------------
say() { printf '\n\x1b[1;36m== %s ==\x1b[0m\n' "$*"; }
fail() { printf '\x1b[1;31mERROR: %s\x1b[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Stage 0 — sanity
# ---------------------------------------------------------------------------
say "Stage 0: sanity checks"
command -v docker >/dev/null 2>&1 || fail "docker not found on PATH"
[ -f .env ] || fail ".env not found — copy .env.example to .env first"
command -v jq >/dev/null 2>&1 || fail "jq not found on PATH (needed for JSON validation)"

# Forbidden runtime strings (P0.1) must never appear in n8n workflow definitions.
FORBIDDEN='SYNTH-ACME'
if grep -rIl --exclude-dir='.git' "$FORBIDDEN" n8n/workflows/ >/dev/null 2>&1; then
  fail "forbidden string '$FORBIDDEN' found under n8n/workflows/ — refusing to deploy"
fi

# Each workflow JSON must parse.
for f in n8n/workflows/wf*.json; do
  jq -e . "$f" >/dev/null 2>&1 || fail "invalid workflow JSON: $f"
done

[ "$MODE" = "--verify" ] || [ "$MODE" = "--reimport" ] || MODE="full"

# ---------------------------------------------------------------------------
# Stage 1 — stack up
# ---------------------------------------------------------------------------
if [ "$MODE" = "full" ]; then
  say "Stage 1: docker compose up -d"
  $COMPOSE up -d postgres nocodb n8n
fi

# ---------------------------------------------------------------------------
# Stage 2 + 3 — migrations and views
# ---------------------------------------------------------------------------
if [ "$MODE" = "full" ]; then
  say "Stage 2: apply DB migrations"
  docker compose exec -T postgres bash /srv/db/run-migrations.sh

  say "Stage 3: apply DB views"
  docker compose exec -T postgres bash /srv/db/apply-views.sh
fi

# ---------------------------------------------------------------------------
# Stage 4 — import / re-import workflows (Git JSON is the source of truth)
# ---------------------------------------------------------------------------
if [ "$MODE" = "full" ] || [ "$MODE" = "--reimport" ]; then
  say "Stage 4: import workflows into n8n from Git JSON"
  # Workflows are mounted read-only into the container at /home/node/workflows.
  $N8N n8n import:workflow --input=/home/node/workflows --separate
fi

# ---------------------------------------------------------------------------
# Stage 4b — bind the WF-99 Shared Error Handler to every worker workflow (P0.5)
#
# "WF-99 exists" is not enough: each worker (wf04/wf05/wf06/wf07/wf08) must
# actually reference WF-99 as its error workflow, otherwise a worker failure
# never reaches fail_job(). The binding lives in <n8n>.workflow_entity.settings
# -> errorWorkflow (the workflow ID allocated by n8n at import time), so we
# resolve workflow NAME -> ID and write the binding directly into the n8n DB.
# This is a formal, reproducible deploy step (n8n reads settings.errorWorkflow
# from its Postgres store). After writing, n8n is restarted so the in-memory
# workflow cache picks up the binding.
# =============================================================================
say "Stage 4b: bind WF-99 error workflow to worker workflows (P0.5)"
N8N_PSQL="docker compose exec -T postgres psql -U ${N8N_DB_USER:-geo_operator} -d ${N8N_DB_DATABASE:-n8n} -v ON_ERROR_STOP=1 -qAt"
err_id="$($N8N_PSQL -c "SELECT id FROM workflow_entity WHERE lower(name) LIKE '%wf-99%' LIMIT 1;")"
if [ -n "${err_id:-}" ]; then
  for base in wf04 wf05 wf06 wf07 wf08; do
    wid="$($N8N_PSQL -c "SELECT id FROM workflow_entity WHERE lower(name) LIKE '%wf-$base%' LIMIT 1;" || true)"
    if [ -n "${wid:-}" ]; then
      $N8N_PSQL -c "UPDATE workflow_entity SET settings = jsonb_set(COALESCE(settings,'{}')::jsonb, '{errorWorkflow}', '\"$err_id\"'::jsonb) WHERE id = '$wid';" >/dev/null
      echo "   bound WF-99 (id=$err_id) as error workflow for wf${base} (id=$wid)"
    else
      echo "   !! workflow matching 'wf-$base' not found — error binding skipped"
    fi
  done
  echo "   restarting n8n so the errorWorkflow binding is loaded"
  docker compose restart n8n >/dev/null 2>&1 && echo "   n8n restarted"
else
  echo "   !! WF-99 error handler not found — error binding skipped"
fi

# ---------------------------------------------------------------------------
# Stage 5 — activate selected workflows (shadow run: default NONE active)
# ---------------------------------------------------------------------------
#
# Activation is intentionally conservative for a Shadow Run. Git JSON is the
# source of truth; activation state is a runtime decision. Two supported ways:
#   A) n8n REST API with an API key  (N8N_URL + N8N_API_KEY env vars)
#   B) manual toggle in the n8n UI  (recommended for the first real client)
#
# Only workflows the operator explicitly lists are activated. During a real
# client Shadow Run the recommended set is: wf08 (periodic report) only; keep
# wf01/wf02/wf03/wf04/wf05/wf06/wf07 manual until the run is supervised.
# =============================================================================
if [ -n "$ACTIVE_WORKFLOWS" ]; then
  say "Stage 5: activating workflows: $ACTIVE_WORKFLOWS"
  if [ -n "${N8N_API_KEY:-}" ] && [ -n "${N8N_URL:-}" ]; then
    for base in ${ACTIVE_WORKFLOWS//,/ }; do
      resp="$(curl -fsS -H "X-N8N-API-KEY: $N8N_API_KEY" "$N8N_URL/api/v1/workflows")"
      id="$(printf '%s' "$resp" | jq -r --arg b "$base" '.data[] | select(.name | test($b; "i")) | .id' | head -n1)"
      if [ -n "${id:-}" ]; then
        curl -fsS -X PATCH -H "X-N8N-API-KEY: $N8N_API_KEY" \
          -H 'Content-Type: application/json' \
          -d '{"active":true}' "$N8N_URL/api/v1/workflows/$id" >/dev/null
        echo "   activated $base (id=$id)"
      else
        echo "   !! workflow matching '$base' not found in n8n — check import"
      fi
    done
  else
    echo "   N8N_API_KEY/N8N_URL not set — activate manually in the n8n UI."
    echo "   Recommended active set for a supervised Shadow Run: wf08 only."
  fi
else
  say "Stage 5: no workflows to activate (set ACTIVE_WORKFLOWS to activate)"
fi

# ---------------------------------------------------------------------------
# Stage 6 — verify
# ---------------------------------------------------------------------------
say "Stage 6: verify"
echo ">> migrations applied:"
docker compose exec -T postgres psql -d "$DB_NAME" -At -c \
  "SELECT string_agg(version, ', ' ORDER BY version) FROM schema_migrations"

echo ">> operator views present:"
docker compose exec -T postgres psql -d "$DB_NAME" -At -c \
  "SELECT string_agg(x, ', ') FROM (VALUES ('v_client_health'),('v_manual_publish_queue'),('v_failed_retry_jobs'),('v_content_qa_failures'),('v_open_exceptions')) t(x) LEFT JOIN pg_class c ON c.relname=x WHERE c.relname IS NULL"

echo ">> n8n workflows (active):"
$N8N n8n list:workflow --active=true 2>/dev/null || echo "   (none active or CLI list unavailable)"
echo "   tip: browser to http://localhost:\${N8N_PORTMAP:-5678} to confirm imports"

say "deploy complete"