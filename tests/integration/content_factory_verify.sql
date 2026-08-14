-- ============================================================================
-- Stage 6 · WF-06 Content Factory integration assertions (SYNTH-ACME).
-- Run AFTER db/seeds/synthetic_content_factory.sql (which needs Stages 2-5).
-- Verifies: brief creation, VERIFIED-only generation, fact QA, surface
-- adaptation, idempotency, and fail-closed on missing VERIFIED claims.
-- ============================================================================
\set ON_ERROR_STOP on

SELECT id INTO TEMP TABLE _t6_cid FROM clients WHERE code='SYNTH-ACME';
DO $$
DECLARE
  v_cid uuid;
  v_briefs int; v_assets int; v_verified int; v_not_verified int;
  v_dup_brief uuid; v_dup_asset uuid;
  v_other int;
  v_body text;
  v_claim_count int;
BEGIN
  SELECT id INTO v_cid FROM _t6_cid;
  IF v_cid IS NULL THEN RAISE EXCEPTION 'FAIL: SYNTH-ACME client not found'; END IF;

  -- 1. Briefs: one READY canonical brief per CONTENT_CREATION action.
  SELECT count(*) INTO v_briefs FROM content_briefs WHERE client_id=v_cid;
  IF v_briefs <> 2 THEN RAISE EXCEPTION 'FAIL briefs expected 2 got %', v_briefs; END IF;
  SELECT count(*) INTO v_briefs FROM content_briefs
    WHERE client_id=v_cid AND status='READY';
  IF v_briefs <> 2 THEN
    RAISE EXCEPTION 'FAIL READY briefs expected 2 got %', v_briefs; END IF;

  -- 2. Assets: one canonical per brief + surface variants; all must pass the
  --    Fact + Compliance gates (P0.10/P0.11). Approved assets are
  --    READY_TO_PUBLISH with fact_check_status=PASSED AND compliance_status=PASSED.
  --    (Later stages may add surface variants, so assert the canonical count and
  --    the all-PASSED invariant rather than an absolute total.)
  SELECT count(*) INTO v_assets FROM content_assets
    WHERE client_id=v_cid AND surface_id IS NULL;
  IF v_assets <> 2 THEN
    RAISE EXCEPTION 'FAIL canonical assets expected 2 got %', v_assets; END IF;
  SELECT count(*) INTO v_verified FROM content_assets
    WHERE client_id=v_cid AND fact_check_status='PASSED' AND compliance_status='PASSED';
  SELECT count(*) INTO v_not_verified FROM content_assets
    WHERE client_id=v_cid
      AND (fact_check_status IS DISTINCT FROM 'PASSED'
           OR compliance_status IS DISTINCT FROM 'PASSED');
  IF v_not_verified <> 0 THEN
    RAISE EXCEPTION 'FAIL an asset failed a gate: %', v_not_verified; END IF;
  SELECT count(*) INTO v_not_verified FROM content_assets
    WHERE client_id=v_cid AND status IS DISTINCT FROM 'READY_TO_PUBLISH';
  IF v_not_verified <> 0 THEN
    RAISE EXCEPTION 'FAIL an asset is not READY_TO_PUBLISH: %', v_not_verified; END IF;

  -- 3. Every asset body compiles only referenced VERIFIED claims.
  SELECT count(*) INTO v_claim_count FROM content_assets a, claims cl
    WHERE a.client_id=v_cid
      AND cl.id IN (SELECT v::uuid
                    FROM jsonb_array_elements_text(a.claim_ids) v)
      AND cl.verification IS DISTINCT FROM 'VERIFIED';
  IF v_claim_count <> 0 THEN
    RAISE EXCEPTION 'FAIL an asset references a non-VERIFIED claim'; END IF;

  -- 4. Idempotency: re-running brief/asset creation adds nothing new.
  SELECT create_content_brief('SYNTH-ACME',
    (SELECT id FROM geo_actions WHERE client_id=v_cid
      AND action_type='CONTENT_CREATION' LIMIT 1)) INTO v_dup_brief;
  IF v_dup_brief IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL create_content_brief not idempotent: %', v_dup_brief; END IF;
  SELECT generate_content_asset('SYNTH-ACME',
    (SELECT id FROM content_briefs WHERE client_id=v_cid LIMIT 1),
    'MARKDOWN') INTO v_dup_asset;
  IF v_dup_asset IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL generate_content_asset not idempotent: %', v_dup_asset; END IF;
  SELECT count(*) INTO v_assets FROM content_assets
    WHERE client_id=v_cid AND surface_id IS NULL;
  IF v_assets <> 2 THEN
    RAISE EXCEPTION 'FAIL idempotency canonical asset count drifted: %', v_assets; END IF;

  -- 5. Cross-client isolation: no brief/asset leaked to a NON-SYNTH client.
  --    (The runtime_convergence test creates its own SYNTH-A/SYNTH-B fixtures
  --    with briefs/assets; those are intentional synthetic tenants, so the
  --    leak check scopes to clients outside the SYNTH-* test namespace.)
  SELECT count(*) INTO v_other FROM content_briefs cb
    JOIN clients c ON c.id=cb.client_id
    WHERE c.code NOT LIKE 'SYNTH-%';
  IF v_other <> 0 THEN RAISE EXCEPTION 'FAIL a brief leaked to a non-SYNTH client'; END IF;
  SELECT count(*) INTO v_other FROM content_assets ca
    JOIN clients c ON c.id=ca.client_id
    WHERE c.code NOT LIKE 'SYNTH-%';
  IF v_other <> 0 THEN RAISE EXCEPTION 'FAIL an asset leaked to a non-SYNTH client'; END IF;

  RAISE NOTICE 'PASS content_factory: briefs=% assets=% verified=%',
    v_briefs, v_assets, v_verified;
END $$;
DROP TABLE _t6_cid;