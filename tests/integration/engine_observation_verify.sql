-- ============================================================================
-- Stage 4 · WF-04 Engine Observation integration assertions (SYNTH-ACME).
-- Run AFTER db/seeds/synthetic_engine_observation.sql.
-- Verifies: engine catalog dedup, idempotent observation recording,
-- observation-kind fidelity, cross-client isolation, surface profile
-- aggregation, and idempotent job scheduling.
-- ============================================================================
\set ON_ERROR_STOP on

SELECT id INTO TEMP TABLE _t4_cid FROM clients WHERE code='SYNTH-ACME';
DO $$
DECLARE
  v_cid uuid;
  v_eng_chat uuid; v_eng_search uuid;
  v_engines int;
  v_obs int; v_api int; v_manual int;
  v_mentioned int; v_recommended int;
  v_profiles int; v_search_profiles int; v_chat_profiles int;
  v_ev_count int;
  v_scheduled int; v_jobs_before int; v_jobs_after int;
  v_obs_after int;
  v_other_client int;
  v_uuid uuid;
  v_qid uuid;
BEGIN
  SELECT id INTO v_cid FROM _t4_cid;
  IF v_cid IS NULL THEN RAISE EXCEPTION 'FAIL: SYNTH-ACME client not found'; END IF;

  -- 1. Engine catalog: two synthetic engines registered, deduped by composite key.
  SELECT count(*) INTO v_engines FROM engines
    WHERE provider IN ('SYNTH-LOCAL','SYNTH-SEARCH');
  IF v_engines <> 2 THEN RAISE EXCEPTION 'FAIL engines expected 2 got %', v_engines; END IF;

  SELECT id INTO v_eng_chat FROM engines
    WHERE provider='SYNTH-LOCAL' AND product='Qwen2.5' AND mode='chat';
  SELECT id INTO v_eng_search FROM engines
    WHERE provider='SYNTH-SEARCH' AND product='web-search-mock' AND mode='websearch';
  IF v_eng_chat IS NULL OR v_eng_search IS NULL THEN
    RAISE EXCEPTION 'FAIL composite engine keys not found'; END IF;

  -- Re-running upsert must NOT create a duplicate (idempotent by composite key).
  SELECT upsert_engine('SYNTH-LOCAL','Qwen2.5','chat','CN','zh-CN',true)
    INTO v_uuid;
  IF v_uuid IS DISTINCT FROM v_eng_chat THEN
    RAISE EXCEPTION 'FAIL upsert_engine dedup broken'; END IF;
  SELECT count(*) INTO v_engines FROM engines
    WHERE provider='SYNTH-LOCAL' AND product='Qwen2.5' AND mode='chat';
  IF v_engines <> 1 THEN RAISE EXCEPTION 'FAIL upsert_engine created duplicate'; END IF;

  -- 2. Observations recorded across API + MANUAL kinds. (The retest seed adds
  --    2 more API observations, so assert at-least-3 and the kind split on the
  --    engine seed's own keys rather than an absolute total.)
  SELECT count(*) INTO v_obs FROM engine_observations WHERE client_id=v_cid;
  IF v_obs < 3 THEN RAISE EXCEPTION 'FAIL observations expected >=3 got %', v_obs; END IF;

  SELECT count(*) INTO v_api FROM engine_observations
    WHERE client_id=v_cid AND observation_kind='API_OBSERVATION'
      AND run_key IN ('SYNTH-OBS-0001','SYNTH-OBS-0002');
  SELECT count(*) INTO v_manual FROM engine_observations
    WHERE client_id=v_cid AND observation_kind='MANUAL_OBSERVATION'
      AND run_key='SYNTH-OBS-0003';
  IF v_api <> 2 OR v_manual <> 1 THEN
    RAISE EXCEPTION 'FAIL kind split expected 2 API + 1 MANUAL got % API + % MANUAL', v_api, v_manual; END IF;

  -- 3. Mentioned / recommended signals captured (on the engine seed's own keys).
  SELECT count(*) INTO v_mentioned FROM engine_observations
    WHERE client_id=v_cid AND target_mentioned
      AND run_key IN ('SYNTH-OBS-0001','SYNTH-OBS-0002','SYNTH-OBS-0003');
  SELECT count(*) INTO v_recommended FROM engine_observations
    WHERE client_id=v_cid AND target_recommended
      AND run_key IN ('SYNTH-OBS-0001','SYNTH-OBS-0002','SYNTH-OBS-0003');
  IF v_mentioned <> 2 OR v_recommended <> 2 THEN
    RAISE EXCEPTION 'FAIL mentioned=% recommended=% expected 2/2', v_mentioned, v_recommended; END IF;

  -- 4. Idempotent re-insert of an existing run_key must NOT add a new row.
  --    (The 19-arg overload is an upsert: it returns the EXISTING observation's
  --    id on conflict and must not create a duplicate.)
  SELECT query_id INTO v_qid FROM engine_observations
    WHERE client_id=v_cid AND run_key='SYNTH-OBS-0001' LIMIT 1;
  SELECT record_observation('SYNTH-ACME', v_eng_search, v_qid,
    'API_OBSERVATION', now() - interval '3 days', 'SYNTH-OBS-0001',
    'dup', true, true, 1, 'CORRECT', '[]'::jsonb, '[]'::jsonb,
    NULL, NULL, NULL, NULL, '{}'::jsonb, NULL) INTO v_uuid;
  SELECT count(*) INTO v_obs_after FROM engine_observations WHERE client_id=v_cid;
  IF v_obs_after <> v_obs THEN RAISE EXCEPTION 'FAIL idempotency broken: % rows', v_obs_after; END IF;
  IF v_uuid <> (SELECT id FROM engine_observations
                WHERE client_id=v_cid AND run_key='SYNTH-OBS-0001' LIMIT 1) THEN
    RAISE EXCEPTION 'FAIL idempotent re-insert returned a different id'; END IF;

  -- 5. Surface profile aggregation: time/region/language-bound, evidence-counted.
  SELECT count(*) INTO v_profiles FROM engine_surface_profiles
    WHERE engine_id IN (v_eng_chat, v_eng_search);
  IF v_profiles < 1 THEN RAISE EXCEPTION 'FAIL no surface profiles aggregated'; END IF;

  SELECT count(*) INTO v_search_profiles FROM engine_surface_profiles
    WHERE engine_id=v_eng_search AND observed_from = CURRENT_DATE - 7;
  SELECT count(*) INTO v_chat_profiles FROM engine_surface_profiles
    WHERE engine_id=v_eng_chat AND observed_from = CURRENT_DATE - 7;
  IF v_search_profiles < 1 OR v_chat_profiles < 1 THEN
    RAISE EXCEPTION 'FAIL profiles missing per engine (search=% chat=%)', v_search_profiles, v_chat_profiles; END IF;

  SELECT COALESCE(sum(evidence_count),0) INTO v_ev_count FROM engine_surface_profiles
    WHERE engine_id=v_eng_search;
  IF v_ev_count < 1 THEN RAISE EXCEPTION 'FAIL search profile has no evidence count'; END IF;

  -- Confidence bounded to [0,1].
  SELECT count(*) INTO v_profiles FROM engine_surface_profiles
    WHERE engine_id IN (v_eng_chat, v_eng_search)
      AND (confidence < 0 OR confidence > 1);
  IF v_profiles <> 0 THEN RAISE EXCEPTION 'FAIL profile confidence out of range'; END IF;

  -- 6. Job scheduling is idempotent (deterministic unique_key dedupes).
  SELECT count(*) INTO v_jobs_before FROM jobs
    WHERE job_type='ENGINE_OBSERVATION' AND payload_json->>'run_date' = CURRENT_DATE::text;
  SELECT schedule_observation_jobs('SYNTH-ACME','BASELINE',
    ARRAY[v_eng_chat], CURRENT_DATE, 5, 50) INTO v_scheduled;
  IF v_scheduled < 1 THEN RAISE EXCEPTION 'FAIL expected observation jobs scheduled, got %', v_scheduled; END IF;
  SELECT count(*) INTO v_jobs_after FROM jobs
    WHERE job_type='ENGINE_OBSERVATION' AND payload_json->>'run_date' = CURRENT_DATE::text;
  IF v_jobs_after <> v_jobs_before THEN
    RAISE EXCEPTION 'FAIL scheduling not idempotent: before=% after=%', v_jobs_before, v_jobs_after; END IF;

  -- 7. Every job carries the client_id (no cross-client leak in scheduling).
  SELECT count(*) INTO v_other_client FROM jobs
    WHERE job_type='ENGINE_OBSERVATION' AND client_id <> v_cid;
  IF v_other_client <> 0 THEN RAISE EXCEPTION 'FAIL observation job leaked to another client'; END IF;

  RAISE NOTICE 'PASS engine_observation: engines=% obs=% api=%/manual=% mentioned=% recommended=% profiles(search/chat)=(%/%) scheduled=%',
    v_engines, v_obs, v_api, v_manual, v_mentioned, v_recommended,
    v_search_profiles, v_chat_profiles, v_scheduled;
END $$;
DROP TABLE _t4_cid;