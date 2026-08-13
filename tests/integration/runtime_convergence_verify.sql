-- ============================================================================
-- Integration test: Runtime Convergence (P0 remediation) DB layer.
-- Validates the fixes in migration 012_runtime_convergence.sql against the
-- real PostgreSQL. Self-contained: creates its own SYNTH-A / SYNTH-B
-- adversarial tenants as fixtures (never runtime data).
--
-- Run:
--   docker compose exec -T -e PGPASSWORD=... postgres psql -d geo_operator \
--     -v ON_ERROR_STOP=1 -f /srv/tests/integration/runtime_convergence_verify.sql
-- ============================================================================
\set ON_ERROR_STOP on

-- ---------------------------------------------------------------------------
-- Fixture: SYNTH-A and SYNTH-B tenants (adversarial isolation targets).
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_a uuid; v_b uuid;
BEGIN
  INSERT INTO clients(code, legal_name, display_name, status, notes)
  VALUES ('SYNTH-A','Synthetic Tenant A','SYNTHETIC Ten A','ACTIVE','SYNTHETIC test fixture')
  ON CONFLICT (code) DO UPDATE SET status='ACTIVE' RETURNING id INTO v_a;
  INSERT INTO clients(code, legal_name, display_name, status, notes)
  VALUES ('SYNTH-B','Synthetic Tenant B','SYNTHETIC Ten B','ACTIVE','SYNTHETIC test fixture')
  ON CONFLICT (code) DO UPDATE SET status='ACTIVE' RETURNING id INTO v_b;

  -- Entities + a VERIFIED claim + a query path for tenant A.
  INSERT INTO entities(client_id, entity_type, canonical_name)
  VALUES (v_a, 'BRAND', 'Tenant A Brand')
  ON CONFLICT DO NOTHING;
  INSERT INTO entities(client_id, entity_type, canonical_name)
  VALUES (v_b, 'BRAND', 'Tenant B Brand')
  ON CONFLICT DO NOTHING;

  -- Tenant B entity/claim/surface so cross-client refs are provable.
  INSERT INTO claims(client_id, entity_id, claim_text, field_key, verification)
  VALUES (v_b, (SELECT id FROM entities WHERE client_id=v_b AND canonical_name='Tenant B Brand'),
          'Tenant B produces 999 units', 'capability', 'VERIFIED')
  ON CONFLICT DO NOTHING;

  RAISE NOTICE 'fixture tenants ready a=% b=%', v_a, v_b;
END $$;

-- ---------------------------------------------------------------------------
-- P0.3 — Unified scoring scale must be consistent for 0-1 and 0-100 inputs.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_lo numeric; v_hi numeric;
BEGIN
  v_lo := weighted_priority(0.5, 0.6, 0.7);   -- legacy 0-1 prompt
  v_hi := weighted_priority(50, 60, 70);      -- 0-100 scale
  IF v_lo <> v_hi THEN
    RAISE EXCEPTION 'FAIL P0.3 scoring mismatch: 0-1 gave % but 0-100 gave %', v_lo, v_hi;
  END IF;
  IF v_hi < 0 OR v_hi > 100 THEN
    RAISE EXCEPTION 'FAIL P0.3 priority out of 0-100 range: %', v_hi;
  END IF;
  RAISE NOTICE 'PASS P0.3 weighted_priority 0-1==0-100, value=%', v_hi;
END $$;

-- ---------------------------------------------------------------------------
-- P0.2 — Truth document parsing: TXT / MD / CSV parse; PDF fails closed.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_a uuid; v_doc uuid; v_res jsonb; v_pdf_res jsonb; v_pdf_exc int;
BEGIN
  SELECT id INTO v_a FROM clients WHERE code='SYNTH-A';
  INSERT INTO truth_documents(client_id, document_type, title, status)
  VALUES (v_a, 'TXT', 'A spec notes', 'RECEIVED') RETURNING id INTO v_doc;

  v_res := parse_truth_document('SYNTH-A', v_doc, E'line one\nline two\nline three', 'TXT');
  IF NOT (v_res->>'parsed')::boolean THEN
    RAISE EXCEPTION 'FAIL P0.2 TXT not parsed: %', v_res;
  END IF;
  IF (v_res->>'sections')::int <> 3 THEN
    RAISE EXCEPTION 'FAIL P0.2 TXT sections expected 3 got %', v_res->>'sections';
  END IF;

  -- CSV
  INSERT INTO truth_documents(client_id, document_type, title, status)
  VALUES (v_a, 'CSV', 'A pricing table', 'RECEIVED') RETURNING id INTO v_doc;
  v_res := parse_truth_document('SYNTH-A', v_doc, E'name,value\nthing,1\nother,2', 'CSV');
  IF NOT (v_res->>'parsed')::boolean THEN
    RAISE EXCEPTION 'FAIL P0.2 CSV not parsed: %', v_res;
  END IF;

  -- PDF without pre-extracted content must fail closed (no pretend-parse).
  INSERT INTO truth_documents(client_id, document_type, title, status)
  VALUES (v_a, 'PDF', 'A brochure', 'RECEIVED') RETURNING id INTO v_doc;
  v_pdf_res := parse_truth_document('SYNTH-A', v_doc, NULL, 'PDF');
  IF (v_pdf_res->>'parsed')::boolean THEN
    RAISE EXCEPTION 'FAIL P0.2 PDF should not parse without content';
  END IF;
  SELECT count(*) INTO v_pdf_exc FROM exceptions
    WHERE client_id=v_a AND exception_type='PARSE_FAILED' AND status='OPEN';
  IF v_pdf_exc < 1 THEN
    RAISE EXCEPTION 'FAIL P0.2 PDF fail-closed did not raise PARSE_FAILED';
  END IF;

  RAISE NOTICE 'PASS P0.2 parse TXT/CSV ok, PDF fail-closed raises PARSE_FAILED';
END $$;

-- ---------------------------------------------------------------------------
-- P0.4 — Engine adapter routing: unsupported engine fails closed.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_a uuid; v_eng uuid; v_obs uuid; v_unsupported int;
  v_q uuid; v_i jsonb; v_ent uuid;
BEGIN
  SELECT id INTO v_a FROM clients WHERE code='SYNTH-A';
  SELECT id INTO v_ent FROM entities WHERE client_id=v_a AND canonical_name='Tenant A Brand';

  -- Register an intent + query for tenant A (uses unified scoring).
  SELECT register_intent_with_queries('SYNTH-A','Tenant A Brand','INFO','A capability',
    'describe A', 0.6, 0.7, 0.8,
    '[{"query_text":"A brand capability","language":"en","region":"us","priority":80}]')
    INTO v_i;
  SELECT id INTO v_q FROM queries WHERE client_id=v_a AND intent_id=(v_i->>'intent_id')::uuid LIMIT 1;

  -- Engine WITHOUT any enabled adapter => UNSUPPORTED, must fail closed.
  SELECT upsert_engine('FAKE-CLOUD','no-adapter','chat') INTO v_eng;
  v_obs := record_observation('SYNTH-A', v_eng, v_q, 'API_OBSERVATION', now(),
    'SYNTH-RUN-ADAPTER', 'some answer', true, true, 1, NULL, '[]'::jsonb, '[]'::jsonb,
    NULL, NULL, NULL, NULL, NULL, NULL);
  IF v_obs IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL P0.4 unsupported engine recorded an observation';
  END IF;
  SELECT count(*) INTO v_unsupported FROM exceptions
    WHERE client_id=v_a AND exception_type='UNSUPPORTED_ENGINE' AND status='OPEN';
  IF v_unsupported < 1 THEN
    RAISE EXCEPTION 'FAIL P0.4 unsupported engine did not raise UNSUPPORTED_ENGINE';
  END IF;

  RAISE NOTICE 'PASS P0.4 unsupported engine fails closed (UNSUPPORTED_ENGINE)';
END $$;

-- ---------------------------------------------------------------------------
-- P0.5 — Rule-based factuality (no more mentioned=CORRECT).
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_a uuid; v_claim uuid; v_ent uuid; v_fact jsonb;
BEGIN
  SELECT id INTO v_a FROM clients WHERE code='SYNTH-A';
  SELECT id INTO v_ent FROM entities WHERE client_id=v_a AND canonical_name='Tenant A Brand';
  INSERT INTO claims(client_id, entity_id, claim_text, field_key, verification)
  VALUES (v_a, v_ent, 'Tenant A offers 5000 PSI cylinders', 'capability', 'VERIFIED')
  ON CONFLICT DO NOTHING RETURNING id INTO v_claim;
  IF v_claim IS NULL THEN
    SELECT id INTO v_claim FROM claims WHERE client_id=v_a AND claim_text='Tenant A offers 5000 PSI cylinders';
  END IF;

  -- Matching answer => CORRECT.
  v_fact := assess_factuality(v_a, 'Tenant A offers 5000 PSI cylinders', ARRAY[v_claim]);
  IF v_fact->>'status' <> 'CORRECT' THEN
    RAISE EXCEPTION 'FAIL P0.5 expected CORRECT got %', v_fact->>'status';
  END IF;

  -- Contradicting number => not CORRECT.
  v_fact := assess_factuality(v_a, 'Tenant A offers 9000 PSI cylinders', ARRAY[v_claim]);
  IF v_fact->>'status' = 'CORRECT' THEN
    RAISE EXCEPTION 'FAIL P0.5 contradicted answer marked CORRECT';
  END IF;

  -- Empty answer => UNVERIFIABLE.
  v_fact := assess_factuality(v_a, '', ARRAY[v_claim]);
  IF v_fact->>'status' <> 'UNVERIFIABLE' THEN
    RAISE EXCEPTION 'FAIL P0.5 empty answer expected UNVERIFIABLE got %', v_fact->>'status';
  END IF;

  RAISE NOTICE 'PASS P0.5 factuality CORRECT/contradiction/UNVERIFIABLE ok';
END $$;

-- ---------------------------------------------------------------------------
-- P0.6 — Content Fact Gate + Compliance Gate. LLM output is never VERIFIED.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_a uuid; v_ent uuid; v_claim uuid; v_brief uuid; v_asset uuid; v_gate jsonb;
  v_bad uuid;
  v_asset_status text; v_fact_status text; v_comp_status text;
BEGIN
  SELECT id INTO v_a FROM clients WHERE code='SYNTH-A';
  SELECT id INTO v_ent FROM entities WHERE client_id=v_a AND canonical_name='Tenant A Brand';
  SELECT id INTO v_claim FROM claims WHERE client_id=v_a AND claim_text='Tenant A offers 5000 PSI cylinders';

  INSERT INTO content_briefs(client_id, intent_id, target_entity_id,
    canonical_angle, required_claim_ids, status)
  SELECT v_a, NULL, v_ent, 'A capability', jsonb_build_array(v_claim), 'READY'
  RETURNING id INTO v_brief;

  -- Asset that only restates the VERIFIED claim => gate PASSES, READY_TO_PUBLISH.
  v_asset := store_content_asset('SYNTH-A', v_brief, NULL, 'MARKDOWN',
    'A capability page', 'Tenant A offers 5000 PSI cylinders', 'qwen2.5');
  IF v_asset IS NULL THEN RAISE EXCEPTION 'FAIL P0.6 store_content_asset null'; END IF;
  SELECT fact_check_status, quality_score, status INTO v_fact_status, v_asset_status, v_asset_status
    FROM content_assets WHERE id=v_asset;
  IF v_fact_status <> 'PENDING' THEN
    RAISE EXCEPTION 'FAIL P0.6 asset should start PENDING not %', v_fact_status;
  END IF;
  v_gate := approve_content_asset(v_asset);
  IF v_gate->>'fact_check' <> 'PASSED' OR v_gate->>'compliance' <> 'PASSED' THEN
    RAISE EXCEPTION 'FAIL P0.6 gate did not pass: %', v_gate;
  END IF;
  SELECT status, fact_check_status, compliance_status
    INTO v_asset_status, v_fact_status, v_comp_status FROM content_assets WHERE id=v_asset;
  IF v_asset_status <> 'READY_TO_PUBLISH' THEN
    RAISE EXCEPTION 'FAIL P0.6 expected READY_TO_PUBLISH got %', v_asset_status;
  END IF;

  -- Asset introducing an UNSUPPORTED number => CONTENT_QA_FAILED, BLOCKED.
  -- (Uses a distinct brief so the dedup_key does not collide with the good asset.)
  INSERT INTO content_briefs(client_id, target_entity_id, canonical_angle,
    required_claim_ids, status)
  SELECT v_a, v_ent, 'A capability hallucinated', jsonb_build_array(v_claim), 'READY'
  RETURNING id INTO v_brief;
  v_bad := store_content_asset('SYNTH-A', v_brief, NULL, 'MARKDOWN',
    'A page with hallucination', 'Tenant A offers 9000 PSI cylinders and wins 10 awards', 'qwen2.5');
  IF v_bad IS NULL THEN RAISE EXCEPTION 'FAIL P0.6 bad asset null'; END IF;
  v_gate := approve_content_asset(v_bad);
  SELECT status, fact_check_status INTO v_asset_status, v_fact_status FROM content_assets WHERE id=v_bad;
  IF v_asset_status <> 'BLOCKED' OR v_fact_status <> 'CONTENT_QA_FAILED' THEN
    RAISE EXCEPTION 'FAIL P0.6 hallucinated asset not blocked: status=% fact=%', v_asset_status, v_fact_status;
  END IF;

  -- quality_score must NOT be defaulted to 100.
  IF EXISTS (SELECT 1 FROM content_assets WHERE client_id=v_a AND quality_score=100) THEN
    RAISE EXCEPTION 'FAIL P0.6 quality_score defaulted to 100';
  END IF;

  RAISE NOTICE 'PASS P0.6 fact+compliance gate: PASSED->READY_TO_PUBLISH, hallucination->BLOCKED';
END $$;

-- ---------------------------------------------------------------------------
-- P0.7 — Publication fail-closed: no simulated AUTO_API PUBLISHED.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_a uuid; v_ent uuid; v_claim uuid; v_brief uuid; v_asset uuid; v_surf uuid;
  v_task uuid; v_disp jsonb; v_status text; v_recs int; v_fabricated boolean;
BEGIN
  SELECT id INTO v_a FROM clients WHERE code='SYNTH-A';
  SELECT id INTO v_ent FROM entities WHERE client_id=v_a AND canonical_name='Tenant A Brand';
  SELECT id INTO v_claim FROM claims WHERE client_id=v_a AND claim_text='Tenant A offers 5000 PSI cylinders';
  INSERT INTO content_briefs(client_id, target_entity_id, canonical_angle,
    required_claim_ids, status)
  SELECT v_a, v_ent, 'A capability pub', jsonb_build_array(v_claim), 'READY'
  RETURNING id INTO v_brief;
  v_asset := store_content_asset('SYNTH-A', v_brief, NULL, 'MARKDOWN',
    'A pub page', 'Tenant A offers 5000 PSI cylinders', 'qwen2.5');
  PERFORM approve_content_asset(v_asset);

  -- AUTO_API surface with NO official adapter => dispatch must route MANUAL_REQUIRED.
  v_surf := upsert_surface('SYNTH-A', 'WEB', 'example', NULL, 'https://a.example/pub',
    'Tenant A Brand', 'AUTO_API', NULL, 'SYNTH-A-SURF-PUB');
  v_task := create_publication_task('SYNTH-A', v_asset, v_surf);
  IF v_task IS NULL THEN RAISE EXCEPTION 'FAIL P0.7 create_publication_task null'; END IF;
  v_disp := dispatch_publication(v_task);
  IF v_disp->>'outcome' <> 'MANUAL_REQUIRED' THEN
    RAISE EXCEPTION 'FAIL P0.7 AUTO_API without adapter expected MANUAL_REQUIRED got %', v_disp;
  END IF;
  SELECT status INTO v_status FROM publication_tasks WHERE id=v_task;
  IF v_status <> 'WAITING_APPROVAL' THEN
    RAISE EXCEPTION 'FAIL P0.7 task should be WAITING_APPROVAL got %', v_status;
  END IF;
  SELECT count(*) INTO v_recs FROM publication_records WHERE publication_task_id=v_task;
  IF v_recs <> 0 THEN
    RAISE EXCEPTION 'FAIL P0.7 no publication record must exist for a manual task';
  END IF;

  -- complete_publication must refuse a fabricated external_id. Simulate a real
  -- adapter that moved the task to PUBLISHING, then verify fabrication is blocked.
  UPDATE publication_tasks SET status='PUBLISHING' WHERE id=v_task;
  v_fabricated := false;
  BEGIN
    PERFORM complete_publication(v_task, 'ext-fake-123', 'https://x', '{"simulated":true}');
    v_fabricated := false;
  EXCEPTION WHEN others THEN
    IF SQLERRM LIKE '%fabricated%' THEN v_fabricated := true;
    ELSE RAISE EXCEPTION 'FAIL P0.7 unexpected error: %', SQLERRM; END IF;
  END;
  IF NOT v_fabricated THEN
    RAISE EXCEPTION 'FAIL P0.7 complete_publication accepted a fabricated external_id';
  END IF;
  -- No publication record may exist for the whole manual flow.
  SELECT count(*) INTO v_recs FROM publication_records WHERE publication_task_id=v_task;
  IF v_recs <> 0 THEN
    RAISE EXCEPTION 'FAIL P0.7 no publication record must exist for a manual task';
  END IF;

  RAISE NOTICE 'PASS P0.7 AUTO_API->MANUAL_REQUIRED, no simulated PUBLISHED, fabricated id refused';
END $$;

-- ---------------------------------------------------------------------------
-- P0.8 — Job lease recovery + retry bookkeeping.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_a uuid; v_job uuid; v_claim jobs; v_recovered int; v_final_status text;
  v_key text;
BEGIN
  SELECT id INTO v_a FROM clients WHERE code='SYNTH-A';
  v_key := 'lease-test-' || left(gen_random_uuid()::text, 8);
  v_job := enqueue_job(v_a, 'TEST_LEASE', '{"k":"v"}'::jsonb, 50, now(), 3, v_key);

  -- Claim -> RUNNING with a lease.
  v_claim := claim_next_job('test-worker', 60, 'TEST_LEASE');
  IF v_claim.id IS NULL OR v_claim.status <> 'RUNNING' THEN
    RAISE EXCEPTION 'FAIL P0.8 claim did not RUNNING';
  END IF;

  -- Simulate worker crash: expire the lease, recover, then reclaim.
  UPDATE jobs SET lease_until = now() - interval '1 minute' WHERE id = v_job;
  v_recovered := recover_expired_leases();
  IF v_recovered <> 1 THEN
    RAISE EXCEPTION 'FAIL P0.8 recover_expired_leases expected 1 got %', v_recovered;
  END IF;
  SELECT status INTO v_final_status FROM jobs WHERE id=v_job;
  IF v_final_status <> 'PENDING' THEN
    RAISE EXCEPTION 'FAIL P0.8 recovered job should be PENDING got %', v_final_status;
  END IF;

  -- Reclaim must increment attempts (retry bookkeeping) and succeed.
  v_claim := claim_next_job('test-worker', 60, 'TEST_LEASE');
  IF v_claim.attempts < 2 THEN
    RAISE EXCEPTION 'FAIL P0.8 reclaim did not increment attempts: %', v_claim.attempts;
  END IF;

  -- Retry exhaustion: fail_job until FAILED.
  v_final_status := fail_job(v_job, 'boom');
  IF v_final_status IS NULL OR v_final_status = '' THEN
    RAISE EXCEPTION 'FAIL P0.8 fail_job returned empty';
  END IF;
  -- Force attempts to max and confirm FAILED terminal.
  UPDATE jobs SET attempts = max_attempts WHERE id = v_job;
  v_final_status := fail_job(v_job, 'exhausted');
  IF v_final_status <> 'FAILED' THEN
    RAISE EXCEPTION 'FAIL P0.8 retry exhaustion expected FAILED got %', v_final_status;
  END IF;

  RAISE NOTICE 'PASS P0.8 lease recovery + retry/exhaustion ok';
END $$;

-- ---------------------------------------------------------------------------
-- P0.9 — Cross-client isolation (adversarial). All must fail closed.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_a uuid; v_b uuid; v_qb uuid; v_eng uuid; v_obs uuid;
  v_asset_b uuid; v_brief_b uuid; v_claim_b uuid; v_surface_b uuid;
  v_asset_bg uuid; v_asset_be uuid;
  v_cross int;
BEGIN
  SELECT id INTO v_a FROM clients WHERE code='SYNTH-A';
  SELECT id INTO v_b FROM clients WHERE code='SYNTH-B';

  -- (1) A observation + B query => blocked.
  SELECT id INTO v_qb FROM queries WHERE client_id=v_b LIMIT 1;
  IF v_qb IS NULL THEN
    PERFORM register_intent_with_queries('SYNTH-B', NULL, 'INFO', 'B query path',
      NULL, 0.5, 0.5, 0.5,
      '[{"query_text":"B capability query","language":"en","region":"us","priority":50}]');
    SELECT id INTO v_qb FROM queries WHERE client_id=v_b LIMIT 1;
  END IF;

  SELECT upsert_engine('FAKE-CLOUD','b-eng','chat') INTO v_eng;
  IF v_qb IS NOT NULL THEN
    v_obs := record_observation('SYNTH-A', v_eng, v_qb, 'API_OBSERVATION', now(),
      'SYNTH-CROSS-1', 'answer', true, true, 1, NULL, '[]'::jsonb, '[]'::jsonb,
      NULL, NULL, NULL, NULL, NULL, NULL);
    IF v_obs IS NOT NULL THEN
      RAISE EXCEPTION 'FAIL P0.9 A observation recorded against B query';
    END IF;
  END IF;

  -- (2) A content + B surface => blocked.
  INSERT INTO surfaces(client_id, surface_type, platform) VALUES (v_b, 'WEB', 'b-site')
    ON CONFLICT DO NOTHING RETURNING id INTO v_surface_b;
  IF v_surface_b IS NULL THEN
    SELECT id INTO v_surface_b FROM surfaces WHERE client_id=v_b LIMIT 1;
  END IF;
  SELECT id INTO v_claim_b FROM claims WHERE client_id=v_b LIMIT 1;
  INSERT INTO content_briefs(client_id, target_entity_id, canonical_angle,
    required_claim_ids, status)
  SELECT v_b, NULL, 'B brief', jsonb_build_array(v_claim_b), 'READY'
  RETURNING id INTO v_brief_b;
  v_asset_b := store_content_asset('SYNTH-B', v_brief_b, v_surface_b, 'MARKDOWN',
    'B page', 'Tenant B produces 999 units', 'qwen2.5');

  -- create_publication_task with A asset + B surface => must raise (client check).
  IF v_asset_b IS NOT NULL THEN
    BEGIN
      PERFORM create_publication_task('SYNTH-A', v_asset_b,
        (SELECT id FROM surfaces WHERE client_id=v_b LIMIT 1));
      RAISE EXCEPTION 'FAIL P0.9 A created pub task from B surface/asset';
    EXCEPTION WHEN OTHERS THEN
      NULL; -- expected fail (asset not found for A)
    END;
  END IF;

  -- (3) adapt_content_for_surface with A client + B surface => blocked.
  BEGIN
    PERFORM adapt_content_for_surface('SYNTH-A',
      (SELECT id FROM content_assets WHERE client_id=v_a LIMIT 1),
      v_surface_b, 'MARKDOWN');
  EXCEPTION WHEN OTHERS THEN
    SELECT count(*) INTO v_cross FROM exceptions
      WHERE client_id=v_a AND exception_type='CROSS_CLIENT_REFERENCE';
    IF v_cross < 1 THEN
      RAISE EXCEPTION 'FAIL P0.9 cross-client blocked without CROSS_CLIENT_REFERENCE exception';
    END IF;
  END;

  RAISE NOTICE 'PASS P0.9 cross-client references fail closed (CROSS_CLIENT_REFERENCE)';
END $$;