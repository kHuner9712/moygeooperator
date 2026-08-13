-- ============================================================================
-- 011_enqueue_job_idempotent.sql
-- Make enqueue_job fully idempotent on unique_key.
-- Previously, when a same-key job already existed in a terminal state
-- (SUCCEEDED / FAILED / CANCELLED), enqueue_job fell through to INSERT and
-- blew up on the uq_jobs_unique_key constraint. This surfaced in WF-08:
-- schedule_engine_retest() re-schedules the same-day RETEST ENGINE_OBSERVATION
-- jobs on every REPORT run, and the second run collided with the already
-- SUCCEEDED jobs.
-- Now: if the unique_key already exists in ANY state, return the existing id
-- and do not insert a duplicate. Idempotent by construction.
-- ============================================================================

CREATE OR REPLACE FUNCTION enqueue_job(
  p_client_id uuid,
  p_job_type text,
  p_payload jsonb DEFAULT '{}',
  p_priority integer DEFAULT 50,
  p_due_at timestamptz DEFAULT now(),
  p_max_attempts integer DEFAULT 3,
  p_unique_key text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_existing uuid;
  v_id uuid;
BEGIN
  IF p_unique_key IS NOT NULL THEN
    SELECT id INTO v_existing FROM jobs
      WHERE unique_key = p_unique_key
      LIMIT 1;
    IF v_existing IS NOT NULL THEN
      RETURN v_existing;
    END IF;
  END IF;

  INSERT INTO jobs(client_id, job_type, priority, due_at, payload_json, max_attempts, unique_key)
  VALUES (p_client_id, p_job_type, p_priority, p_due_at, p_payload, p_max_attempts, p_unique_key)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;