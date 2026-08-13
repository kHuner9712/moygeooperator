-- ============================================================================
-- Integration test: Truth Intake vertical slice (Stage 2).
-- Asserts the SYNTHETIC seed produced the expected state on the SYNTH-ACME
-- client. Run AFTER db/seeds/synthetic_truth_pack.sql.
--   docker compose exec -T -e PGUSER=geo_operator -e PGPASSWORD=... \
--     postgres psql -d geo_operator -v ON_ERROR_STOP=1 -f /srv/tests/integration/truth_intake_verify.sql
-- ============================================================================
\set ON_ERROR_STOP on

DO $$
DECLARE
  v_cid uuid;
  v_docs int; v_ents int; v_claims int; v_evidence int; v_verified int; v_draft int;
  v_conflict int; v_missing int; v_synth int;
BEGIN
  SELECT id INTO v_cid FROM clients WHERE code='SYNTH-ACME';
  IF v_cid IS NULL THEN RAISE EXCEPTION 'FAIL: SYNTH-ACME client not found'; END IF;

  SELECT count(*) INTO v_docs FROM truth_documents WHERE client_id=v_cid;
  SELECT count(*) INTO v_ents FROM entities WHERE client_id=v_cid;
  SELECT count(*) INTO v_claims FROM claims WHERE client_id=v_cid;
  SELECT count(*) INTO v_evidence FROM evidence_items
    WHERE client_id=v_cid AND source_uri LIKE 'synthetic://%';
  SELECT count(*) INTO v_verified FROM claims WHERE client_id=v_cid AND verification='VERIFIED';
  SELECT count(*) INTO v_draft FROM claims WHERE client_id=v_cid AND verification='DRAFT';
  SELECT count(*) INTO v_conflict FROM exceptions WHERE client_id=v_cid AND exception_type='FACT_CONFLICT' AND status='OPEN';
  -- Fail-closed claim exception from the truth slice (C10 factory_size has no
  -- source doc). Scope to related_object_type='claim' so exceptions raised by
  -- later stages (e.g. GEO_GAP CLIENT_DATA_REQUIRED) don't perturb this slice.
  SELECT count(*) INTO v_missing FROM exceptions
    WHERE client_id=v_cid AND exception_type='CLIENT_DATA_REQUIRED'
      AND related_object_type='claim' AND status='OPEN';
  SELECT count(*) INTO v_synth FROM clients WHERE code='SYNTH-ACME' AND notes ILIKE '%SYNTHETIC%';

  IF v_docs <> 4 THEN RAISE EXCEPTION 'FAIL documents expected 4 got %', v_docs; END IF;
  IF v_ents <> 6 THEN RAISE EXCEPTION 'FAIL entities expected 6 got %', v_ents; END IF;
  IF v_claims <> 10 THEN RAISE EXCEPTION 'FAIL claims expected 10 got %', v_claims; END IF;
  IF v_evidence <> 9 THEN RAISE EXCEPTION 'FAIL evidence expected 9 got %', v_evidence; END IF;
  IF v_verified <> 4 THEN RAISE EXCEPTION 'FAIL verified expected 4 got %', v_verified; END IF;
  IF v_draft <> 6 THEN RAISE EXCEPTION 'FAIL draft expected 6 got %', v_draft; END IF;
  IF v_conflict <> 1 THEN RAISE EXCEPTION 'FAIL FACT_CONFLICT expected 1 got %', v_conflict; END IF;
  IF v_missing <> 1 THEN RAISE EXCEPTION 'FAIL CLIENT_DATA_REQUIRED expected 1 got %', v_missing; END IF;
  IF v_synth <> 1 THEN RAISE EXCEPTION 'FAIL SYNTHETIC marker missing on client'; END IF;

  RAISE NOTICE 'PASS truth_intake: docs=% ents=% claims=% evidence=% verified=% draft=% conflict=% missing=% synth=%',
    v_docs, v_ents, v_claims, v_evidence, v_verified, v_draft, v_conflict, v_missing, v_synth;
END $$;

-- Idempotency: re-running the seed must not change claim/evidence counts.
SELECT 're-run seed then re-check counts' AS note;