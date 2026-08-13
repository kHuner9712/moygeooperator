-- ============================================================================
-- Stage 8 · Retest / Reporting views (WF-08) for NocoDB / operator dashboard.
-- ============================================================================

-- Publication verification queue: records that were published but not yet
-- verified (evidence of live presence not yet confirmed).
CREATE OR REPLACE VIEW v_publication_verification AS
SELECT
  r.id,
  c.code AS client_code,
  r.platform,
  s.surface_type,
  r.external_id,
  r.url,
  r.published_at,
  r.verification_status,
  r.evidence_uri,
  r.verified_at,
  t.mode AS task_mode
FROM publication_records r
LEFT JOIN clients c ON c.id = r.client_id
LEFT JOIN publication_tasks t ON t.id = r.publication_task_id
LEFT JOIN surfaces s ON s.id = t.surface_id
ORDER BY
  CASE r.verification_status WHEN 'PENDING' THEN 0 WHEN 'VERIFIED' THEN 1 ELSE 2 END,
  r.published_at ASC;

-- Engine retest queue: due ENGINE_OBSERVATION jobs scoped to RETEST.
CREATE OR REPLACE VIEW v_retest_queue AS
SELECT
  j.id,
  c.code AS client_code,
  j.job_type,
  j.status,
  j.priority,
  j.due_at,
  j.unique_key,
  j.payload_json,
  j.attempts,
  j.last_error
FROM jobs j
LEFT JOIN clients c ON c.id = j.client_id
WHERE j.job_type = 'ENGINE_OBSERVATION'
  AND j.payload_json->>'scope' = 'RETEST'
ORDER BY j.due_at ASC;

-- Period metrics comparison: current vs prior window per engine/query.
CREATE OR REPLACE VIEW v_period_comparison AS
WITH current AS (
  SELECT client_id, engine_id, query_id,
         count(*) AS observations,
         count(*) FILTER (WHERE target_mentioned) AS mentioned,
         count(*) FILTER (WHERE target_recommended) AS recommended,
         round(avg(position_hint) FILTER (WHERE position_hint IS NOT NULL),2) AS avg_position
  FROM engine_observations
  GROUP BY client_id, engine_id, query_id
)
SELECT
  c.code AS client_code,
  e.provider || ' / ' || e.product AS engine,
  q.query_text,
  cur.observations,
  cur.mentioned,
  cur.recommended,
  cur.avg_position,
  round(cur.mentioned::numeric / NULLIF(cur.observations,0), 4) AS mention_rate
FROM current cur
JOIN clients c ON c.id = cur.client_id
JOIN engines e ON e.id = cur.engine_id
JOIN queries q ON q.id = cur.query_id
ORDER BY c.code, e.provider, q.query_text;

-- Generated reports (operator-facing).
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
ORDER BY r.period_start DESC, r.period_end DESC;