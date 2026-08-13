-- ============================================================================
-- MOY GEO Operator · Migration 010 · Stage 8 · Retest / Reporting (WF-08)
-- Publication verification, engine retest scheduling, period comparison, and
-- weekly report generation. Period metrics are computed from engine
-- observations and compared against the baseline; reports are idempotent per
-- (client, type, period).
-- ============================================================================

-- ============================================================================
-- Idempotency: reports are unique per (client, report_type, period). The base
-- table (001) has no such constraint, so add it here to support ON CONFLICT.
-- ============================================================================
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'reports_client_type_period_key'
  ) THEN
    ALTER TABLE reports
      ADD CONSTRAINT reports_client_type_period_key
      UNIQUE (client_id, report_type, period_start, period_end);
  END IF;
END;
$$;

-- ============================================================================
-- verify_publication — mark a publication record as verified with evidence.
-- Fail closed: only a prior PUBLISHED record may reach VERIFIED.
-- ============================================================================
CREATE OR REPLACE FUNCTION verify_publication(
  p_record_id uuid,
  p_verification_status text DEFAULT 'VERIFIED',
  p_url text DEFAULT NULL,
  p_evidence_uri text DEFAULT NULL,
  p_provider_response jsonb DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  v_task_status publication_status;
BEGIN
  SELECT t.status INTO v_task_status
    FROM publication_records r
    JOIN publication_tasks t ON t.id = r.publication_task_id
    WHERE r.id = p_record_id;
  IF v_task_status IS NULL THEN
    RAISE EXCEPTION 'publication record % not found', p_record_id;
  END IF;
  IF v_task_status <> 'PUBLISHED' THEN
    RAISE EXCEPTION 'cannot verify record % whose task is % (not PUBLISHED)',
      p_record_id, v_task_status;
  END IF;
  UPDATE publication_records
    SET verification_status = p_verification_status,
        url = COALESCE(p_url, url),
        evidence_uri = COALESCE(p_evidence_uri, evidence_uri),
        provider_response = COALESCE(p_provider_response, provider_response),
        verified_at = now()
    WHERE id = p_record_id;
END;
$$;

-- ============================================================================
-- schedule_engine_retest — enqueue ENGINE_OBSERVATION jobs for a RETEST scope
-- (a fresh comparison run) across the client's active engines/queries.
-- ============================================================================
CREATE OR REPLACE FUNCTION schedule_engine_retest(
  p_client_code text,
  p_run_date date DEFAULT CURRENT_DATE,
  p_priority integer DEFAULT 50
) RETURNS int
LANGUAGE plpgsql AS $$
BEGIN
  RETURN schedule_observation_jobs(p_client_code, 'RETEST', NULL,
                                   p_run_date, NULL, p_priority);
END;
$$;

-- ============================================================================
-- compute_period_metrics — aggregate engine observations over a window into a
-- metrics jsonb, and compare visibility/recommendation against the PRIOR
-- period (delta). Used by generate_report.
-- ============================================================================
CREATE OR REPLACE FUNCTION compute_period_metrics(
  p_client_code text,
  p_period_start date,
  p_period_end date
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_client uuid;
  v_past_start date := p_period_start - (p_period_end - p_period_start);
  v_obs int; v_mentioned int; v_recommended int;
  v_mention_rate numeric; v_recommend_rate numeric;
  v_avg_position numeric;
  v_prev_obs int; v_prev_mentioned int;
  v_prev_mention_rate numeric;
  v_verified int; v_assets int; v_published int;
  v_mention_delta numeric;
BEGIN
  SELECT id INTO v_client FROM clients WHERE code = p_client_code;
  IF v_client IS NULL THEN
    RAISE EXCEPTION 'client % not found', p_client_code;
  END IF;

  SELECT count(*), count(*) FILTER (WHERE target_mentioned),
         count(*) FILTER (WHERE target_recommended),
         COALESCE(round(avg(position_hint) FILTER (WHERE position_hint IS NOT NULL),2),0)
    INTO v_obs, v_mentioned, v_recommended, v_avg_position
    FROM engine_observations
    WHERE client_id = v_client
      AND observed_at::date BETWEEN p_period_start AND p_period_end;

  SELECT count(*), count(*) FILTER (WHERE target_mentioned)
    INTO v_prev_obs, v_prev_mentioned
    FROM engine_observations
    WHERE client_id = v_client
      AND observed_at::date BETWEEN v_past_start AND (p_period_start - 1);

  v_mention_rate := round(v_mentioned::numeric / NULLIF(v_obs,0), 4);
  v_recommend_rate := round(v_recommended::numeric / NULLIF(v_obs,0), 4);
  v_prev_mention_rate := round(v_prev_mentioned::numeric / NULLIF(v_prev_obs,0), 4);
  v_mention_delta := round(v_mention_rate - v_prev_mention_rate, 4);

  SELECT count(*) INTO v_verified FROM claims
    WHERE client_id = v_client AND verification = 'VERIFIED';
  SELECT count(*) INTO v_assets FROM content_assets
    WHERE client_id = v_client AND status = 'READY';
  SELECT count(*) INTO v_published FROM publication_tasks
    WHERE client_id = v_client AND status = 'PUBLISHED';

  RETURN jsonb_build_object(
    'period_start', p_period_start, 'period_end', p_period_end,
    'observations', v_obs,
    'target_mentioned', v_mentioned,
    'mention_rate', v_mention_rate,
    'target_recommended', v_recommended,
    'recommend_rate', v_recommend_rate,
    'avg_position', v_avg_position,
    'prev_observations', v_prev_obs,
    'prev_mention_rate', v_prev_mention_rate,
    'mention_delta', v_mention_delta,
    'verified_claims', v_verified,
    'ready_assets', v_assets,
    'published', v_published);
END;
$$;

-- ============================================================================
-- generate_report — build a report row with computed period metrics and a
-- markdown summary. Idempotent per (client, report_type, period).
-- ============================================================================
CREATE OR REPLACE FUNCTION generate_report(
  p_client_code text,
  p_report_type text,
  p_period_start date,
  p_period_end date
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_client uuid;
  v_metrics jsonb;
  v_summary text;
  v_id uuid;
  v_mr numeric; v_delta numeric; v_obs int; v_pub int;
BEGIN
  SELECT id INTO v_client FROM clients WHERE code = p_client_code;
  IF v_client IS NULL THEN
    RAISE EXCEPTION 'client % not found', p_client_code;
  END IF;

  v_metrics := compute_period_metrics(p_client_code, p_period_start, p_period_end);
  v_mr := COALESCE((v_metrics->>'mention_rate')::numeric, 0);
  v_delta := COALESCE((v_metrics->>'mention_delta')::numeric, 0);
  v_obs := COALESCE((v_metrics->>'observations')::int, 0);
  v_pub := COALESCE((v_metrics->>'published')::int, 0);

  v_summary := '## ' || p_report_type || ' Report (' || p_period_start || ' to '
    || p_period_end || ')' || E'\n\n'
    || '- Observations: ' || v_obs || E'\n'
    || '- Mention rate: ' || round(v_mr*100,2) || '% (delta ' || round(v_delta*100,2) || 'pp)' || E'\n'
    || '- Published items: ' || v_pub;

  INSERT INTO reports(client_id, report_type, period_start, period_end,
                      status, metrics, summary_md, generated_at)
  VALUES (v_client, p_report_type, p_period_start, p_period_end,
          'READY', v_metrics, v_summary, now())
  ON CONFLICT (client_id, report_type, period_start, period_end) DO UPDATE
    SET metrics = EXCLUDED.metrics,
        summary_md = EXCLUDED.summary_md,
        status = 'READY',
        generated_at = now()
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;