-- ============================================================================
-- MOY GEO Operator · Migration 007 · Stage 5 · WF-05 job scheduling
-- Adds schedule_gap_analysis_jobs() so the WF-05 webhook worker has due
-- GAP_ANALYSIS jobs to claim (claim_next_job('wf05', ...)). Deterministic
-- unique_key makes re-runs idempotent via enqueue_job dedup.
-- ============================================================================

-- Schedule a single GAP_ANALYSIS job for a client. Used by the WF-05 entry
-- pass (first run over all ACTIVE clients) and by scheduled re-runs.
CREATE OR REPLACE FUNCTION schedule_gap_analysis_jobs(
  p_client_code text,
  p_priority integer DEFAULT 50,
  p_run_date date DEFAULT CURRENT_DATE
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_client uuid;
  v_uk text;
  v_id uuid;
BEGIN
  SELECT id INTO v_client FROM clients WHERE code = p_client_code;
  IF v_client IS NULL THEN
    RAISE EXCEPTION 'client % not found', p_client_code;
  END IF;

  v_uk := 'gap:' || v_client::text || ':' || p_run_date::text;
  v_id := enqueue_job(
    v_client, 'GAP_ANALYSIS',
    jsonb_build_object('client_code', p_client_code, 'run_date', p_run_date),
    p_priority, now(), 3, v_uk);
  RETURN v_id;
END;
$$;

-- Schedule GAP_ANALYSIS jobs for every ACTIVE client. Returns number enqueued
-- (0 if all already pending — idempotent re-run).
CREATE OR REPLACE FUNCTION schedule_all_gap_analysis(
  p_priority integer DEFAULT 50,
  p_run_date date DEFAULT CURRENT_DATE
) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  r RECORD;
  n int := 0;
BEGIN
  FOR r IN SELECT code FROM clients WHERE active ORDER BY code LOOP
    PERFORM schedule_gap_analysis_jobs(r.code, p_priority, p_run_date);
    n := n + 1;
  END LOOP;
  RETURN n;
END;
$$;

-- ============================================================================
-- WF-05 -> WF-06 handoff: enqueue a CONTENT_FACTORY job for every OPEN
-- CONTENT_CREATION action of the client (idempotent via unique_key so a
-- re-run never duplicates pending content jobs). Returns jobs enqueued.
-- ============================================================================
CREATE OR REPLACE FUNCTION enqueue_content_factory_jobs(
  p_client_code text
) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  v_client uuid;
  r RECORD;
  n int := 0;
BEGIN
  SELECT id INTO v_client FROM clients WHERE code = p_client_code;
  IF v_client IS NULL THEN
    RAISE EXCEPTION 'client % not found', p_client_code;
  END IF;

  FOR r IN
    SELECT a.id, a.target_intent_id, a.priority
    FROM geo_actions a
    WHERE a.client_id = v_client
      AND a.action_type = 'CONTENT_CREATION'
      AND a.status NOT IN ('DONE','CANCELLED')
      AND NOT EXISTS (
        SELECT 1 FROM jobs j
        WHERE j.unique_key = 'content-factory:' || a.id::text
          AND j.status IN ('PENDING','RUNNING','RETRY_WAIT'))
    ORDER BY a.priority DESC
  LOOP
    PERFORM enqueue_job(
      v_client, 'CONTENT_FACTORY',
      jsonb_build_object('action_id', r.id, 'intent_id', r.target_intent_id),
      r.priority, now(), 3, 'content-factory:' || r.id::text);
    n := n + 1;
  END LOOP;

  RETURN n;
END;
$$;