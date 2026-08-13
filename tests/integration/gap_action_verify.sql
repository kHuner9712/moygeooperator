-- ============================================================================
-- Stage 5 · WF-05 Gap/Action integration assertions (SYNTH-ACME).
-- Run AFTER db/seeds/synthetic_gap_action.sql (which needs Stages 2/3/4 seeds).
-- Verifies: gap detection counts, action planning routing, fail-closed
-- CLIENT_DATA_REQUIRED exceptions, priority assignment, idempotency, and
-- cross-client isolation.
-- ============================================================================
\set ON_ERROR_STOP on

SELECT id INTO TEMP TABLE _t5_cid FROM clients WHERE code='SYNTH-ACME';
DO $$
DECLARE
  v_cid uuid;
  v_gaps int; v_vis int; v_content int;
  v_actions int; v_content_actions int;
  v_exceptions int;
  v_priority int;
  v_dup int;
  v_other int;
  v_result jsonb;
BEGIN
  SELECT id INTO v_cid FROM _t5_cid;
  IF v_cid IS NULL THEN RAISE EXCEPTION 'FAIL: SYNTH-ACME client not found'; END IF;

  -- 1. Gap detection counts.
  SELECT count(*) INTO v_gaps FROM geo_gaps WHERE client_id=v_cid;
  IF v_gaps <> 5 THEN RAISE EXCEPTION 'FAIL gaps expected 5 got %', v_gaps; END IF;

  SELECT count(*) INTO v_vis FROM geo_gaps
    WHERE client_id=v_cid AND gap_type='ENGINE_VISIBILITY_GAP';
  SELECT count(*) INTO v_content FROM geo_gaps
    WHERE client_id=v_cid AND gap_type='CONTENT_GAP';
  IF v_vis <> 1 OR v_content <> 4 THEN
    RAISE EXCEPTION 'FAIL gap split expected 1 vis + 4 content got % + %', v_vis, v_content; END IF;

  -- 2. Action planning counts.
  SELECT count(*) INTO v_actions FROM geo_actions WHERE client_id=v_cid;
  IF v_actions <> 2 THEN RAISE EXCEPTION 'FAIL actions expected 2 got %', v_actions; END IF;
  SELECT count(*) INTO v_content_actions FROM geo_actions
    WHERE client_id=v_cid AND action_type='CONTENT_CREATION';
  IF v_content_actions <> 2 THEN
    RAISE EXCEPTION 'FAIL content actions expected 2 got %', v_content_actions; END IF;

  -- 3. Fail-closed exceptions: 3 intents have no VERIFIED facts.
  --    (Filter to the GEO_GAP-sourced ones; a separate CLIENT_DATA_REQUIRED from
  --    Stage 2 truth intake exists and is not part of this Stage 5 assertion.)
  SELECT count(*) INTO v_exceptions FROM exceptions
    WHERE client_id=v_cid AND exception_type='CLIENT_DATA_REQUIRED'
      AND related_object_type='GEO_GAP' AND status='OPEN';
  IF v_exceptions <> 3 THEN
    RAISE EXCEPTION 'FAIL CLIENT_DATA_REQUIRED expected 3 got %', v_exceptions; END IF;

  -- 4. Priority is inherited from the intent's priority_score.
  SELECT a.priority INTO v_priority FROM geo_actions a
    JOIN intents i ON i.id=a.target_intent_id
    WHERE a.client_id=v_cid AND i.label='采购精密气缸供应商'
    LIMIT 1;
  IF v_priority IS DISTINCT FROM 255 THEN
    RAISE EXCEPTION 'FAIL purchase action priority expected 255 got %', v_priority; END IF;

  -- 5. Idempotency: re-running analysis/planning creates nothing new.
  SELECT analyze_gaps('SYNTH-ACME') INTO v_dup;
  IF v_dup <> 0 THEN RAISE EXCEPTION 'FAIL analyze_gaps not idempotent: % new', v_dup; END IF;
  SELECT plan_actions('SYNTH-ACME') INTO v_result;
  IF (v_result->>'content_actions')::int <> 0 OR (v_result->>'data_exceptions')::int <> 0 THEN
    RAISE EXCEPTION 'FAIL plan_actions not idempotent: %', v_result; END IF;
  SELECT count(*) INTO v_gaps FROM geo_gaps WHERE client_id=v_cid;
  SELECT count(*) INTO v_actions FROM geo_actions WHERE client_id=v_cid;
  SELECT count(*) INTO v_exceptions FROM exceptions
    WHERE client_id=v_cid AND exception_type='CLIENT_DATA_REQUIRED'
      AND related_object_type='GEO_GAP' AND status='OPEN';
  IF v_gaps <> 5 OR v_actions <> 2 OR v_exceptions <> 3 THEN
    RAISE EXCEPTION 'FAIL idempotency counts drifted: gaps=% actions=% exc=%', v_gaps, v_actions, v_exceptions; END IF;

  -- 6. Cross-client isolation: no gap/action/exception leaked to another client.
  SELECT count(*) INTO v_other FROM geo_gaps WHERE client_id IS DISTINCT FROM v_cid;
  IF v_other <> 0 THEN RAISE EXCEPTION 'FAIL a gap leaked to another client'; END IF;
  SELECT count(*) INTO v_other FROM geo_actions WHERE client_id IS DISTINCT FROM v_cid;
  IF v_other <> 0 THEN RAISE EXCEPTION 'FAIL an action leaked to another client'; END IF;

  -- 7. WF-05 handoff: a GAP_ANALYSIS job + a CONTENT_FACTORY job per OPEN
  --    CONTENT_CREATION action are pending for this client.
  SELECT count(*) INTO v_other FROM jobs
    WHERE client_id=v_cid AND job_type='GAP_ANALYSIS'
      AND status IN ('PENDING','RUNNING','RETRY_WAIT');
  IF v_other <> 1 THEN
    RAISE EXCEPTION 'FAIL expected 1 pending GAP_ANALYSIS job got %', v_other; END IF;
  SELECT count(*) INTO v_other FROM jobs
    WHERE client_id=v_cid AND job_type='CONTENT_FACTORY'
      AND status IN ('PENDING','RUNNING','RETRY_WAIT');
  IF v_other <> 2 THEN
    RAISE EXCEPTION 'FAIL expected 2 pending CONTENT_FACTORY jobs got %', v_other; END IF;

  RAISE NOTICE 'PASS gap_action: gaps=% (vis=% content=%) actions=% exceptions=% priority=%',
    v_gaps, v_vis, v_content, v_actions, v_exceptions, v_priority;
END $$;
DROP TABLE _t5_cid;