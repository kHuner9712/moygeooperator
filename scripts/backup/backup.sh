#!/usr/bin/env bash
# geo-operator backup: nightly PostgreSQL dump of the System-of-Record DB.
# Retention: KEEP_DAILY daily .dump + KEEP_WEEKLY weekly .dump (kept on mondays).
# Usage: BACKUP_DIR=/srv/geo-operator/backups ./scripts/backup/backup.sh
# Requires psql/pg_dump (run inside postgres container or with db tools on PATH).
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/srv/geo-operator/backups}"
KEEP_DAILY="${BACKUP_KEEP_DAILY:-7}"
KEEP_WEEKLY="${BACKUP_KEEP_WEEKLY:-4}"
DB_NAME="${PGDATABASE:-${POSTGRES_DB:-geo_operator}}"

mkdir -p "${BACKUP_DIR}/daily" "${BACKUP_DIR}/weekly"

stamp="$(date +%Y%m%d_%H%M%S)"
dow="$(date +%u)"   # 1=Mon..7=Sun

daily="${BACKUP_DIR}/daily/${DB_NAME}_daily_${stamp}.dump"
echo ">> dump daily -> ${daily}"
pg_dump -d "${DB_NAME}" -Fc -f "${daily}"

# Weekly: promote monday's dump into the weekly folder as well.
if [ "${dow}" = "1" ]; then
  weekly="${BACKUP_DIR}/weekly/${DB_NAME}_weekly_${stamp}.dump"
  echo ">> promote to weekly -> ${weekly}"
  cp "${daily}" "${weekly}"
fi

# Retention.
ls -1t "${BACKUP_DIR}/daily"/${DB_NAME}_daily_*.dump 2>/dev/null | tail -n +$((KEEP_DAILY + 1)) | xargs -r rm -f
ls -1t "${BACKUP_DIR}/weekly"/${DB_NAME}_weekly_*.dump 2>/dev/null | tail -n +$((KEEP_WEEKLY + 1)) | xargs -r rm -f

echo ">> backup complete. daily kept=${KEEP_DAILY} weekly kept=${KEEP_WEEKLY}"