# geo-operator migration runner (PowerShell, for Windows host).
# Same semantics as run-migrations.sh. Requires psql on PATH.
# Connection via PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE env vars.
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$migrationsDir = Join-Path $scriptDir 'migrations'
$dbConn = if ($env:PGDATABASE) { $env:PGDATABASE } else { 'geo_operator' }

Write-Host ">> Migration target database: $dbConn"

& psql -d $dbConn -v ON_ERROR_STOP=1 -q -c @"
CREATE TABLE IF NOT EXISTS schema_migrations (
  version text PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
);
"@
if ($LASTEXITCODE -ne 0) { throw 'failed to init schema_migrations' }

$applied = 0
Get-ChildItem -Path $migrationsDir -Filter '*.sql' | Sort-Object Name | ForEach-Object {
  $version = $_.BaseName
  if ($version -notmatch '^[0-9]') { return }
  $existing = & psql -d $dbConn -At -c "SELECT 1 FROM schema_migrations WHERE version = '$version'"
  if ($LASTEXITCODE -ne 0) { throw "failed to check $version" }
  if ($existing -eq '1') { Write-Host "   skip $version"; return }

  Write-Host ">> apply $version"
  & psql -d $dbConn -v ON_ERROR_STOP=1 -q -f $_.FullName
  if ($LASTEXITCODE -ne 0) { throw "failed to apply $version" }
  & psql -d $dbConn -v ON_ERROR_STOP=1 -q -c "INSERT INTO schema_migrations(version) VALUES ('$version')"
  if ($LASTEXITCODE -ne 0) { throw "failed to record $version" }
  $applied++
}

Write-Host ">> done. applied=$applied pending=0"