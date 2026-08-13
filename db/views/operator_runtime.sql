-- ============================================================================
-- Operator Runtime views (P0.10) for NocoDB / operator dashboard.
-- Read-only, exception-first. One operator can run ~20 clients from these.
-- All exception health/aggregation ONLY considers status='OPEN'.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Per-client health, exception-first. Every health driver is filtered to
-- OPEN exceptions only. A human approve-and-publish task must surface as
-- PUBLISH_REQUIRED (not hide as WAITING_APPROVAL).
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS v_client_health;
CREATE OR REPLACE VIEW v_client_health AS
SELECT
  c.id          AS client_id,
  c.code,
  c.display_name,
  c.status      AS client_status,
  COUNT(DISTINCT e.id) FILTER (WHERE e.status='OPEN' AND e.severity='CRITICAL') AS open_critical,
  COUNT(DISTINCT e.id) FILTER (WHERE e.status='OPEN' AND e.severity='HIGH')     AS open_high,
  COUNT(DISTINCT e.id) FILTER (WHERE e.status='OPEN')                            AS open_exceptions,
  COUNT(DISTINCT j.id) FILTER (WHERE j.status IN ('FAILED'))                    AS failed_jobs,
  COUNT(DISTINCT j.id) FILTER (WHERE j.status='RETRY_WAIT')                     AS retry_jobs,
  COUNT(DISTINCT j.id) FILTER (WHERE j.status IN ('PENDING','RETRY_WAIT')
                                    AND j.due_at <= now())                       AS overdue_jobs,
  COUNT(DISTINCT p.id) FILTER (WHERE p.status IN ('WAITING_APPROVAL','PUBLISHING')) AS manual_publish,
  CASE
    WHEN c.status IN ('PAUSED','ARCHIVED') THEN 'HEALTHY'
    WHEN COUNT(DISTINCT e.id) FILTER (WHERE e.status='OPEN' AND e.severity='CRITICAL') > 0
         OR COUNT(DISTINCT j.id) FILTER (WHERE j.status IN ('FAILED')) > 0
         THEN 'ERROR'
    WHEN COUNT(DISTINCT e.id) FILTER (WHERE e.status='OPEN'
            AND e.exception_type IN ('CLIENT_DATA_REQUIRED','PARSE_FAILED')) > 0
         THEN 'CLIENT_DATA_REQUIRED'
    WHEN COUNT(DISTINCT p.id) FILTER (WHERE p.status IN ('WAITING_APPROVAL','PUBLISHING')) > 0
         THEN 'PUBLISH_REQUIRED'
    WHEN COUNT(DISTINCT e.id) FILTER (WHERE e.status='OPEN'
            AND e.exception_type IN ('FACT_CONFLICT','CONTENT_QA_FAILED',
                                     'UNSUPPORTED_PLATFORM','CREDENTIAL_INVALID',
                                     'PLATFORM_POLICY','UNSUPPORTED_ENGINE')) > 0
         THEN 'ACTION_REQUIRED'
    ELSE 'HEALTHY'
  END AS health
FROM clients c
LEFT JOIN exceptions e ON e.client_id = c.id
LEFT JOIN jobs j       ON j.client_id  = c.id
LEFT JOIN publication_tasks p ON p.client_id = c.id
GROUP BY c.id, c.code, c.display_name, c.status;

-- ---------------------------------------------------------------------------
-- Manual publish queue: tasks a human must approve/assist, sorted by urgency.
-- This is the "PUBLISH_REQUIRED" worklist.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_manual_publish_queue AS
SELECT
  t.id,
  c.code AS client_code,
  s.platform,
  s.surface_type,
  s.canonical_url,
  t.mode,
  t.status,
  COALESCE(t.last_error, '') AS last_error,
  t.scheduled_for,
  t.created_at,
  (t.payload_json->>'title') AS asset_title,
  CASE WHEN t.scheduled_for IS NOT NULL AND t.scheduled_for <= now() THEN true ELSE false END AS due
FROM publication_tasks t
LEFT JOIN clients c ON c.id = t.client_id
LEFT JOIN surfaces s ON s.id = t.surface_id
WHERE t.status IN ('WAITING_APPROVAL','PUBLISHING')
ORDER BY
  CASE t.status WHEN 'PUBLISHING' THEN 0 WHEN 'WAITING_APPROVAL' THEN 1 ELSE 2 END,
  t.scheduled_for ASC NULLS LAST,
  t.created_at ASC;

-- ---------------------------------------------------------------------------
-- Content QA failures: assets the fact or compliance gate blocked.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_content_qa_failures AS
SELECT
  a.id,
  c.code AS client_code,
  b.canonical_angle AS brief_angle,
  a.format,
  a.title,
  a.fact_check_status,
  a.compliance_status,
  a.status AS asset_status,
  a.quality_score,
  a.updated_at
FROM content_assets a
LEFT JOIN clients c ON c.id = a.client_id
LEFT JOIN content_briefs b ON b.id = a.brief_id
WHERE a.fact_check_status IN ('CONTENT_QA_FAILED','FAILED')
   OR a.compliance_status = 'BLOCKED'
   OR a.status = 'BLOCKED'
ORDER BY a.updated_at DESC;

-- ---------------------------------------------------------------------------
-- Failed / retry-exhausted jobs requiring operator attention.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_failed_retry_jobs AS
SELECT
  j.id,
  c.code AS client_code,
  j.job_type,
  j.status,
  j.attempts,
  j.max_attempts,
  j.priority,
  j.due_at,
  j.unique_key,
  j.last_error,
  j.created_at,
  CASE WHEN j.status='RETRY_WAIT' AND j.attempts >= j.max_attempts THEN true ELSE false END AS exhausted
FROM jobs j
LEFT JOIN clients c ON c.id = j.client_id
WHERE j.status IN ('FAILED','RETRY_WAIT')
ORDER BY
  CASE j.status WHEN 'FAILED' THEN 0 ELSE 1 END,
  j.due_at ASC;

-- ---------------------------------------------------------------------------
-- Pending client data: truth documents that are not yet parsed, plus OPEN
-- CLIENT_DATA_REQUIRED / PARSE_FAILED exceptions.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_pending_client_data AS
SELECT 'DOCUMENT' AS kind, d.id AS object_id, c.code AS client_code,
       d.title AS subject, d.document_type AS detail, d.status, d.received_at AS ts
FROM truth_documents d
LEFT JOIN clients c ON c.id = d.client_id
WHERE d.status IN ('RECEIVED','PARSE_FAILED')
UNION ALL
SELECT 'EXCEPTION', e.id, c.code, e.exception_type, e.detail, e.status, e.created_at
FROM exceptions e
LEFT JOIN clients c ON c.id = e.client_id
WHERE e.status='OPEN'
  AND e.exception_type IN ('CLIENT_DATA_REQUIRED','PARSE_FAILED');

-- ---------------------------------------------------------------------------
-- Reports (operator reads the generated reports here).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_reports AS
SELECT
  r.id,
  c.code AS client_code,
  r.report_type,
  r.period_start,
  r.period_end,
  r.status,
  r.metrics,
  r.summary_md,
  r.artifact_path,
  r.generated_at
FROM reports r
LEFT JOIN clients c ON c.id = r.client_id
ORDER BY r.generated_at DESC NULLS LAST, r.period_end DESC;