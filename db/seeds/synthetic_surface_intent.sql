-- ============================================================================
-- Stage 3 · SYNTHETIC Surface + Intent — WF-02/WF-03 vertical slice.
-- THIS DATA IS SYNTHETIC. Uses the fictional "合成测试精密工业有限公司" company
-- and synthetic URLs (example.com/example.org). Never treat as, or export as,
-- a real business result. Idempotent: safe to re-run.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

-- ---------------------------------------------------------------------------
-- WF-02 · Surface discovery (upsert idempotent by import_key / client+url)
-- ---------------------------------------------------------------------------
SELECT upsert_surface('SYNTH-ACME','WEBSITE','OFFICIAL_SITE',
  'https://acme-precision.example.com/',
  'https://acme-precision.example.com/',
  '合成测试精密工业有限公司','MANUAL_REQUIRED',NULL,'SYNTH-ACME-SURF-WEBSITE') AS surf_website;

SELECT upsert_surface('SYNTH-ACME','KNOWLEDGE_PAGE','BAIDU_BAIKE',
  NULL,
  'https://baike.example.org/acme-precision',
  'AcmePrecision','MANUAL_REQUIRED',NULL,'SYNTH-ACME-SURF-BAIKE') AS surf_baike;

SELECT upsert_surface('SYNTH-ACME','MAP_POI','AMAP',
  'AcmePrecision 上海松江',
  'https://ditu.example.com/poi/12345',
  '合成测试精密工业有限公司','MANUAL_REQUIRED',NULL,'SYNTH-ACME-SURF-MAP') AS surf_map;

SELECT upsert_surface('SYNTH-ACME','MARKETPLACE_LISTING','ALIBABA_1688',
  'AcmePrecision 官方店',
  'https://1688.example.com/acme',
  'AcmePrecision','MANUAL_REQUIRED',NULL,'SYNTH-ACME-SURF-1688') AS surf_1688;

SELECT upsert_surface('SYNTH-ACME','FORUM','ZHIHU',
  NULL,
  'https://zhihu.example.org/question/98765',
  NULL,'MANUAL_REQUIRED',NULL,'SYNTH-ACME-SURF-ZHIHU') AS surf_zhihu;

-- Resources under each surface.
SELECT upsert_surface_resource('SYNTH-ACME','SYNTH-ACME-SURF-WEBSITE','HOME_PAGE',
  'https://acme-precision.example.com/','home','AcmePrecision 官网 (SYNTHETIC)',
  NULL,'合成测试精密工业有限公司 — 精密气缸与伺服模组制造商。','SYNTH-ACME-RES-WEBSITE-HOME') AS res_website;

SELECT upsert_surface_resource('SYNTH-ACME','SYNTH-ACME-SURF-BAIKE','KNOWLEDGE_ENTRY',
  'https://baike.example.org/acme-precision','acme-precision','AcmePrecision (SYNTHETIC) 百科词条',
  NULL,'AcmePrecision 是一家精密工业零部件制造商，注册地区为上海市松江区。','SYNTH-ACME-RES-BAIKE-PAGE') AS res_baike;

SELECT upsert_surface_resource('SYNTH-ACME','SYNTH-ACME-SURF-MAP','POI_DETAIL',
  'https://ditu.example.com/poi/12345','12345','AcmePrecision 上海松江 (SYNTHETIC)',
  NULL,'上海市松江区 精密气缸 制造商','SYNTH-ACME-RES-MAP-POI') AS res_map;

SELECT upsert_surface_resource('SYNTH-ACME','SYNTH-ACME-SURF-1688','STORE_LISTING',
  'https://1688.example.com/acme','acme-store','AcmePrecision 1688 店铺 (SYNTHETIC)',
  NULL,'AC-100 精密气缸 额定负载 500kg','SYNTH-ACME-RES-1688-STORE') AS res_1688;

SELECT upsert_surface_resource('SYNTH-ACME','SYNTH-ACME-SURF-ZHIHU','QA_PAGE',
  'https://zhihu.example.org/question/98765','98765','精密气缸 供应商推荐 (SYNTHETIC)',
  NULL,'哪个品牌精密气缸质量好？','SYNTH-ACME-RES-ZHIHU-QA') AS res_zhihu;

-- Public evidence (idempotent by import_key).
SELECT record_public_evidence('SYNTH-ACME','SYNTH-ACME-RES-BAIKE-PAGE','public_legal_name',
  'AcmePrecision 是一家精密工业零部件制造商，注册地区为上海市松江区。',
  0.9,'SYNTH-ACME-EVID-BAIKE-1') AS evid_baike;

SELECT record_public_evidence('SYNTH-ACME','SYNTH-ACME-RES-1688-STORE','public_product_spec',
  'AC-100 精密气缸 额定负载 500kg',0.9,'SYNTH-ACME-EVID-1688-1') AS evid_1688;

-- ---------------------------------------------------------------------------
-- WF-03 · Intent + Query generation (idempotent by client+label / intent+text)
-- Categories: PRODUCT / PURCHASE / COMPARE / AFTER_SALES / TRUST
-- ---------------------------------------------------------------------------
SELECT register_intent_with_queries(
  'SYNTH-ACME','AC-100 精密气缸','PRODUCT','AC-100 精密气缸产品查询',
  '买家查询 AC-100 参数、规格与用途。',90,80,70,
  '[
    {"query_text":"AC-100 精密气缸 参数","language":"zh-CN","region":"CN","priority":90},
    {"query_text":"精密气缸 AC-100 规格 负载","language":"zh-CN","region":"CN","priority":80},
    {"query_text":"AC-100 pneumatic cylinder specs","language":"en-US","region":"US","priority":60}
  ]'::jsonb) AS intent_product;

SELECT register_intent_with_queries(
  'SYNTH-ACME','合成测试精密工业有限公司','PURCHASE','采购精密气缸供应商',
  '买家寻找可采购的精密气缸供应商。',95,85,75,
  '[
    {"query_text":"精密气缸供应商 推荐","language":"zh-CN","region":"CN","priority":85},
    {"query_text":"工业气缸 采购渠道","language":"zh-CN","region":"CN","priority":75}
  ]'::jsonb) AS intent_purchase;

SELECT register_intent_with_queries(
  'SYNTH-ACME','AC-200 伺服模组','COMPARE','AC-200 与竞品对比',
  '买家对比 AC-200 与替代方案的差异。',80,85,60,
  '[
    {"query_text":"AC-200 伺服模组 对比","language":"zh-CN","region":"CN","priority":80},
    {"query_text":"伺服模组 选型对比","language":"zh-CN","region":"CN","priority":70}
  ]'::jsonb) AS intent_compare;

SELECT register_intent_with_queries(
  'SYNTH-ACME','合成测试精密工业有限公司','AFTER_SALES','精密气缸售后与质保',
  '买家关心质保、售后和交期。',70,70,65,
  '[
    {"query_text":"精密气缸 质保 售后","language":"zh-CN","region":"CN","priority":70}
  ]'::jsonb) AS intent_after_sales;

SELECT register_intent_with_queries(
  'SYNTH-ACME','AcmePrecision','TRUST','AcmePrecision 品牌可信度',
  '买家评估品牌可靠性与认证。',85,75,80,
  '[
    {"query_text":"AcmePrecision 品牌 可靠吗","language":"zh-CN","region":"CN","priority":85},
    {"query_text":"AcmePrecision ISO9001 认证","language":"zh-CN","region":"CN","priority":80}
  ]'::jsonb) AS intent_trust;

COMMIT;