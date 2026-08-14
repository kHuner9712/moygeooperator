-- ============================================================================
-- MOY GEO Operator · SYNTHETIC Shadow-Runtime E2E fixture (P0.17)
--
-- Dedicated tenants SHADOW-E2E-A / SHADOW-E2E-B for the full Shadow Runtime
-- E2E (WF-01..WF-08 + error path + tenant isolation). Intentionally separate
-- from the SYNTH-ACME vertical-slice seeds so the E2E never depends on them.
--
-- THIS DATA IS SYNTHETIC TEST FIXTURE ONLY. It references a fictional company
-- and MUST NOT be treated as, or exported as, a real business result. Every
-- E2E verification is idempotent (unique keys / ON CONFLICT) and safe to re-run.
--
-- A) Happy-path tenant (SHADOW-E2E-A): clean truth pack with VERIFIED structured
--    claims + an enabled LOCAL_OLLAMA observer adapter + target surfaces, so the
--    full chain can flow deterministically.
-- B) Adversarial isolation tenant (SHADOW-E2E-B): enough objects to prove every
--    cross-client reference fails closed with CROSS_CLIENT_REFERENCE.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

-- ---------------------------------------------------------------------------
-- Clients
-- ---------------------------------------------------------------------------
INSERT INTO clients(code, legal_name, display_name, status, primary_region,
                    primary_language, notes)
VALUES (
  'SHADOW-E2E-A',
  'Shadow E2E Manufacturing Co. (SYNTHETIC)',
  'Shadow E2E A (SYNTHETIC)',
  'ACTIVE',
  'CN',
  'zh-CN',
  E'SYNTHETIC Shadow-Runtime E2E happy-path tenant. Fictional company; not a real business result.'
)
ON CONFLICT (code) DO UPDATE SET status='ACTIVE', updated_at=now();

INSERT INTO clients(code, legal_name, display_name, status, primary_region,
                    primary_language, notes)
VALUES (
  'SHADOW-E2E-B',
  'Shadow E2E Isolation Co. (SYNTHETIC)',
  'Shadow E2E B (SYNTHETIC)',
  'ACTIVE',
  'us',
  'en',
  E'SYNTHETIC Shadow-Runtime E2E adversarial isolation tenant.'
)
ON CONFLICT (code) DO UPDATE SET status='ACTIVE', updated_at=now();

-- ---------------------------------------------------------------------------
-- WF-01 contract: import_truth_pack for SHADOW-E2E-A.
-- Clean pack: every claim binds to a document; structured low-risk fields are
-- rule-verified -> VERIFIED (so the WF-06 fact gate has grounded Truth).
-- ---------------------------------------------------------------------------
SELECT import_truth_pack(
  'SHADOW-E2E-A',

  -- Documents (truth pack raw material).
  '[
    {"import_key":"SHADOWE2E-A-2026-company-profile","document_type":"COMPANY_PROFILE","title":"Company Profile 2026 (SYNTHETIC)","source_uri":"synthetic://shadowe2e-a/company-profile","checksum":"sha256:synthetic-shadowa-profile","document_status":"PARSED"},
    {"import_key":"SHADOWE2E-A-2026-product-catalog","document_type":"PRODUCT_CATALOG","title":"Product Catalog 2026 (SYNTHETIC)","source_uri":"synthetic://shadowe2e-a/product-catalog","checksum":"sha256:synthetic-shadowa-catalog","document_status":"RECEIVED"},
    {"import_key":"SHADOWE2E-A-2026-iso9001","document_type":"CERTIFICATE","title":"ISO9001 Certificate (SYNTHETIC)","source_uri":"synthetic://shadowe2e-a/iso9001","checksum":"sha256:synthetic-shadowa-iso","document_status":"RECEIVED"}
  ]'::jsonb,

  -- Entities.
  '[
    {"entity_type":"ORGANIZATION","canonical_name":"Shadow E2E Manufacturing Co.","aliases":["ShadowE2E","Shadow E2E"]},
    {"entity_type":"BRAND","canonical_name":"ShadowE2E","aliases":[]},
    {"entity_type":"PRODUCT","canonical_name":"SE-100 Precision Cylinder","aliases":[]},
    {"entity_type":"LOCATION","canonical_name":"Shanghai Songjiang","aliases":[]},
    {"entity_type":"CERTIFICATE","canonical_name":"ISO9001:2015","aliases":[]}
  ]'::jsonb,

  -- Claims. Low-risk structured fields (legal_name/display_name/registration_region)
  -- are rule-verified -> VERIFIED. Product/certificate facts stay DRAFT (no conflict).
  '[
    {"import_key":"SHADOWE2E-A-C1","entity_type":"ORGANIZATION","entity_name":"Shadow E2E Manufacturing Co.","field_key":"legal_name","claim_text":"The legal name is Shadow E2E Manufacturing Co.","document_key":"SHADOWE2E-A-2026-company-profile","low_risk":true,"rule_verify":true},
    {"import_key":"SHADOWE2E-A-C2","entity_type":"ORGANIZATION","entity_name":"Shadow E2E Manufacturing Co.","field_key":"display_name","claim_text":"The brand display name is ShadowE2E","document_key":"SHADOWE2E-A-2026-company-profile","low_risk":true,"rule_verify":true},
    {"import_key":"SHADOWE2E-A-C3","entity_type":"ORGANIZATION","entity_name":"Shadow E2E Manufacturing Co.","field_key":"registration_region","claim_text":"The registration region is Shanghai Songjiang","document_key":"SHADOWE2E-A-2026-company-profile","low_risk":true,"rule_verify":true},
    {"import_key":"SHADOWE2E-A-C4","entity_type":"PRODUCT","entity_name":"SE-100 Precision Cylinder","field_key":"spec","claim_text":"SE-100 Precision Cylinder rated load is 500 kg","document_key":"SHADOWE2E-A-2026-product-catalog","low_risk":false,"rule_verify":false},
    {"import_key":"SHADOWE2E-A-C5","entity_type":"CERTIFICATE","entity_name":"ISO9001:2015","field_key":"validity","claim_text":"Holds ISO9001:2015 certification valid to 2027-06","document_key":"SHADOWE2E-A-2026-iso9001","low_risk":false,"rule_verify":false}
  ]'::jsonb
) AS shadow_e2e_a_import;

-- ---------------------------------------------------------------------------
-- WF-01 contract: import_truth_pack for SHADOW-E2E-B (isolation target).
-- ---------------------------------------------------------------------------
SELECT import_truth_pack(
  'SHADOW-E2E-B',
  '[
    {"import_key":"SHADOWE2E-B-2026-company-profile","document_type":"COMPANY_PROFILE","title":"Isolation Co. Profile (SYNTHETIC)","source_uri":"synthetic://shadowe2e-b/company-profile","checksum":"sha256:synthetic-shadowb-profile","document_status":"PARSED"}
  ]'::jsonb,
  '[
    {"entity_type":"ORGANIZATION","canonical_name":"Shadow E2E Isolation Co.","aliases":["IsolationB"]}
  ]'::jsonb,
  '[
    {"import_key":"SHADOWE2E-B-C1","entity_type":"ORGANIZATION","entity_name":"Shadow E2E Isolation Co.","field_key":"legal_name","claim_text":"The legal name is Shadow E2E Isolation Co.","document_key":"SHADOWE2E-B-2026-company-profile","low_risk":true,"rule_verify":true}
  ]'::jsonb
) AS shadow_e2e_b_import;

-- ---------------------------------------------------------------------------
-- WF-04 contract: observer engine + enabled LOCAL_OLLAMA adapter for A.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_eng uuid;
BEGIN
  SELECT upsert_engine('LOCAL_OLLAMA','qwen2.5','chat','CN','zh-CN',true,
    jsonb_build_object('model','qwen2.5:0.5b','url',COALESCE(current_setting('app.ollama_url',true),'http://ollama:11434')))
    INTO v_eng;
  PERFORM register_engine_adapter(v_eng, 'LOCAL_OLLAMA', true, '1.0.0', 'READY');

  -- A second engine with NO enabled adapter: WF-04 must fail closed (UNSUPPORTED).
  SELECT upsert_engine('FAKE-CLOUD','no-adapter','chat','us','en',true) INTO v_eng;
END $$;

-- ---------------------------------------------------------------------------
-- WF-02 contract: target surfaces for A (publication closure targets).
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM upsert_surface('SHADOW-E2E-A', 'WEBSITE', 'OFFICIAL_SITE',
    NULL, 'https://shadowe2e-a.example', 'Shadow E2E Manufacturing Co.',
    'MANUAL_REQUIRED', NULL, 'SHADOWE2E-A-SURF-WEB');
  PERFORM upsert_surface('SHADOW-E2E-A', 'B2B_LISTING', 'ALIBABA_1688',
    NULL, 'https://shadowe2e-a.example/1688', 'Shadow E2E Manufacturing Co.',
    'MANUAL_REQUIRED', NULL, 'SHADOWE2E-A-SURF-1688');

  -- Isolation tenant B surface (any cross-client ref to it must fail closed).
  PERFORM upsert_surface('SHADOW-E2E-B', 'WEBSITE', 'OFFICIAL_SITE',
    NULL, 'https://shadowe2e-b.example', 'Shadow E2E Isolation Co.',
    'MANUAL_REQUIRED', NULL, 'SHADOWE2E-B-SURF-WEB');
END $$;

COMMIT;