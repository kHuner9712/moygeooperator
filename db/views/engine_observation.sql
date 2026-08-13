-- ============================================================================
-- Stage 4 · Engine Observation views (NocoDB-facing). Read-only.
-- WF-04 results: engine catalog, observation status, baseline completeness,
-- and time/region/language-bound surface profiles.
-- ============================================================================

-- Engine catalog.
CREATE OR REPLACE VIEW v_engine_catalog AS
SELECT id, provider, product, mode, region, language, enabled, config
FROM engines
ORDER BY provider, product, mode;

-- Per (client, engine, query): latest observation + counts by kind/factuality.
CREATE OR REPLACE VIEW v_engine_observation_status AS
SELECT
  c.code AS client_code,
  q.id AS query_id,
  q.query_text,
  e.id AS engine_id,
  e.provider, e.product, e.mode,
  count(o.id) AS observations,
  count(o.id) FILTER (WHERE o.observation_kind='API_OBSERVATION')    AS api_obs,
  count(o.id) FILTER (WHERE o.observation_kind='UI_OBSERVATION')     AS ui_obs,
  count(o.id) FILTER (WHERE o.observation_kind='MANUAL_OBSERVATION') AS manual_obs,
  count(o.id) FILTER (WHERE o.target_mentioned)   AS mentioned,
  count(o.id) FILTER (WHERE o.target_recommended) AS recommended,
  max(o.observed_at) AS last_observed_at,
  (array_agg(o.factuality_status ORDER BY o.observed_at DESC))[1] AS last_factuality
FROM engine_observations o
JOIN clients c ON c.id = o.client_id
JOIN engines e ON e.id = o.engine_id
JOIN queries q ON q.id = o.query_id
GROUP BY c.code, q.id, q.query_text, e.id, e.provider, e.product, e.mode
ORDER BY c.code, e.provider, q.query_text;

-- Baseline completeness: observed query count vs active queries per client+engine.
CREATE OR REPLACE VIEW v_engine_baseline AS
SELECT
  c.code AS client_code,
  e.id AS engine_id, e.provider, e.product, e.mode,
  count(DISTINCT q.id) AS active_queries,
  count(DISTINCT o.query_id) AS observed_queries,
  round(count(DISTINCT o.query_id)::numeric
        / NULLIF(count(DISTINCT q.id)::numeric,0), 4) AS coverage
FROM clients c
JOIN queries q ON q.client_id = c.id AND q.active
JOIN engines e ON e.enabled
LEFT JOIN engine_observations o
       ON o.query_id = q.id AND o.engine_id = e.id AND o.client_id = c.id
GROUP BY c.code, e.id, e.provider, e.product, e.mode
ORDER BY c.code, e.provider;

-- Time/region/language-bound surface profiles.
CREATE OR REPLACE VIEW v_engine_surface_profiles AS
SELECT
  e.provider, e.product,
  p.surface_type, p.region, p.language,
  p.observed_from, p.observed_until,
  p.evidence_count, p.confidence, p.findings, p.updated_at
FROM engine_surface_profiles p
JOIN engines e ON e.id = p.engine_id
ORDER BY e.provider, p.surface_type, p.observed_from DESC;