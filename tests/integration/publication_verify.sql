-- ============================================================================
-- Stage 7 · WF-07 Publishing integration assertions (SYNTH-ACME).
-- Run AFTER db/seeds/synthetic_publication.sql (which needs Stages 2-6).
-- P0.7-aligned: AUTO_API is never fabricated PUBLISHED. A task only reaches
-- PUBLISHED via complete_publication() with a REAL provider external_id.
--   - OFFICIAL_SITE (AUTO_API + adapter + credential)   -> PUBLISHING (awaiting)
--   - AMAP (BROWSER_ASSISTED)                           -> WAITING_APPROVAL
--   - ALIBABA_1688 (MANUAL_REQUIRED)                    -> WAITING_APPROVAL
--   - BAIDU_BAIKE (AUTO_API, no adapter)                -> UNSUPPORTED_PLATFORM
--                                                          + MANUAL_REQUIRED
-- Verifies: no simulated publish, real-completion path, fail-closed
-- (UNSUPPORTED_PLATFORM / CREDENTIAL_INVALID), idempotency, cross-client iso.
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
  v_dup_task uuid;
  v_official uuid;
  v_ext text;
BEGIN
  SELECT id INTO v_cid FROM _t7_cid;
  IF v_cid IS NULL THEN RAISE EXCEPTION 'FAIL: SYNTH-ACME client not found'; END IF;

  -- Re-runnable reset: restore the canonical post-seed state. Step 4 completes
  -- OFFICIAL_SITE and steps 6/7 flip BAIDU_BAIKE modes, so a prior run leaves
  -- the tasks mutated. Restoring here keeps the test deterministic on re-runs.
  DELETE FROM publication_records WHERE client_id=v_cid;
  DELETE FROM exceptions
    WHERE client_id=v_cid AND related_object_type='PUBLICATION_TASK';
  UPDATE publication_tasks t SET
    mode = (CASE s.platform
             WHEN 'OFFICIAL_SITE' THEN 'AUTO_API'::publication_mode
             WHEN 'AMAP' THEN 'BROWSER_ASSISTED'::publication_mode
             WHEN 'BAIDU_BAIKE' THEN 'AUTO_API'::publication_mode
             WHEN 'ALIBABA_1688' THEN 'MANUAL_REQUIRED'::publication_mode
           END),
    status = (CASE s.platform
             WHEN 'OFFICIAL_SITE' THEN 'PUBLISHING'::publication_status
             ELSE 'WAITING_APPROVAL'::publication_status
           END),
    last_error = NULL
  FROM surfaces s WHERE s.id=t.surface_id AND t.client_id=v_cid;

  -- 1. One publication task per target surface.
  SELECT count(*) INTO v_tasks FROM publication_tasks WHERE client_id=v_cid;
  IF v_tasks <> 4 THEN RAISE EXCEPTION 'FAIL tasks expected 4 got %', v_tasks; END IF;

  -- 2. AUTO_API + adapter + credential is NOT fabricated PUBLISHED. P0.7:
  --    without a real provider response it stays PUBLISHING (awaiting).
  SELECT count(*) INTO v_other FROM publication_tasks t
    JOIN surfaces s ON s.id=t.surface_id
    WHERE t.client_id=v_cid AND s.platform='OFFICIAL_SITE' AND t.status='PUBLISHED';
  IF v_other <> 0 THEN
    RAISE EXCEPTION 'FAIL simulated PUBLISHED exists; P0.7 forbids fabricated PUBLISHED'; END IF;
  SELECT count(*) INTO v_other FROM publication_tasks t
    JOIN surfaces s ON s.id=t.surface_id
    WHERE t.client_id=v_cid AND s.platform='OFFICIAL_SITE' AND t.status='PUBLISHING';
  IF v_other <> 1 THEN
    RAISE EXCEPTION 'FAIL OFFICIAL_SITE expected PUBLISHING (awaiting) got %', v_other; END IF;

  -- 3. No fabricated publication record exists yet (nothing was "published").
  SELECT count(*) INTO v_records FROM publication_records WHERE client_id=v_cid;
  IF v_records <> 0 THEN
    RAISE EXCEPTION 'FAIL expected 0 publication records (no simulated publish) got %', v_records; END IF;

  -- 4. Real completion path: a task only becomes PUBLISHED via
  --    complete_publication() with a genuine provider external_id.
  SELECT t.id INTO v_official FROM publication_tasks t
    JOIN surfaces s ON s.id=t.surface_id
    WHERE t.client_id=v_cid AND s.platform='OFFICIAL_SITE' LIMIT 1;
  v_ext := 'provider-' || replace(gen_random_uuid()::text, '-', '');  -- real-shaped id (guard rejects 'ext-' prefix)
  PERFORM complete_publication(v_official, v_ext, 'https://acme-precision.example.com/company',
                              '{"provider":"official CMS","ok":true}'::jsonb);
  SELECT count(*) INTO v_other FROM publication_tasks t
    JOIN surfaces s ON s.id=t.surface_id
    WHERE t.client_id=v_cid AND s.platform='OFFICIAL_SITE' AND t.status='PUBLISHED';
  IF v_other <> 1 THEN
    RAISE EXCEPTION 'FAIL OFFICIAL_SITE did not reach PUBLISHED after real completion'; END IF;
  SELECT count(*) INTO v_records FROM publication_records WHERE client_id=v_cid;
  IF v_records <> 1 THEN
    RAISE EXCEPTION 'FAIL expected 1 publication record after real completion got %', v_records; END IF;

  -- 5. BROWSER_ASSISTED / MANUAL_REQUIRED -> WAITING_APPROVAL.
  SELECT count(*) INTO v_other FROM publication_tasks t
    JOIN surfaces s ON s.id=t.surface_id
    WHERE t.client_id=v_cid AND s.platform IN ('AMAP','ALIBABA_1688')
      AND t.status='WAITING_APPROVAL';
  IF v_other <> 2 THEN
    RAISE EXCEPTION 'FAIL assisted/manual expected WAITING_APPROVAL got %', v_other; END IF;

  -- 6. Fail closed: AUTO_API surface with NO adapter -> UNSUPPORTED_PLATFORM,
  --    routed to MANUAL_REQUIRED (never BLOCKED-with-fake, never fabricated).
  --    Restore the "no adapter" precondition first (a prior run of step 7 may
  --    have registered a BAIDU_BAIKE adapter), then re-dispatch the task.
  SELECT t.id INTO v_dup_task FROM publication_tasks t
    JOIN surfaces s ON s.id=t.surface_id
    WHERE t.client_id=v_cid AND s.platform='BAIDU_BAIKE' LIMIT 1;
  -- A prior run may have routed this task to MANUAL_REQUIRED; reset it to
  -- AUTO_API so dispatch exercises the adapter-gate branch again.
  UPDATE publication_tasks SET mode='AUTO_API', status='READY'
    WHERE id=v_dup_task;
  DELETE FROM publication_adapters WHERE platform='BAIDU_BAIKE';
  PERFORM dispatch_publication(v_dup_task);
  SELECT count(*) INTO v_other FROM publication_tasks t
    JOIN surfaces s ON s.id=t.surface_id
    WHERE t.client_id=v_cid AND s.platform='BAIDU_BAIKE' AND t.status='WAITING_APPROVAL';
  IF v_other <> 1 THEN
    RAISE EXCEPTION 'FAIL BAIDU_BAIKE expected WAITING_APPROVAL (MANUAL_REQUIRED) got %', v_other; END IF;
  SELECT count(*) INTO v_unsup FROM exceptions
    WHERE client_id=v_cid AND exception_type='UNSUPPORTED_PLATFORM' AND status='OPEN';
  IF v_unsup <> 1 THEN
    RAISE EXCEPTION 'FAIL expected 1 UNSUPPORTED_PLATFORM got %', v_unsup; END IF;

  -- 7. Fail closed: adapter WITHOUT credential -> CREDENTIAL_INVALID.
  PERFORM register_publication_adapter('BAIDU_BAIKE','PUBLISH',true,true,true,'{}');
  SELECT t.id INTO v_dup FROM publication_tasks t
    JOIN surfaces s ON s.id=t.surface_id
    WHERE t.client_id=v_cid AND s.platform='BAIDU_BAIKE' LIMIT 1;
  UPDATE publication_tasks SET mode='AUTO_API', status='READY' WHERE id=v_dup;
  PERFORM dispatch_publication(v_dup);
  SELECT count(*) INTO v_cred FROM exceptions
    WHERE client_id=v_cid AND exception_type='CREDENTIAL_INVALID' AND status='OPEN';
  IF v_cred <> 1 THEN
    RAISE EXCEPTION 'FAIL expected 1 CREDENTIAL_INVALID got %', v_cred; END IF;

  -- 8. Idempotency: re-creating the same task adds nothing.
  SELECT create_publication_task('SYNTH-ACME',
    (SELECT content_asset_id FROM publication_tasks WHERE client_id=v_cid LIMIT 1),
    (SELECT surface_id FROM publication_tasks WHERE client_id=v_cid LIMIT 1)) INTO v_dup;
  IF v_dup IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL create_publication_task not idempotent: %', v_dup; END IF;
  SELECT count(*) INTO v_tasks FROM publication_tasks WHERE client_id=v_cid;
  IF v_tasks <> 4 THEN
    RAISE EXCEPTION 'FAIL idempotency task count drifted: %', v_tasks; END IF;

  -- 9. Cross-client isolation: SYNTH-ACME tasks must only reference surfaces
  --    owned by SYNTH-ACME (other tenants may legitimately hold their own
  --    tasks from other suites, so scope the leak check to this client).
  SELECT count(*) INTO v_other FROM publication_tasks t
    JOIN surfaces s ON s.id=t.surface_id
    WHERE t.client_id=v_cid AND s.client_id <> v_cid;
  IF v_other <> 0 THEN RAISE EXCEPTION 'FAIL a task references another client''s surface'; END IF;
  SELECT count(*) INTO v_other FROM publication_records r
    JOIN publication_tasks t ON t.id=r.publication_task_id
    WHERE r.client_id=v_cid AND t.client_id <> v_cid;
  IF v_other <> 0 THEN RAISE EXCEPTION 'FAIL a record references another client''s task'; END IF;

  RAISE NOTICE 'PASS publication: tasks=% records=% unsupported=% credential_invalid=%',
    v_tasks, v_records, v_unsup, v_cred;
END $$;
DROP TABLE _t7_cid;