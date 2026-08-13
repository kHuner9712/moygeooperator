#!/usr/bin/env bash
# geo-operator health check: verifies DB connectivity, applied migrations,
# and that the jobs/exceptions queue is reachable. Exit 0 = healthy.
set -euo pipefail

DB_NAME="${PGDATABASE:-${POSTGRES_DB:-geo_operator}}"

echo ">> postgres reachable"
pg_isready -d "${DB_NAME}" -t 5

echo ">> schema_migrations applied:"
psql -d "${DB_NAME}" -At -c "SELECT version FROM schema_migrations ORDER BY version"

echo ">> queue tables present:"
psql -d "${DB_NAME}" -At -c \
  "SELECT to_regclass('jobs'), to_regclass('exceptions'), to_regclass('v_exception_queue')"

echo ">> open exceptions:"
psql -d "${DB_NAME}" -At -c "SELECT count(*) FROM exceptions WHERE status='OPEN'"