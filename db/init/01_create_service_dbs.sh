#!/bin/bash
# geo-operator postgres init (runs once on first volume creation).
# Creates the per-service metadata databases used by NocoDB and n8n.
# The business System-of-Record DB (POSTGRES_DB) is created by the image env.
set -euo pipefail

create_db_if_missing() {
  local db="$1"
  if [ -z "$db" ]; then return; fi
  exists="$(psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
    -tAc "SELECT 1 FROM pg_database WHERE datname = '${db}'")"
  if [ "$exists" = "1" ]; then
    echo ">> database ${db} already exists"
  else
    echo ">> creating database ${db}"
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
      -c "CREATE DATABASE \"${db}\""
  fi
}

create_db_if_missing "${NOCODB_DB:-nocodb}"
create_db_if_missing "${N8N_DB:-n8n}"