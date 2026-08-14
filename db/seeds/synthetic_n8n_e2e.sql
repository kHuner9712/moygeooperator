-- ============================================================================
-- MOY GEO Operator · SYNTHETIC True N8N Full-Chain E2E fixture (P0.18)
--
-- Dedicated tenants N8N-E2E-A / N8N-E2E-B for the TRUE N8N Full-Chain gate
-- (scripts/e2e/true-n8n-shadow-runtime.sh). The ONLY thing this seed may
-- create is SYSTEM CONFIGURATION:
--   * clients
--   * engine registry / adapter configuration (LOCAL_OLLAMA + TEST_HTTP_FAIL)
--
-- It MUST NOT create any business-chain result:
--   entities / claims / VERIFIED claims / surfaces / intents / queries /
--   observations / gaps / actions / content assets / publication tasks /
--   reports  ==  all zero until the n8n workflows run for real.
--
-- WF-01 produces the FIRST entity/claim/evidence for N8N-E2E-A from a real
-- PDF -> truth-extractor -> Ollama -> import_truth_pack path.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

-- ---------------------------------------------------------------------------
-- Clients
-- ---------------------------------------------------------------------------
INSERT INTO clients(code, legal_name, display_name, status, primary_region,
                    primary_language, notes)
VALUES (
  'N8N-E2E-A',
  'Shadow E2E Manufacturing Co. (SYNTHETIC)',
  'N8N E2E A (SYNTHETIC)',
  'ACTIVE',
  'CN',
  'zh-CN',
  E'SYNTHETIC True-N8N Full-Chain happy-path tenant. Fictional company; not a real business result. Zero business-chain rows until the n8n workflows run.'
)
ON CONFLICT (code) DO UPDATE SET status='ACTIVE', updated_at=now();

INSERT INTO clients(code, legal_name, display_name, status, primary_region,
                    primary_language, notes)
VALUES (
  'N8N-E2E-B',
  'Shadow E2E Isolation Co. (SYNTHETIC)',
  'N8N E2E B (SYNTHETIC)',
  'ACTIVE',
  'us',
  'en',
  E'SYNTHETIC True-N8N Full-Chain adversarial isolation tenant. Only used for the cross-client WF-07 runtime attack fixture.'
)
ON CONFLICT (code) DO UPDATE SET status='ACTIVE', updated_at=now();

-- ---------------------------------------------------------------------------
-- Engine registry + adapters (system config, allowed)
--   LOCAL_OLLAMA  : enabled + enabled LOCAL_OLLAMA adapter  -> happy-path WF-04
--   TEST_HTTP_FAIL: DISABLED by default. The E2E driver enables it (engine +
--                   adapter) only for the WF-99 fault-injection window, so it
--                   never pollutes the happy-path observation queue.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_eng uuid;
BEGIN
  SELECT upsert_engine('LOCAL_OLLAMA','qwen2.5','chat','CN','zh-CN',true,
    jsonb_build_object('model','qwen2.5:3b','url',COALESCE(current_setting('app.ollama_url',true),'http://ollama:11434')))
    INTO v_eng;
  PERFORM register_engine_adapter(v_eng, 'LOCAL_OLLAMA', true, '1.0.0', 'READY');

  SELECT upsert_engine('TEST_HTTP_FAIL','mock-fail','chat','CN','zh-CN',false,
    jsonb_build_object('url',COALESCE(current_setting('app.test_fail_url',true),'http://mock-engine:8010/fail')))
    INTO v_eng;
  PERFORM register_engine_adapter(v_eng, 'TEST_HTTP_FAIL', false, '0.0.1', 'UNSUPPORTED');
END $$;

COMMIT;
