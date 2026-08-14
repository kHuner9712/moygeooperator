#!/usr/bin/env bash
# geo-operator seed runner: applies synthetic test fixtures in DEPENDENCY ORDER.
# Seeds are mutually dependent (engine_observation needs client+queries created
# by truth_pack/surface_intent), so alphabetical iteration is wrong. Each seed
# is idempotent (unique keys / ON CONFLICT) and safe to re-run.
#
# All seed data is SYNTHETIC test fixture ONLY — never a real business result.
# Usage:
#   docker compose exec -T postgres bash /srv/db/run-seeds.sh
#   PGDATABASE=geo_operator ./db/run-seeds.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEEDS_DIR="${SCRIPT_DIR}/seeds"
DB_CONN="${PGDATABASE:-${POSTGRES_DB:-geo_operator}}"

# Explicit dependency order (do not reorder).
ORDER=(
  synthetic_truth_pack.sql
  synthetic_surface_intent.sql
  synthetic_engine_observation.sql
  synthetic_gap_action.sql
  synthetic_content_factory.sql
  synthetic_publication.sql
  synthetic_retest_reporting.sql
  synthetic_shadow_e2e.sql
  synthetic_n8n_e2e.sql
)

for s in "${ORDER[@]}"; do
  f="${SEEDS_DIR}/${s}"
  [ -f "$f" ] || { echo ">> WARN: missing seed ${s} (skipped)"; continue; }
  echo ">> apply seed ${s}"
  psql -d "${DB_CONN}" -v ON_ERROR_STOP=1 -q -f "${f}"
done
echo ">> seeds done."