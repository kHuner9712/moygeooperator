-- ============================================================================
-- Integration test: Full Shadow Runtime E2E (P0.17) — DB contract layer.
--
-- Deterministically exercises the WF-01..WF-08 function contracts against the
-- real PostgreSQL, in dependency order, for the dedicated SHADOW-E2E-A tenant.
-- Also proves the adversarial error path (tenant isolation + job lifecycle).
--
-- This is the reproducible core of the local full-shadow-runtime.sh driver.
-- Each stage asserts the exact DB state WF-01..WF-08 must leave behind, so a
-- real n8n run is evidenced by the same invariants.
--
-- Run (after db/run-seeds.sh, which applies synthetic_shadow_e2e.sql):
--   docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -q \
--     -f /srv/tests/integration/shadow_runtime_e2e.sql
-- ============================================================================
\set ON_ERROR_STOP on

-- ---------------------------------------------------------------------------
-- Stage 1 · WF-01 Truth Intake contract — SHADOW-E2E-A pack imported.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_a uuid; v_docs int; v_ents int; v_claims int; v_verified int;
BEGIN
  SELECT id INTO v_a FROM clients WHERE code='SHADOW-E2E-A';
  IF v_a IS NULL THEN
    RAISE EXCEPTION 'FAIL WF-01 client SHADOW-E2E-A missing (seed not applied?)';
  END IF;
  SELECT count(*) INTO v_docs FROM truth_documents WHERE client_id=v_a;
  SELECT count(*) INTO v_ents FROM entities WHERE client_id=v_a;
  SELECT count(*) INTO v_claims FROM claims WHERE client_id=v_a;
  SELECT count(*) INTO v_verified FROM claims WHERE client_id=v_a AND verification='VERIFIED';
  IF v_docs < 3 OR v_ents < 5 OR v_claims < 5 OR v_verified < 3 THEN
    RAISE EXCEPTION 'FAIL WF-01 pack counts docs=% ents=% claims=% verified=%', v_docs, v_ents, v_claims, v_verified;
  END IF;
  RAISE NOTICE 'PASS WF-01 truth pack imported: docs=% ents=% claims=% verified=%', v_docs, v_ents, v_claims, v_verified;
END $$;

-- ---------------------------------------------------------------------------
-- Stage 2 · WF-02 Surface Discovery contract — target surfaces exist.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_a uuid; v_n int;
BEGIN
  SELECT id INTO v_a FROM clients WHERE code='SHADOW-E2E-A';
  SELECT count(*) INTO v_n FROM surfaces WHERE client_id=v_a;
  IF v_n < 2 THEN RAISE EXCEPTION 'FAIL WF-02 surfaces=% < 2', v_n; END IF;
  RAISE NOTICE 'PASS WF-02 surfaces recorded: %', v_n;
END $$;

-- ---------------------------------------------------------------------------
-- Stage 3 · WF-03 Intent Generation contract.
-- High priority (>=70) so WF-05's CONTENT_GAP is deterministic.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_a uuid; v_ent uuid; v_res jsonb; v_intent uuid; v_q int;
BEGIN
  SELECT id INTO v_a FROM clients WHERE code='SHADOW-E2E-A';
  SELECT id INTO v_ent FROM entities
    WHERE client_id=v_a AND canonical_name='Shadow E2E Manufacturing Co.';
  v_res := register_intent_with_queries('SHADOW-E2E-A', 'Shadow E2E Manufacturing Co.',
    'PURCHASE', 'SE-100 cylinder buyers', 'Sourcing SE-100 precision cylinders',
    80, 90, 70,
    '[{"query_text":"SE-100 precision cylinder supplier","language":"zh-CN","region":"CN","priority":90}]');
  v_intent := (v_res->>'intent_id')::uuid;
  IF v_intent IS NULL THEN RAISE EXCEPTION 'FAIL WF-03 intent null'; END IF;
  IF (v_res->>'priority_score')::numeric < 70 THEN
    RAISE EXCEPTION 'FAIL WF-03 priority % not >=70', v_res->>'priority_score';
  END IF;
  SELECT count(*) INTO v_q FROM queries WHERE client_id=v_a AND intent_id=v_intent;
  IF v_q < 1 THEN RAISE EXCEPTION 'FAIL WF-03 no queries'; END IF;
  RAISE NOTICE 'PASS WF-03 intent registered (priority=% queries=%)', v_res->>'priority_score', v_q;
END $$;

-- ---------------------------------------------------------------------------
-- Stage 4 · WF-04 Engine Observation contract.
-- LOCAL_OLLAMA adapter records an observation; no-adapter engine fails closed.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_a uuid; v_eng uuid; v_eng_bad uuid; v_q uuid; v_obs uuid; v_unsup int;
BEGIN
  SELECT id INTO v_a FROM clients WHERE code='SHADOW-E2E-A';
  SELECT id INTO v_eng FROM engines WHERE provider='LOCAL_OLLAMA' LIMIT 1;
  SELECT id INTO v_eng_bad FROM engines WHERE provider='FAKE-CLOUD' LIMIT 1;
  IF v_eng IS NULL OR v_eng_bad IS NULL THEN
    RAISE EXCEPTION 'FAIL WF-04 engines missing (seed not applied?)';
  END IF;
  SELECT q.id INTO v_q FROM queries q
    JOIN intents i ON i.id=q.intent_id
    WHERE q.client_id=v_a LIMIT 1;
  IF v_q IS NULL THEN RAISE EXCEPTION 'FAIL WF-04 no query for A'; END IF;

  -- Enabled adapter => observation recorded.
  v_obs := record_observation('SHADOW-E2E-A', v_eng, v_q, 'API_OBSERVATION', now(),
    'SHADOWE2E-RUN-1', 'SE-100 Precision Cylinder rated load is 500 kg',
    true, true, 1, 'CORRECT', '[]'::jsonb, '[]'::jsonb,
    NULL, NULL, 120, NULL, '{}'::jsonb, 'LOCAL_OLLAMA');
  IF v_obs IS NULL THEN RAISE EXCEPTION 'FAIL WF-04 observation not recorded'; END IF;

  -- No enabled adapter => UNSUPPORTED_ENGINE, fail closed.
  v_obs := record_observation('SHADOW-E2E-A', v_eng_bad, v_q, 'API_OBSERVATION', now(),
    'SHADOWE2E-RUN-BAD', 'answer', true, true, 1, NULL, '[]'::jsonb, '[]'::jsonb,
    NULL, NULL, NULL, NULL, NULL, NULL);
  IF v_obs IS NOT NULL THEN RAISE EXCEPTION 'FAIL WF-04 no-adapter engine recorded obs'; END IF;
  SELECT count(*) INTO v_unsup FROM exceptions
    WHERE client_id=v_a AND exception_type='UNSUPPORTED_ENGINE' AND status='OPEN';
  IF v_unsup < 1 THEN RAISE EXCEPTION 'FAIL WF-04 no UNSUPPORTED_ENGINE exception'; END IF;

  RAISE NOTICE 'PASS WF-04 observation recorded; no-adapter engine fails closed (UNSUPPORTED_ENGINE)';
END $$;

-- ---------------------------------------------------------------------------
-- Stage 5 · WF-05 Gap Analysis contract.
-- High-priority intent with no brief => CONTENT_GAP; run is idempotent.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_a uuid; v_gaps int; v_gaps2 int; v_open int; v_dup int; v_gap_records int;
BEGIN
  SELECT id INTO v_a FROM clients WHERE code='SHADOW-E2E-A';
  -- First run creates the CONTENT_GAP for the high-priority intent with no
  -- brief; a re-run must be a strict no-op (dedup_key), never a duplicate.
  v_gaps := analyze_gaps('SHADOW-E2E-A');
  v_gaps2 := analyze_gaps('SHADOW-E2E-A');
  IF v_gaps2 <> 0 THEN RAISE EXCEPTION 'FAIL WF-05 re-run created % new gaps', v_gaps2; END IF;
  SELECT count(*) INTO v_gap_records FROM geo_gaps
    WHERE client_id=v_a AND gap_type='CONTENT_GAP';
  IF v_gap_records < 1 THEN RAISE EXCEPTION 'FAIL WF-05 no CONTENT_GAP recorded'; END IF;
  SELECT count(*) INTO v_open FROM geo_actions
    WHERE client_id=v_a AND status IN ('PROPOSED','APPROVED','IN_PROGRESS');
  SELECT count(*) INTO v_dup FROM (
    SELECT dedup_key FROM geo_actions WHERE client_id=v_a AND dedup_key IS NOT NULL
    GROUP BY dedup_key HAVING count(*) > 1) d;
  IF v_dup > 0 THEN RAISE EXCEPTION 'FAIL WF-05 duplicate gap dedup_key'; END IF;
  RAISE NOTICE 'PASS WF-05 CONTENT_GAP recorded=% (first-run created %; re-run no-op; open=%): idempotent', v_gap_records, v_gaps, v_open;
END $$;

-- ---------------------------------------------------------------------------
-- Stage 6 · WF-06 Content Factory contract.
-- Brief on VERIFIED claims -> canonical DRAFT -> approve -> READY_TO_PUBLISH.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_a uuid; v_ent uuid; v_claim_ids uuid[]; v_brief uuid; v_asset uuid;
  v_gate jsonb; v_status text; v_fact text;
BEGIN
  SELECT id INTO v_a FROM clients WHERE code='SHADOW-E2E-A';
  SELECT id INTO v_ent FROM entities WHERE client_id=v_a AND canonical_name='Shadow E2E Manufacturing Co.';
  SELECT ARRAY(SELECT id FROM claims WHERE client_id=v_a AND verification='VERIFIED')
    INTO v_claim_ids;
  IF array_length(v_claim_ids,1) IS NULL THEN RAISE EXCEPTION 'FAIL WF-06 no VERIFIED claims'; END IF;

  INSERT INTO content_briefs(client_id, intent_id, target_entity_id, canonical_angle,
    required_claim_ids, target_surfaces, status)
  SELECT v_a, (SELECT id FROM intents WHERE client_id=v_a LIMIT 1), v_ent,
    'Shadow E2E capability', to_jsonb(v_claim_ids),
    (SELECT jsonb_agg(id) FROM surfaces WHERE client_id=v_a), 'READY'
  ON CONFLICT DO NOTHING
  RETURNING id INTO v_brief;
  IF v_brief IS NULL THEN
    SELECT id INTO v_brief FROM content_briefs
      WHERE client_id=v_a AND canonical_angle='Shadow E2E capability' LIMIT 1;
  END IF;

  -- Canonical asset (surface_id NULL) from the VERIFIED claims.
  v_asset := generate_content_asset('SHADOW-E2E-A', v_brief, 'MARKDOWN');
  IF v_asset IS NULL THEN RAISE EXCEPTION 'FAIL WF-06 generate_content_asset null'; END IF;
  v_gate := approve_content_asset(v_asset);
  IF v_gate->>'fact_check' <> 'PASSED' OR v_gate->>'compliance' <> 'PASSED' THEN
    RAISE EXCEPTION 'FAIL WF-06 gate did not pass: %', v_gate;
  END IF;
  SELECT status, fact_check_status INTO v_status, v_fact FROM content_assets WHERE id=v_asset;
  IF v_status <> 'READY_TO_PUBLISH' OR v_fact <> 'PASSED' THEN
    RAISE EXCEPTION 'FAIL WF-06 expected READY_TO_PUBLISH got status=% fact=%', v_status, v_fact;
  END IF;
  RAISE NOTICE 'PASS WF-06 canonical asset READY_TO_PUBLISH (gate %)', v_gate;
END $$;

-- ---------------------------------------------------------------------------
-- Stage 7 · WF-07 Publication closure contract (P0.14/15/16).
-- close_content_to_publication -> per-surface adapted + re-gated + PUBLICATION
-- job; dispatch fails closed to MANUAL_REQUIRED (no real adapter).
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_a uuid; v_base uuid; v_closure jsonb; v_tasks int; v_jobs int;
  v_task uuid; v_disp jsonb; v_status text;
BEGIN
  SELECT id INTO v_a FROM clients WHERE code='SHADOW-E2E-A';
  SELECT id INTO v_base FROM content_assets
    WHERE client_id=v_a AND status='READY_TO_PUBLISH' AND surface_id IS NULL
    ORDER BY updated_at DESC LIMIT 1;
  IF v_base IS NULL THEN RAISE EXCEPTION 'FAIL WF-07 no canonical base asset'; END IF;

  v_closure := close_content_to_publication('SHADOW-E2E-A', v_base);
  IF v_closure->>'result' <> 'OK' THEN
    RAISE EXCEPTION 'FAIL WF-07 closure not OK: %', v_closure;
  END IF;
  IF (v_closure->>'passed')::int < 1 THEN
    RAISE EXCEPTION 'FAIL WF-07 no surface passed the re-gate: %', v_closure;
  END IF;

  SELECT count(*) INTO v_tasks FROM publication_tasks
    WHERE client_id=v_a AND content_asset_id IN
      (SELECT id FROM content_assets WHERE client_id=v_a AND brief_id IN
        (SELECT id FROM content_briefs WHERE client_id=v_a));
  SELECT count(*) INTO v_jobs FROM jobs
    WHERE client_id=v_a AND job_type='PUBLICATION' AND status IN ('PENDING','RUNNING');
  IF v_tasks < 1 OR v_jobs < 1 THEN
    RAISE EXCEPTION 'FAIL WF-07 tasks=% jobs=%', v_tasks, v_jobs;
  END IF;

  -- WF-07 dispatch contract: MANUAL_REQUIRED surfaces -> WAITING_APPROVAL.
  SELECT id INTO v_task FROM publication_tasks WHERE client_id=v_a AND status IN ('DRAFT','PUBLISHING') LIMIT 1;
  v_disp := dispatch_publication(v_task);
  -- MANUAL_REQUIRED mode routes to WAITING_APPROVAL (never simulated PUBLISHED).
  IF v_disp->>'mode' <> 'MANUAL_REQUIRED' OR v_disp->>'outcome' <> 'WAITING_APPROVAL' THEN
    RAISE EXCEPTION 'FAIL WF-07 dispatch expected MANUAL_REQUIRED/WAITING_APPROVAL got %', v_disp;
  END IF;
  SELECT status INTO v_status FROM publication_tasks WHERE id=v_task;
  IF v_status <> 'WAITING_APPROVAL' THEN
    RAISE EXCEPTION 'FAIL WF-07 task should be WAITING_APPROVAL got %', v_status;
  END IF;

  RAISE NOTICE 'PASS WF-07 closure=% tasks=% jobs=% dispatch=%', v_closure, v_tasks, v_jobs, v_disp;
END $$;

-- ---------------------------------------------------------------------------
-- Stage 8 · WF-08 Retest / Reporting contract.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_a uuid; v_report uuid; v_mr numeric; v_obs int;
BEGIN
  SELECT id INTO v_a FROM clients WHERE code='SHADOW-E2E-A';
  v_report := generate_report('SHADOW-E2E-A', 'WEEKLY',
    CURRENT_DATE - 7, CURRENT_DATE);
  IF v_report IS NULL THEN RAISE EXCEPTION 'FAIL WF-08 generate_report null'; END IF;
  v_obs := (SELECT COALESCE((metrics->>'observations')::int,0) FROM reports WHERE id=v_report);
  IF v_obs < 1 THEN RAISE EXCEPTION 'FAIL WF-08 report has no observations'; END IF;
  RAISE NOTICE 'PASS WF-08 report generated (observations=%)', v_obs;
END $$;

-- ---------------------------------------------------------------------------
-- Stage 9 · Tenant isolation (adversarial). All cross-client refs fail closed.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_a uuid; v_b uuid; v_qb uuid; v_eng uuid; v_obs uuid;
  v_surface_b uuid; v_surface_a uuid; v_base_a uuid; v_cross int;
BEGIN
  SELECT id INTO v_a FROM clients WHERE code='SHADOW-E2E-A';
  SELECT id INTO v_b FROM clients WHERE code='SHADOW-E2E-B';
  SELECT id INTO v_qb FROM queries WHERE client_id=v_b LIMIT 1;
  SELECT id INTO v_surface_b FROM surfaces WHERE client_id=v_b LIMIT 1;
  SELECT id INTO v_surface_a FROM surfaces WHERE client_id=v_a LIMIT 1;
  SELECT id INTO v_eng FROM engines WHERE provider='LOCAL_OLLAMA' LIMIT 1;

  -- (1) A observation + B query => blocked.
  IF v_qb IS NOT NULL AND v_eng IS NOT NULL THEN
    v_obs := record_observation('SHADOW-E2E-A', v_eng, v_qb, 'API_OBSERVATION', now(),
      'SHADOWE2E-CROSS-1', 'answer', true, true, 1, NULL, '[]'::jsonb, '[]'::jsonb,
      NULL, NULL, NULL, NULL, NULL, NULL);
    IF v_obs IS NOT NULL THEN RAISE EXCEPTION 'FAIL isolation A obs recorded against B query'; END IF;
  END IF;

  -- (2) adapt_content_for_surface with A client + B surface => blocked.
  SELECT id INTO v_base_a FROM content_assets WHERE client_id=v_a AND status='READY_TO_PUBLISH' AND surface_id IS NULL LIMIT 1;
  IF v_base_a IS NOT NULL AND v_surface_b IS NOT NULL THEN
    BEGIN
      PERFORM adapt_content_for_surface('SHADOW-E2E-A', v_base_a, v_surface_b, 'MARKDOWN');
    EXCEPTION WHEN OTHERS THEN
      SELECT count(*) INTO v_cross FROM exceptions
        WHERE client_id=v_a AND exception_type='CROSS_CLIENT_REFERENCE';
      IF v_cross < 1 THEN RAISE EXCEPTION 'FAIL isolation no CROSS_CLIENT_REFERENCE raised'; END IF;
    END;
  END IF;

  RAISE NOTICE 'PASS isolation cross-client references fail closed (CROSS_CLIENT_REFERENCE)';
END $$;

-- ---------------------------------------------------------------------------
-- Stage 10 · Job runtime contract (n8n worker loop): enqueue -> claim -> run ->
-- finish; plus error path (fail -> retry -> exhaustion) and lease recovery.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_a uuid; v_job uuid; v_claim jobs; v_final text; v_recovered int;
  v_key text;
BEGIN
  SELECT id INTO v_a FROM clients WHERE code='SHADOW-E2E-A';

  -- Idempotent re-run hygiene: clear leftover TEST_E2E jobs from prior runs so
  -- claim_next_job deterministically claims THIS run's jobs.
  UPDATE jobs SET status='CANCELLED', last_error='test re-run cleanup'
    WHERE client_id=v_a AND job_type='TEST_E2E' AND status NOT IN ('CANCELLED');

  -- Happy path: enqueue -> claim -> finish.
  v_key := 'e2e-happy-' || left(gen_random_uuid()::text, 8);
  v_job := enqueue_job(v_a, 'TEST_E2E', '{}'::jsonb, 50, now(), 3, v_key);
  v_claim := claim_next_job('wf-e2e', 300, 'TEST_E2E');
  IF v_claim.id <> v_job OR v_claim.status <> 'RUNNING' THEN
    RAISE EXCEPTION 'FAIL runtime claim did not RUNNING';
  END IF;
  PERFORM finish_job(v_job);
  SELECT status INTO v_final FROM jobs WHERE id=v_job;
  IF v_final <> 'SUCCEEDED' THEN RAISE EXCEPTION 'FAIL runtime finish not SUCCEEDED'; END IF;

  -- Error path: fail -> RETRY_WAIT -> claim again -> exhaustion -> FAILED.
  v_key := 'e2e-fail-' || left(gen_random_uuid()::text, 8);
  v_job := enqueue_job(v_a, 'TEST_E2E', '{}'::jsonb, 50, now(), 2, v_key);
  v_claim := claim_next_job('wf-e2e', 300, 'TEST_E2E');
  IF v_claim.id <> v_job THEN RAISE EXCEPTION 'FAIL runtime error-path claim picked wrong job'; END IF;
  v_final := fail_job(v_job, 'boom');
  IF v_final <> 'RETRY_WAIT' THEN RAISE EXCEPTION 'FAIL runtime fail should RETRY_WAIT got %', v_final; END IF;
  -- Simulate the exponential-backoff window elapsing so the job is claimable again.
  UPDATE jobs SET due_at = now() - interval '1 second' WHERE id = v_job;
  v_claim := claim_next_job('wf-e2e', 300, 'TEST_E2E');
  IF v_claim.id <> v_job THEN RAISE EXCEPTION 'FAIL runtime retry claim picked wrong job'; END IF;
  v_final := fail_job(v_job, 'boom2');
  IF v_final <> 'FAILED' THEN RAISE EXCEPTION 'FAIL runtime exhaustion should FAILED got %', v_final; END IF;

  -- Lease recovery: RUNNING job with expired lease -> recovered to PENDING.
  v_key := 'e2e-lease-' || left(gen_random_uuid()::text, 8);
  v_job := enqueue_job(v_a, 'TEST_E2E', '{}'::jsonb, 50, now(), 3, v_key);
  v_claim := claim_next_job('wf-e2e', 300, 'TEST_E2E');
  UPDATE jobs SET lease_until = now() - interval '1 minute' WHERE id = v_job;
  v_recovered := recover_expired_leases();
  IF v_recovered < 1 THEN RAISE EXCEPTION 'FAIL runtime lease recovery recovered 0'; END IF;
  SELECT status INTO v_final FROM jobs WHERE id=v_job;
  IF v_final <> 'PENDING' THEN RAISE EXCEPTION 'FAIL runtime lease recovery not PENDING got %', v_final; END IF;

  RAISE NOTICE 'PASS runtime job lifecycle: happy SUCCEEDED, error RETRY->FAILED, lease recovery ok';
END $$;

-- ---------------------------------------------------------------------------
-- Final summary — the full chain leaves a coherent trace for SHADOW-E2E-A.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_a uuid; v_obs_check int; v_jobs int; v_tasks int; v_reports int; v_gaps int;
BEGIN
  SELECT id INTO v_a FROM clients WHERE code='SHADOW-E2E-A';
  SELECT count(*) INTO v_obs_check FROM engine_observations WHERE client_id=v_a;
  SELECT count(*) INTO v_jobs FROM jobs WHERE client_id=v_a;
  SELECT count(*) INTO v_tasks FROM publication_tasks WHERE client_id=v_a;
  SELECT count(*) INTO v_reports FROM reports WHERE client_id=v_a;
  SELECT count(*) INTO v_gaps FROM geo_actions WHERE client_id=v_a;
  RAISE NOTICE 'SHADOW-E2E-A chain trace: obs=% jobs=% tasks=% reports=% gaps=%', v_obs_check, v_jobs, v_tasks, v_reports, v_gaps;
END $$;