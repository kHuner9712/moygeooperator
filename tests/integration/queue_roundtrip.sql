-- ============================================================================
-- Integration test: jobs/exceptions queue round-trip (Stage 1 infra).
-- Validates: enqueue idempotency, atomic claim (lease), retry-to-fail
-- exhaustion, and open-exception dedup. Run against geo_operator DB.
--   docker compose exec -T -e PGUSER=geo_operator -e PGPASSWORD=... \
--     postgres psql -d geo_operator -v ON_ERROR_STOP=1 -f /srv/tests/integration/queue_roundtrip.sql
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

-- fixture client (unique code so the test is re-runnable)
INSERT INTO clients(code, legal_name, display_name)
VALUES ('TESTQBC' || to_char(now(),'HH24MISSMS'), 'Test Queue Client', 'Test Queue')
RETURNING id AS cid \gset

-- 1) enqueue idempotency: same unique_key -> same job id
SELECT enqueue_job(:'cid'::uuid,'test_job','{"x":1}'::jsonb,50,now(),3,'test-key-abc') AS job1 \gset
SELECT enqueue_job(:'cid'::uuid,'test_job','{"x":1}'::jsonb,50,now(),3,'test-key-abc') AS job2 \gset
SELECT CASE
  WHEN :'job1' = :'job2' THEN 'PASS enqueue_idempotent'
  ELSE 'FAIL enqueue_idempotent'
END AS check_idempotent;

-- helper: force a job back due so it can be claimed again
\set make_due 'UPDATE jobs SET due_at = now() - interval ''1 minute'' WHERE id = '

-- 2) atomic claim: returns the job as RUNNING with attempts=1 + a lease
CREATE TEMP TABLE _claim AS SELECT * FROM claim_next_job('test-worker', 600);
SELECT CASE
  WHEN (SELECT status FROM _claim)='RUNNING'
   AND (SELECT attempts FROM _claim)=1
   AND (SELECT lease_until FROM _claim) IS NOT NULL
  THEN 'PASS claim_lease' ELSE 'FAIL claim_lease'
END AS check_claim;

-- 3) retry exhaustion: with max_attempts=3, two fails -> RETRY_WAIT, third -> FAILED
SELECT fail_job((SELECT id FROM _claim), 'boom 1') AS s1 \gset
SELECT CASE WHEN :'s1'='RETRY_WAIT' THEN 'PASS retry_wait_1' ELSE 'FAIL retry_wait_1 ('||:'s1'||')' END;
:make_due (SELECT id FROM _claim);
CREATE TEMP TABLE _c2 AS SELECT * FROM claim_next_job('test-worker', 600);
SELECT CASE WHEN (SELECT status FROM _c2)='RUNNING' AND (SELECT attempts FROM _c2)=2
  THEN 'PASS claim_retry_2' ELSE 'FAIL claim_retry_2' END;
SELECT fail_job((SELECT id FROM _c2), 'boom 2') AS s2 \gset
SELECT CASE WHEN :'s2'='RETRY_WAIT' THEN 'PASS retry_wait_2' ELSE 'FAIL retry_wait_2 ('||:'s2'||')' END;
:make_due (SELECT id FROM _c2);
CREATE TEMP TABLE _c3 AS SELECT * FROM claim_next_job('test-worker', 600);
SELECT CASE WHEN (SELECT status FROM _c3)='RUNNING' AND (SELECT attempts FROM _c3)=3
  THEN 'PASS claim_retry_3' ELSE 'FAIL claim_retry_3' END;
SELECT fail_job((SELECT id FROM _c3), 'boom 3') AS s3 \gset
SELECT CASE WHEN :'s3'='FAILED' THEN 'PASS fail_exhausted' ELSE 'FAIL fail_exhausted ('||:'s3'||')' END;

-- 4) open-exception dedup: second raise on same object is blocked by unique index
CREATE TEMP TABLE _test_cid(cid uuid);
INSERT INTO _test_cid SELECT :'cid'::uuid;
DO $$
DECLARE v_cid uuid; v_count int;
BEGIN
  SELECT cid INTO v_cid FROM _test_cid;
  BEGIN
    PERFORM raise_exception(v_cid, 'FACT_CONFLICT', 'HIGH', 'first', 'd',
      NULL, 'TestObj', 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee');
    RAISE NOTICE 'first raise ok';
  END;
  BEGIN
    PERFORM raise_exception(v_cid, 'FACT_CONFLICT', 'HIGH', 'dup', 'd',
      NULL, 'TestObj', 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee');
    RAISE NOTICE 'FAIL exception_dedup: duplicate insert not blocked';
  EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'PASS exception_dedup: duplicate blocked by partial unique index';
  END;
  SELECT count(*) INTO v_count FROM exceptions
    WHERE related_object_id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' AND status='OPEN';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'exception_dedup count expected 1 got %', v_count;
  END IF;
  RAISE NOTICE 'PASS exception_dedup: open count = %', v_count;
END $$;

ROLLBACK;
SELECT 'queue_roundtrip integration test complete (rolled back).' AS done;