-- ============================================================================
-- MOY GEO Operator · Migration 005 · Stage 4 · Engine Observation (WF-04)
-- Engine catalog dedup + idempotent observation recording + scheduling +
-- time/region/language-bound surface profile aggregation.
-- Rule: API observations must NOT be assumed equal to consumer UI; the kind
-- is explicit (API_OBSERVATION / UI_OBSERVATION / MANUAL_OBSERVATION).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Engine catalog dedup (provider × product × mode × region × language).
-- ---------------------------------------------------------------------------
CREATE UNIQUE INDEX uq_engines_composite
  ON engines(provider, product, mode, COALESCE(region,''), COALESCE(language,''));

-- Unique window/scope for surface profiles (supports upsert).
CREATE UNIQUE INDEX uq_engine_surface_profiles_window
  ON engine_surface_profiles(engine_id, surface_type,
     COALESCE(region,''), COALESCE(language,''), observed_from, observed_until);

-- ============================================================================
-- Register an engine (idempotent by composite key).
-- ============================================================================
CREATE OR REPLACE FUNCTION upsert_engine(
  p_provider text,
  p_product text,
  p_mode text,
  p_region text DEFAULT NULL,
  p_language text DEFAULT NULL,
  p_enabled boolean DEFAULT true,
  p_config jsonb DEFAULT '{}'
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_id uuid;
BEGIN
  INSERT INTO engines(provider, product, mode, region, language, enabled, config)
  VALUES (p_provider, p_product, p_mode, p_region, p_language, p_enabled, COALESCE(p_config,'{}'))
  ON CONFLICT (provider, product, mode, COALESCE(region,''), COALESCE(language,''))
  DO UPDATE SET enabled = EXCLUDED.enabled, config = EXCLUDED.config
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

-- ============================================================================
-- Record one observation. Idempotent by (client, engine, query, run_key).
-- Structured extraction fields map to the columns; wrong/missing facts,
-- competitors and uncertainty go into metadata.
-- ============================================================================
CREATE OR REPLACE FUNCTION record_observation(
  p_client_code text,
  p_engine_id uuid,
  p_query_id uuid,
  p_observation_kind observation_kind,
  p_observed_at timestamptz,
  p_run_key text,
  p_answer_text text DEFAULT NULL,
  p_target_mentioned boolean DEFAULT NULL,
  p_target_recommended boolean DEFAULT NULL,
  p_position_hint integer DEFAULT NULL,
  p_factuality_status text DEFAULT NULL,
  p_citations jsonb DEFAULT '[]',
  p_cited_surface_ids jsonb DEFAULT '[]',
  p_evidence_uri text DEFAULT NULL,
  p_raw_artifact_ref text DEFAULT NULL,
  p_latency_ms integer DEFAULT NULL,
  p_cost_amount numeric DEFAULT NULL,
  p_metadata jsonb DEFAULT '{}'
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_client uuid;
  v_id uuid;
BEGIN
  SELECT id INTO v_client FROM clients WHERE code = p_client_code;
  IF v_client IS NULL THEN
    RAISE EXCEPTION 'client % not found', p_client_code;
  END IF;

  INSERT INTO engine_observations(client_id, engine_id, query_id, observation_kind,
    observed_at, run_key, answer_text, target_mentioned, target_recommended,
    position_hint, factuality_status, citations, cited_surface_ids, evidence_uri,
    raw_artifact_ref, latency_ms, cost_amount, metadata)
  VALUES (v_client, p_engine_id, p_query_id, p_observation_kind,
    p_observed_at, p_run_key, p_answer_text, p_target_mentioned, p_target_recommended,
    p_position_hint, p_factuality_status, p_citations, p_cited_surface_ids, p_evidence_uri,
    p_raw_artifact_ref, p_latency_ms, p_cost_amount, COALESCE(p_metadata,'{}'))
  ON CONFLICT (client_id, engine_id, query_id, run_key) DO NOTHING
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

-- ============================================================================
-- Schedule Engine Observation jobs for a run scope. Deterministic unique_key
-- makes re-runs idempotent (enqueue_job dedupes). scope: BASELINE / WEEKLY /
-- MONTHLY. p_query_limit caps the number of active queries to observe.
-- ============================================================================
CREATE OR REPLACE FUNCTION schedule_observation_jobs(
  p_client_code text,
  p_scope text,
  p_engine_ids uuid[] DEFAULT NULL,   -- NULL = all enabled engines
  p_run_date date DEFAULT CURRENT_DATE,
  p_query_limit integer DEFAULT NULL,
  p_priority integer DEFAULT 50
) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  v_client uuid;
  v_engine uuid;
  v_q RECORD;
  n int := 0;
  v_uk text;
BEGIN
  SELECT id INTO v_client FROM clients WHERE code = p_client_code;
  IF v_client IS NULL THEN
    RAISE EXCEPTION 'client % not found', p_client_code;
  END IF;

  FOR v_q IN
    SELECT q.id FROM queries q
    WHERE q.client_id = v_client AND q.active
    ORDER BY q.priority DESC
    LIMIT p_query_limit
  LOOP
    FOR v_engine IN
      SELECT id FROM engines
      WHERE enabled AND (p_engine_ids IS NULL OR id = ANY(p_engine_ids))
    LOOP
      v_uk := 'obs:' || v_client::text || ':' || v_engine::text || ':' || v_q.id::text
              || ':' || p_scope || ':' || p_run_date::text;
      PERFORM enqueue_job(v_client, 'ENGINE_OBSERVATION',
        jsonb_build_object('query_id', v_q.id, 'engine_id', v_engine,
                           'scope', p_scope, 'run_date', p_run_date),
        p_priority, now(), 3, v_uk);
      n := n + 1;
    END LOOP;
  END LOOP;

  RETURN n;
END;
$$;

-- ============================================================================
-- Aggregate observations for an engine over a window into engine_surface_profiles.
-- Time-bound, region/language-bound, evidence-counted, confidence-scored.
-- ============================================================================
CREATE OR REPLACE FUNCTION refresh_engine_surface_profiles(
  p_engine_id uuid,
  p_observed_from date,
  p_observed_until date DEFAULT NULL
) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  v_until date := COALESCE(p_observed_until, CURRENT_DATE);
  v_region text;
  v_lang text;
  v_surface_type text;
  v_ev_count int;
  v_mention numeric;
  v_confidence numeric;
  n int := 0;
BEGIN
  FOR v_region, v_lang, v_surface_type, v_ev_count, v_mention IN
    SELECT e.region, e.language, s.surface_type,
           count(*)::int,
           round((count(*) FILTER (WHERE o.target_recommended)::numeric
                  / NULLIF(count(*)::numeric,0)), 4)
    FROM engine_observations o
    JOIN engines e ON e.id = o.engine_id
    LEFT JOIN LATERAL (
      SELECT (sid #>> '{}')::uuid AS sid_id
      FROM jsonb_array_elements(o.cited_surface_ids) AS sid
    ) u ON true
    LEFT JOIN surfaces s ON s.id = u.sid_id
    WHERE o.engine_id = p_engine_id
      AND o.observed_at::date BETWEEN p_observed_from AND v_until
      AND s.surface_type IS NOT NULL
    GROUP BY e.region, e.language, s.surface_type
  LOOP
    v_confidence := round(least(1.0, v_ev_count::numeric / 10.0), 4);
    INSERT INTO engine_surface_profiles(engine_id, surface_type, region, language,
      observed_from, observed_until, evidence_count, confidence, findings)
    VALUES (p_engine_id, v_surface_type, v_region, v_lang,
      p_observed_from, v_until, v_ev_count, v_confidence,
      jsonb_build_object('target_recommend_rate', v_mention))
    ON CONFLICT (engine_id, surface_type, COALESCE(region,''), COALESCE(language,''),
                 observed_from, observed_until)
    DO UPDATE SET evidence_count = EXCLUDED.evidence_count,
                  confidence = EXCLUDED.confidence,
                  findings = EXCLUDED.findings,
                  updated_at = now();
    n := n + 1;
  END LOOP;

  RETURN n;
END;
$$;