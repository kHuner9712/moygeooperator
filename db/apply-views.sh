#!/usr/bin/env bash
# geo-operator view runner: applies db/views/*.sql (idempotent CREATE OR REPLACE).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VIEWS_DIR="${SCRIPT_DIR}/views"
DB_CONN="${PGDATABASE:-${POSTGRES_DB:-geo_operator}}"

for f in "${VIEWS_DIR}"/*.sql; do
  [ -e "$f" ] || continue
  echo ">> apply view $(basename "$f")"
  psql -d "${DB_CONN}" -v ON_ERROR_STOP=1 -q -f "${f}"
done
echo ">> views done."