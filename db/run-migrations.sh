#!/usr/bin/env bash
# geo-operator migration runner (bash). Applies db/migrations/*.sql in order,
# each in its own transaction, recording versions in schema_migrations.
#
# Requirements: psql on PATH (or run inside the postgres container:
#   docker compose exec -T postgres /srv/db/run-migrations.sh)
# Connection: PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE env vars.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATIONS_DIR="${SCRIPT_DIR}/migrations"
DB_CONN="${PGDATABASE:-${POSTGRES_DB:-geo_operator}}"

echo ">> Migration target database: ${DB_CONN}"

# Ensure bookkeeping table exists.
psql -d "${DB_CONN}" -v ON_ERROR_STOP=1 -q -c \
  "CREATE TABLE IF NOT EXISTS schema_migrations (
     version text PRIMARY KEY,
     applied_at timestamptz NOT NULL DEFAULT now()
   );"

applied=0
for f in "${MIGRATIONS_DIR}"/[0-9]*.sql; do
  [ -e "$f" ] || continue
  version="$(basename "$f" .sql)"
  if psql -d "${DB_CONN}" -At -c \
      "SELECT 1 FROM schema_migrations WHERE version = '${version}'" | grep -q 1; then
    echo "   skip ${version} (already applied)"
    continue
  fi
  echo ">> apply ${version}"
  psql -d "${DB_CONN}" -v ON_ERROR_STOP=1 -q -f "${f}"
  psql -d "${DB_CONN}" -v ON_ERROR_STOP=1 -q -c \
    "INSERT INTO schema_migrations(version) VALUES ('${version}')"
  applied=$((applied + 1))
done

echo ">> done. applied=${applied} pending=0"