-- ============================================================================
-- Stage 8 · SYNTHETIC Retest / Reporting — WF-08 vertical slice.
-- THIS DATA IS SYNTHETIC. Uses the fictional "合成测试精密工业有限公司"
-- (SYNTH-ACME). Demonstrates:
--  - verify_publication on the Stage 7 OFFICIAL_SITE record (PUBLISHED -> VERIFIED)
--  - an engine retest schedule (idempotent unique_key)
--  - a prior-period observation baseline so the weekly report shows a real delta
--  - compute_period_metrics / generate_report for a WEEKLY report
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

-- Resolve reference ids.
SELECT id INTO TEMP TABLE _s8_cid FROM clients WHERE code='SYNTH-ACME';
SELECT q.id INTO TEMP TABLE _s8_q FROM queries q
WHERE q.client_id IN (SELECT id FROM _s8_cid) AND q.query_text='AC-100 精密气缸 参数';
SELECT id INTO TEMP TABLE _s8_eng_search FROM engines
WHERE provider='SYNTH-SEARCH' AND product='web-search-mock';
SELECT id INTO TEMP TABLE _s8_surf_baike FROM surfaces
WHERE client_id IN (SELECT id FROM _s8_cid) AND import_key='SYNTH-ACME-SURF-BAIKE';

-- Prior-period baseline observations (14 days ago) so the WEEKLY report
-- compares two non-empty windows. Lower mention rate = negative-ish delta.
SELECT record_observation(
  'SYNTH-ACME',
  (SELECT id FROM _s8_eng_search), (SELECT id FROM _s8_q),
  'API_OBSERVATION', CURRENT_DATE - 14, 'SYNTH-OBS-PREV-0001',
  'AcmePrecision 被提及，但未作为首选推荐（SYNTHETIC 前周期基线）。',
  true, false, 4, 'CORRECT',
  '[{"url":"https://baike.example.org/acme-precision","surface_type":"KNOWLEDGE_PAGE"}]'::jsonb,
  (SELECT jsonb_agg(id::text) FROM _s8_surf_baike),
  'https://artifact.example.org/obs-prev-0001', 'synthetic://artifact/prev-0001.pdf', 780, NULL,
  '{"wrong_facts":0,"missing_facts":0,"competitors":[],"uncertainty":false}'::jsonb) AS prev_obs1;

SELECT record_observation(
  'SYNTH-ACME',
  (SELECT id FROM _s8_eng_search), (SELECT id FROM _s8_q),
  'API_OBSERVATION', CURRENT_DATE - 14, 'SYNTH-OBS-PREV-0002',
  '目标未出现在结果中（SYNTHETIC 前周期基线）。',
  false, false, NULL, 'NO_TARGET_FACTS',
  '[]'::jsonb, '[]'::jsonb,
  'https://artifact.example.org/obs-prev-0002', 'synthetic://artifact/prev-0002.pdf', 700, NULL,
  '{"wrong_facts":0,"missing_facts":1,"competitors":["竞品A"],"uncertainty":false}'::jsonb) AS prev_obs2;

-- Verify the OFFICIAL_SITE publication record that Stage 7 published.
CREATE OR REPLACE FUNCTION __synth_verify() RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_rec uuid;
BEGIN
  SELECT r.id INTO v_rec
    FROM publication_records r
    JOIN publication_tasks t ON t.id = r.publication_task_id
    JOIN surfaces s ON s.id = t.surface_id
    JOIN clients c ON c.id = r.client_id
    WHERE c.code = 'SYNTH-ACME' AND s.platform = 'OFFICIAL_SITE'
      AND r.verification_status = 'PENDING'
    ORDER BY r.published_at DESC LIMIT 1;
  IF v_rec IS NOT NULL THEN
    PERFORM verify_publication(v_rec, 'VERIFIED',
      'https://acme-precision.example.com/company', 'https://evidence.example.org/pub-verify-0001',
      '{"simulated": true, "live_check": "confirmed"}'::jsonb);
  END IF;
END;
$$;
SELECT __synth_verify();
DROP FUNCTION __synth_verify();

-- Schedule an engine retest (idempotent unique_key; safe to re-run).
SELECT schedule_engine_retest('SYNTH-ACME', CURRENT_DATE, 50) AS retest_scheduled;

-- Compute + persist a WEEKLY report across the current window.
SELECT generate_report('SYNTH-ACME', 'WEEKLY', CURRENT_DATE - 7, CURRENT_DATE) AS report_id;

DROP TABLE _s8_cid, _s8_q, _s8_eng_search, _s8_surf_baike;
COMMIT;