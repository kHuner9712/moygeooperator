-- ============================================================================
-- Stage 7 · WF-07 Publishing integration assertions (SYNTH-ACME).
-- Run AFTER db/seeds/synthetic_publication.sql (which needs Stages 2-6).
-- Verifies: mode-routed dispatch outcomes, publication record, fail-closed
-- (UNSUPPORTED_PLATFORM / CREDENTIAL_INVALID), idempotency, cross-client isolation.
-- ============================================================================
\set ON_ERROR_STOP on

SELECT id INTO TEMP TABLE _t7_cid FROM clients WHERE code='SYNTH-ACME';
DO $$
DECLARE
  v_cid uuid;
  v_rec int; v_tasks int; v_records int;
  v_other int;
  v_unsup int; v_cred int;
  v_dup uuid;
  v_task_ids uuid[];
BEGIN
  SELECT id INTO v_cid FROM _t7_cid;
  IF v_cid IS NULL THEN RAISE EXCEPTION 'FAIL: SYNTH-ACME client not found'; END IF;

  -- 1. One publication task per target surface.
  SELECT count(*) INTO v_tasks FROM publication_tasks WHERE client_id=v_cid;
  IF v_tasks <> 4 THEN RAISE EXCEPTION 'FAIL tasks expected 4 got %', v_tasks; END IF;

  -- 2. Mode-routed outcomes.
  -- AUTO_API with official adapter + credential -> PUBLISHED.
  SELECT count(*) INTO v_other FROM publication_tasks t
    JOIN surfaces s ON s.id=t.surface_id
    WHERE t.client_id=v_cid AND s.platform='OFFICIAL_SITE' AND t.status='PUBLISHED';
  IF v_other <> 1 THEN
    RAISE EXCEPTION 'FAIL OFFICIAL_SITE expected PUBLISHED got %', v_other; END IF;
  -- BROWSER_ASSISTED / MANUAL_REQUIRED -> WAITING_APPROVAL.
  SELECT count(*) INTO v_other FROM publication_tasks t
    JOIN surfaces s ON s.id=t.surface_id
    WHERE t.client_id=v_cid AND s.platform IN ('AMAP','ALIBABA_1688')
      AND t.status='WAITING_APPROVAL';
  IF v_other <> 2 THEN
    RAISE EXCEPTION 'FAIL assisted/manual expected WAITING_APPROVAL got %', v_other; END IF;

  -- 3. A publication record exists only for the AUTO_API publish.
  SELECT count(*) INTO v_records FROM publication_records WHERE client_id=v_cid;
  IF v_records <> 1 THEN
    RAISE EXCEPTION 'FAIL expected 1 publication record got %', v_records; END IF;

  -- 4. Fail closed: unsupported AUTO_API surface is BLOCKED with exception.
  SELECT count(*) INTO v_other FROM publication_tasks t
    JOIN surfaces s ON s.id=t.surface_id
    WHERE t.client_id=v_cid AND s.platform='BAIDU_BAIKE' AND t.status='BLOCKED';
  IF v_other <> 1 THEN
    RAISE EXCEPTION 'FAIL BAIDU_BAIKE expected BLOCKED got %', v_other; END IF;
  SELECT count(*) INTO v_unsup FROM exceptions
    WHERE client_id=v_cid AND exception_type='UNSUPPORTED_PLATFORM' AND status='OPEN';
  IF v_unsup <> 1 THEN
    RAISE EXCEPTION 'FAIL expected 1 UNSUPPORTED_PLATFORM got %', v_unsup; END IF;

  -- 5. Fail closed: official adapter WITHOUT credential -> CREDENTIAL_INVALID.
  PERFORM register_publication_adapter('BAIDU_BAIKE','PUBLISH',true,true,true,'{}');
  SELECT t.id INTO v_dup FROM publication_tasks t
    JOIN surfaces s ON s.id=t.surface_id
    WHERE t.client_id=v_cid AND s.platform='BAIDU_BAIKE' LIMIT 1;
  PERFORM dispatch_publication(v_dup);
  SELECT count(*) INTO v_cred FROM exceptions
    WHERE client_id=v_cid AND exception_type='CREDENTIAL_INVALID' AND status='OPEN';
  IF v_cred <> 1 THEN
    RAISE EXCEPTION 'FAIL expected 1 CREDENTIAL_INVALID got %', v_cred; END IF;

  -- 6. Idempotency: re-creating the same task adds nothing.
  SELECT create_publication_task('SYNTH-ACME',
    (SELECT content_asset_id FROM publication_tasks WHERE client_id=v_cid LIMIT 1),
    (SELECT surface_id FROM publication_tasks WHERE client_id=v_cid LIMIT 1)) INTO v_dup;
  IF v_dup IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL create_publication_task not idempotent: %', v_dup; END IF;
  SELECT count(*) INTO v_tasks FROM publication_tasks WHERE client_id=v_cid;
  IF v_tasks <> 4 THEN
    RAISE EXCEPTION 'FAIL idempotency task count drifted: %', v_tasks; END IF;

  -- 7. Cross-client isolation.
  SELECT count(*) INTO v_other FROM publication_tasks WHERE client_id IS DISTINCT FROM v_cid;
  IF v_other <> 0 THEN RAISE EXCEPTION 'FAIL a task leaked to another client'; END IF;
  SELECT count(*) INTO v_other FROM publication_records WHERE client_id IS DISTINCT FROM v_cid;
  IF v_other <> 0 THEN RAISE EXCEPTION 'FAIL a record leaked to another client'; END IF;

  RAISE NOTICE 'PASS publication: tasks=% records=% unsupported=% credential_invalid=%',
    v_tasks, v_records, v_unsup, v_cred;
END $$;
DROP TABLE _t7_cid;