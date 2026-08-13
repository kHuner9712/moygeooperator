-- ============================================================================
-- Operator Dashboard views (Stage 1). Read-only; NocoDB shows these first.
-- Views are created on top of the System-of-Record schema.
-- NOTE: v_client_health now lives in operator_runtime.sql (P0.10, exception-first).
-- ============================================================================

-- Open exceptions, prioritized (this is what the operator scans daily).
CREATE OR REPLACE VIEW v_exception_queue AS
SELECT
  e.id,
  e.client_id,
  c.code AS client_code,
  e.exception_type,
  e.severity,
  e.status,
  e.title,
  e.detail,
  e.related_object_type,
  e.related_object_id,
  e.source_job_id,
  e.due_at,
  e.created_at,
  CASE WHEN e.due_at < now() THEN 'OVERDUE' ELSE 'OK' END AS due_state
FROM exceptions e
LEFT JOIN clients c ON c.id = e.client_id
WHERE e.status = 'OPEN'
ORDER BY e.due_at ASC NULLS LAST, e.created_at ASC;

-- Job queue summary (pending / running / retry exhausted).
CREATE OR REPLACE VIEW v_job_queue AS
SELECT
  j.id,
  j.client_id,
  c.code AS client_code,
  j.job_type,
  j.status,
  j.priority,
  j.attempts,
  j.max_attempts,
  j.due_at,
  j.lease_until,
  j.unique_key,
  j.last_error,
  j.created_at,
  CASE WHEN j.status IN ('PENDING','RETRY_WAIT') AND j.due_at <= now() THEN true ELSE false END AS due,
  CASE WHEN j.status IN ('PENDING','RETRY_WAIT') AND j.due_at <= now()
            AND j.attempts >= j.max_attempts THEN true ELSE false END AS exhausted
FROM jobs j
LEFT JOIN clients c ON c.id = j.client_id
WHERE j.status IN ('PENDING','RUNNING','RETRY_WAIT')
ORDER BY j.priority DESC, j.due_at ASC;

-- "Today" ops board: retry-exhausted jobs + credential expiry + manual publish due.
CREATE OR REPLACE VIEW v_daily_ops AS
-- 1. Retry-exhausted / failed jobs needing operator attention.
SELECT 'JOB' AS kind, null::uuid AS client_id, c.code AS client_code,
       j.job_type AS subject, j.last_error AS detail,
       j.created_at AS ts, now() AS due_at
FROM jobs j LEFT JOIN clients c ON c.id = j.client_id
WHERE j.status = 'FAILED'
UNION ALL
-- 2. Credentials expiring within 7 days.
SELECT 'CRED' AS kind, cc.client_id, c.code,
       cc.provider || ' (' || cc.credential_ref || ')' AS subject,
       'expires ' || cc.expires_at::text AS detail,
       cc.expires_at AS ts, cc.expires_at AS due_at
FROM client_credentials cc LEFT JOIN clients c ON c.id = cc.client_id
WHERE cc.status = 'ACTIVE' AND cc.expires_at IS NOT NULL
  AND cc.expires_at BETWEEN now() AND now() + interval '7 days';

-- Credential expiry scan (used by the daily scheduler).
CREATE OR REPLACE VIEW v_credentials_expiring AS
SELECT cc.id, cc.client_id, c.code AS client_code, cc.provider, cc.credential_ref,
       cc.expires_at, cc.metadata
FROM client_credentials cc LEFT JOIN clients c ON c.id = cc.client_id
WHERE cc.status = 'ACTIVE' AND cc.expires_at IS NOT NULL
  AND cc.expires_at BETWEEN now() AND now() + interval '7 days';