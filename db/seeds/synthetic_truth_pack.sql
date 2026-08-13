-- ============================================================================
-- Stage 2 · SYNTHETIC Truth Pack — WF-01 vertical slice.
-- THIS DATA IS SYNTHETIC. It uses a fictional company ("合成测试精密工业有限公司")
-- and is explicitly marked SYNTHETIC; it must NOT be treated as, or exported as,
-- a real business result. Idempotent: safe to re-run.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO clients(code, legal_name, display_name, status, primary_region, primary_language, notes)
VALUES (
  'SYNTH-ACME',
  '合成测试精密工业有限公司 (SYNTHETIC)',
  'AcmePrecision 合成测试客户',
  'ONBOARDING',
  'CN',
  'zh-CN',
  E'SYNTHETIC 测试数据 — 仅用于 Stage 2 / WF-01 垂直切片验证。虚构企业，不代表任何真实企业或业务结果。'
)
ON CONFLICT (code) DO UPDATE SET updated_at = now();

SELECT import_truth_pack(
  'SYNTH-ACME',

  -- Documents (Truth Pack raw material)
  '[
    {"import_key":"SYNTH-ACME-2026-company-profile","document_type":"COMPANY_PROFILE","title":"Company Profile 2026 (SYNTHETIC)","source_uri":"synthetic://acme/company-profile","checksum":"sha256:synthetic-company-profile","document_status":"RECEIVED"},
    {"import_key":"SYNTH-ACME-2026-product-catalog","document_type":"PRODUCT_CATALOG","title":"Product Catalog 2026 (SYNTHETIC)","source_uri":"synthetic://acme/product-catalog","checksum":"sha256:synthetic-product-catalog","document_status":"RECEIVED"},
    {"import_key":"SYNTH-ACME-2026-iso9001","document_type":"CERTIFICATE","title":"ISO9001 Certificate (SYNTHETIC)","source_uri":"synthetic://acme/iso9001","checksum":"sha256:synthetic-iso9001","document_status":"RECEIVED"},
    {"import_key":"SYNTH-ACME-2026-press-release","document_type":"PRESS_RELEASE","title":"Press Release 2026 (SYNTHETIC)","source_uri":"synthetic://acme/press-release","checksum":"sha256:synthetic-press-release","document_status":"RECEIVED"}
  ]'::jsonb,

  -- Entities
  '[
    {"entity_type":"ORGANIZATION","canonical_name":"合成测试精密工业有限公司","aliases":["AcmePrecision","Acme 精密"]},
    {"entity_type":"BRAND","canonical_name":"AcmePrecision","aliases":[]},
    {"entity_type":"PRODUCT","canonical_name":"AC-100 精密气缸","aliases":[]},
    {"entity_type":"PRODUCT","canonical_name":"AC-200 伺服模组","aliases":[]},
    {"entity_type":"LOCATION","canonical_name":"上海市松江区","aliases":[]},
    {"entity_type":"CERTIFICATE","canonical_name":"ISO9001:2015","aliases":[]}
  ]'::jsonb,

  -- Claims. Low-risk structured fields (legal_name/display_name/registration_region)
  -- are rule-verified. founded_year has TWO sources (2008 vs 2010) -> FACT_CONFLICT.
  -- factory_size has NO source document -> CLIENT_DATA_REQUIRED (fail-closed).
  '[
    {"import_key":"SYNTH-ACME-C1","entity_type":"ORGANIZATION","entity_name":"合成测试精密工业有限公司","field_key":"legal_name","claim_text":"公司法定名称为 合成测试精密工业有限公司","document_key":"SYNTH-ACME-2026-company-profile","low_risk":true,"rule_verify":true},
    {"import_key":"SYNTH-ACME-C2","entity_type":"ORGANIZATION","entity_name":"合成测试精密工业有限公司","field_key":"display_name","claim_text":"品牌展示名为 AcmePrecision","document_key":"SYNTH-ACME-2026-company-profile","low_risk":true,"rule_verify":true},
    {"import_key":"SYNTH-ACME-C3","entity_type":"ORGANIZATION","entity_name":"合成测试精密工业有限公司","field_key":"registration_region","claim_text":"注册地区为上海市松江区","document_key":"SYNTH-ACME-2026-company-profile","low_risk":true,"rule_verify":true},
    {"import_key":"SYNTH-ACME-C4","entity_type":"ORGANIZATION","entity_name":"合成测试精密工业有限公司","field_key":"founded_year","claim_text":"公司成立于 2008 年","normalized_value":"2008","document_key":"SYNTH-ACME-2026-company-profile","low_risk":true,"rule_verify":true},
    {"import_key":"SYNTH-ACME-C5","entity_type":"ORGANIZATION","entity_name":"合成测试精密工业有限公司","field_key":"founded_year","claim_text":"公司成立于 2010 年","normalized_value":"2010","document_key":"SYNTH-ACME-2026-press-release","low_risk":true,"rule_verify":false},
    {"import_key":"SYNTH-ACME-C6","entity_type":"PRODUCT","entity_name":"AC-100 精密气缸","field_key":"spec","claim_text":"AC-100 额定负载 500kg","document_key":"SYNTH-ACME-2026-product-catalog","low_risk":false,"rule_verify":false},
    {"import_key":"SYNTH-ACME-C7","entity_type":"PRODUCT","entity_name":"AC-200 伺服模组","field_key":"spec","claim_text":"AC-200 伺服模组 行程 800mm","document_key":"SYNTH-ACME-2026-product-catalog","low_risk":false,"rule_verify":false},
    {"import_key":"SYNTH-ACME-C8","entity_type":"CERTIFICATE","entity_name":"ISO9001:2015","field_key":"validity","claim_text":"持有 ISO9001:2015 认证，有效期至 2027-06","document_key":"SYNTH-ACME-2026-iso9001","low_risk":false,"rule_verify":false},
    {"import_key":"SYNTH-ACME-C9","entity_type":"ORGANIZATION","entity_name":"合成测试精密工业有限公司","field_key":"lead_time","claim_text":"标准交期 7-15 天","document_key":"SYNTH-ACME-2026-product-catalog","low_risk":false,"rule_verify":false},
    {"import_key":"SYNTH-ACME-C10","entity_type":"ORGANIZATION","entity_name":"合成测试精密工业有限公司","field_key":"factory_size","claim_text":"厂房面积 20000 平方米","document_key":null,"low_risk":false,"rule_verify":false}
  ]'::jsonb
) AS import_summary;

COMMIT;