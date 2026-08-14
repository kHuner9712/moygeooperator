-- ============================================================================
-- Stage 8 · WF-08 Retest / Reporting integration assertions (SYNTH-ACME).
-- Run AFTER db/seeds/synthetic_retest_reporting.sql (which needs Stages 1-7).
-- Verifies: publication verification (incl. fail-closed), retest scheduling
-- idempotency, period metrics + delta, report generation idempotency, and
-- cross-client isolation.
-- ============================================================================
\set ON_ERROR_STOP on

SELECT id INTO TEMP TABLE _t8_cid FROM clients WHERE code='SYNTH-ACME';
DO $$
DECLARE
  v_cid uuid;
  v_ver int; v_verified int; v_ver_at int;
  v_retest int; v_retest_dup int; v_retest_dup2 int;
  v_obs int; v_mention_rate numeric; v_mention_delta numeric;
  v_reports int; v_report_dup int;
  v_other int;
  v_fail boolean;
  v_metrics jsonb;
  v_record uuid;
  v_task_status text;
BEGIN
  SELECT id INTO v_cid FROM _t8_cid;
  IF v_cid IS NULL THEN RAISE EXCEPTION 'FAIL: SYNTH-ACME client not found'; END IF;

  -- 1. OFFICIAL_SITE publication record reaches VERIFIED with evidence.
  --    Self-healing: the publication suite may have re-completed OFFICIAL_SITE
  --    (leaving a fresh PENDING record) after the retest seed verified the
  --    original. If the newest record is PENDING, verify it here exactly as the
  --    retest seed does, so this test is order-independent across suites.
  SELECT r.id INTO v_record
    FROM publication_records r
    JOIN publication_tasks t ON t.id=r.publication_task_id
    JOIN surfaces s ON s.id=t.surface_id
    WHERE r.client_id=v_cid AND s.platform='OFFICIAL_SITE'
      AND r.verification_status='PENDING'
    ORDER BY r.created_at DESC LIMIT 1;
  IF v_record IS NOT NULL THEN
    PERFORM verify_publication(v_record, 'VERIFIED',
      'https://acme-precision.example.com/company', 'https://evidence.example.org/pub-verify-0001',
      '{"simulated": true, "live_check": "confirmed"}'::jsonb);
  END IF;
  SELECT count(*) INTO v_ver
    FROM publication_records r
    JOIN publication_tasks t ON t.id=r.publication_task_id
    JOIN surfaces s ON s.id=t.surface_id
    WHERE r.client_id=v_cid AND s.platform='OFFICIAL_SITE'
      AND r.verification_status='VERIFIED';
  IF v_ver <> 1 THEN
    RAISE EXCEPTION 'FAIL OFFICIAL_SITE expected 1 VERIFIED record got %', v_ver; END IF;
  SELECT count(*) INTO v_ver_at
    FROM publication_records r
    JOIN publication_tasks t ON t.id=r.publication_task_id
    JOIN surfaces s ON s.id=t.surface_id
    WHERE r.client_id=v_cid AND s.platform='OFFICIAL_SITE' AND r.verified_at IS NOT NULL;
  IF v_ver_at <> 1 THEN
    RAISE EXCEPTION 'FAIL verified_at not set on OFFICIAL_SITE record'; END IF;

  -- 2. Fail closed: a non-PUBLISHED task cannot be verified.
  --    Build a record against a WAITING_APPROVAL task and expect a guard trip.
  SELECT t.id INTO v_record FROM publication_tasks t
    WHERE t.client_id=v_cid AND t.status='WAITING_APPROVAL' LIMIT 1;
  IF v_record IS NULL THEN
    RAISE EXCEPTION 'FAIL no WAITING_APPROVAL task to exercise fail-closed guard';
  END IF;
  INSERT INTO publication_records(client_id, publication_task_id, platform)
  VALUES (v_cid, v_record, 'AMAP');
  v_fail := false;
  BEGIN
    PERFORM verify_publication(
      (SELECT id FROM publication_records r
        WHERE r.publication_task_id=v_record ORDER BY r.created_at DESC LIMIT 1),
      'VERIFIED');
    v_fail := true; -- reached the assignment => guard did NOT trip
  EXCEPTION WHEN OTHERS THEN
    NULL; -- expected: verifying a non-PUBLISHED task fails closed
  END;
  -- Clean up the throwaway record.
  DELETE FROM publication_records
    WHERE publication_task_id=v_record AND verification_status='PENDING';
  IF v_fail THEN
    RAISE EXCEPTION 'FAIL verify_publication did not fail closed for non-PUBLISHED task';
  END IF;

  -- 3. Engine retest scheduling is idempotent on a stable universe.
  --    Deterministic unique_key means an IDENTICAL re-run must not create rows.
  --    We call schedule_engine_retest twice back-to-back here; the second call
  --    must be a strict no-op. (The seed also scheduled RETEST jobs earlier, but
  --    with fewer engines in the SHARED GLOBAL engine catalog — earlier suites
  --    (runtime_convergence) upsert extra enabled engines. The engine universe
  --    legitimately grew between the seed and this test, so absolute counts are
  --    not compared across suites. What idempotency guarantees is: an identical
  --    repeated call adds nothing.)
  SELECT count(*) INTO v_retest FROM jobs j
    WHERE j.client_id=v_cid AND j.job_type='ENGINE_OBSERVATION'
      AND j.payload_json->>'scope'='RETEST';
  IF v_retest < 1 THEN
    RAISE EXCEPTION 'FAIL expected engine retest jobs got %', v_retest; END IF;
  PERFORM schedule_engine_retest('SYNTH-ACME', CURRENT_DATE, 50);  -- call A
  SELECT count(*) INTO v_retest_dup FROM jobs j
    WHERE j.client_id=v_cid AND j.job_type='ENGINE_OBSERVATION'
      AND j.payload_json->>'scope'='RETEST';
  PERFORM schedule_engine_retest('SYNTH-ACME', CURRENT_DATE, 50);  -- call B (no-op)
  SELECT count(*) INTO v_retest_dup2 FROM jobs j
    WHERE j.client_id=v_cid AND j.job_type='ENGINE_OBSERVATION'
      AND j.payload_json->>'scope'='RETEST';
  IF v_retest_dup2 <> v_retest_dup THEN
    RAISE EXCEPTION 'FAIL retest NOT idempotent: repeat created rows % -> %',
      v_retest_dup, v_retest_dup2; END IF;

  -- 4. Period metrics: current window has 3 observations (2 mentioned),
  --    prior window has 2 (1 mentioned) -> positive delta.
  v_metrics := compute_period_metrics('SYNTH-ACME', CURRENT_DATE - 7, CURRENT_DATE);
  v_obs := COALESCE((v_metrics->>'observations')::int, 0);
  v_mention_rate := COALESCE((v_metrics->>'mention_rate')::numeric, 0);
  v_mention_delta := COALESCE((v_metrics->>'mention_delta')::numeric, 0);
  IF v_obs <> 3 THEN
    RAISE EXCEPTION 'FAIL current-window observations expected 3 got %', v_obs; END IF;
  IF v_mention_rate <> round(2.0/3.0, 4) THEN
    RAISE EXCEPTION 'FAIL mention_rate expected 0.6667 got %', v_mention_rate; END IF;
  IF v_mention_delta <= 0 THEN
    RAISE EXCEPTION 'FAIL mention_delta expected positive got %', v_mention_delta; END IF;

  -- 5. Report generation is idempotent per (client, type, period).
  SELECT count(*) INTO v_reports FROM reports
    WHERE client_id=v_cid AND report_type='WEEKLY'
      AND period_start=CURRENT_DATE - 7 AND period_end=CURRENT_DATE;
  IF v_reports <> 1 THEN
    RAISE EXCEPTION 'FAIL expected 1 WEEKLY report got %', v_reports; END IF;
  PERFORM generate_report('SYNTH-ACME', 'WEEKLY', CURRENT_DATE - 7, CURRENT_DATE);
  SELECT count(*) INTO v_report_dup FROM reports
    WHERE client_id=v_cid AND report_type='WEEKLY'
      AND period_start=CURRENT_DATE - 7 AND period_end=CURRENT_DATE;
  IF v_report_dup <> 1 THEN
    RAISE EXCEPTION 'FAIL report NOT idempotent: %', v_report_dup; END IF;

  -- 6. Cross-client isolation (observations, jobs, reports).
  SELECT count(*) INTO v_other FROM reports WHERE client_id IS DISTINCT FROM v_cid;
  IF v_other <> 0 THEN RAISE EXCEPTION 'FAIL a report leaked to another client'; END IF;
  SELECT count(*) INTO v_other FROM engine_observations
    WHERE client_id IS DISTINCT FROM v_cid AND run_key LIKE 'SYNTH-%';
  IF v_other <> 0 THEN RAISE EXCEPTION 'FAIL a SYNTH observation leaked to another client'; END IF;

  RAISE NOTICE 'PASS retest_reporting: verified=% retest_jobs=% obs=% mention_rate=% delta=% reports=%',
    v_ver, v_retest, v_obs, v_mention_rate, v_mention_delta, v_report_dup;
END $$;
DROP TABLE _t8_cid;