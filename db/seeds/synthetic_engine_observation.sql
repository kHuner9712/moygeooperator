-- ============================================================================
-- Stage 4 · SYNTHETIC Engine Observation — WF-04 vertical slice.
-- THIS DATA IS SYNTHETIC. Uses the fictional "合成测试精密工业有限公司" and
-- synthetic engines/engines/outputs. Never treat as, or export as, a real
-- business result. Idempotent: safe to re-run (run_key / unique_key dedup).
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

-- Synthetic engine catalog (capability catalog, not a real deployment).
SELECT upsert_engine('SYNTH-LOCAL','Qwen2.5','chat','CN','zh-CN',true,
  '{"note":"SYNTHETIC engine for WF-04 validation"}') AS eng_chat;
SELECT upsert_engine('SYNTH-SEARCH','web-search-mock','websearch','CN','zh-CN',true,
  '{"note":"SYNTHETIC engine for WF-04 validation"}') AS eng_search;

-- Resolve reference ids for SYNTH-ACME queries/surfaces.
SELECT q.id INTO TEMP TABLE _s4_q FROM queries q
WHERE q.client_id=(SELECT id FROM clients WHERE code='SYNTH-ACME')
  AND q.query_text='AC-100 精密气缸 参数';
SELECT q.id INTO TEMP TABLE _s4_q2 FROM queries q WHERE q.client_id=(SELECT id FROM clients WHERE code='SYNTH-ACME')
  AND q.query_text='精密气缸供应商 推荐';
SELECT id INTO TEMP TABLE _s4_surf FROM surfaces
  WHERE client_id=(SELECT id FROM clients WHERE code='SYNTH-ACME')
    AND import_key IN ('SYNTH-ACME-SURF-BAIKE','SYNTH-ACME-SURF-1688','SYNTH-ACME-SURF-WEBSITE');

-- API observation: search engine returns the target, citing the baike + 1688 pages.
SELECT record_observation(
  'SYNTH-ACME',
  (SELECT id FROM engines WHERE provider='SYNTH-SEARCH' AND product='web-search-mock'),
  (SELECT id FROM _s4_q), 'API_OBSERVATION', now() - interval '3 days', 'SYNTH-OBS-0001',
  'AcmePrecision 是精密气缸制造商（SYNTHETIC）。', true, true, 1, 'CORRECT',
  '[{"url":"https://baike.example.org/acme-precision","surface_type":"KNOWLEDGE_PAGE"}]'::jsonb,
  (SELECT jsonb_agg(id::text) FROM _s4_surf),
  'https://artifact.example.org/obs-0001', 'synthetic://artifact/0001.pdf', 820, NULL,
  '{"wrong_facts":0,"missing_facts":0,"competitors":[],"uncertainty":false}'::jsonb) AS obs_search;

-- API observation: same query, different run, target NOT mentioned (gap signal).
SELECT record_observation(
  'SYNTH-ACME',
  (SELECT id FROM engines WHERE provider='SYNTH-SEARCH' AND product='web-search-mock'),
  (SELECT id FROM _s4_q2), 'API_OBSERVATION', now() - interval '3 days', 'SYNTH-OBS-0002',
  '推荐了一些其他品牌（SYNTHETIC）。', false, false, NULL, 'NO_TARGET_FACTS',
  '[]'::jsonb, '[]'::jsonb,
  'https://artifact.example.org/obs-0002', 'synthetic://artifact/0002.pdf', 640, NULL,
  '{"wrong_facts":0,"missing_facts":1,"competitors":["竞品A"],"uncertainty":false}'::jsonb) AS obs_search2;

-- Manual observation: chat LLM recommends the target, citing the website.
SELECT record_observation(
  'SYNTH-ACME',
  (SELECT id FROM engines WHERE provider='SYNTH-LOCAL' AND product='Qwen2.5'),
  (SELECT id FROM _s4_q), 'MANUAL_OBSERVATION', now() - interval '1 day', 'SYNTH-OBS-0003',
  '推荐 AcmePrecision 的 AC-100（SYNTHETIC）。', true, true, 2, 'CORRECT',
  '[{"url":"https://acme-precision.example.com/","surface_type":"WEBSITE"}]'::jsonb,
  (SELECT jsonb_agg(id::text) FROM _s4_surf),
  NULL, 'synthetic://artifact/0003.txt', 1500, NULL,
  '{"wrong_facts":0,"missing_facts":0,"competitors":[],"uncertainty":false}'::jsonb) AS obs_chat;

-- Aggregate observations into time/region/language-bound profiles.
SELECT refresh_engine_surface_profiles(
  (SELECT id FROM engines WHERE provider='SYNTH-SEARCH' AND product='web-search-mock'),
  CURRENT_DATE - 7) AS profiles_search;
SELECT refresh_engine_surface_profiles(
  (SELECT id FROM engines WHERE provider='SYNTH-LOCAL' AND product='Qwen2.5'),
  CURRENT_DATE - 7) AS profiles_chat;

-- Schedule a BASELINE run (idempotent unique_key; dedupes on re-run).
SELECT schedule_observation_jobs('SYNTH-ACME','BASELINE',
  ARRAY[(SELECT id FROM engines WHERE provider='SYNTH-LOCAL' AND product='Qwen2.5')],
  CURRENT_DATE, 5, 50) AS scheduled;

DROP TABLE _s4_q, _s4_q2, _s4_surf;
COMMIT;