-- ============================================================================
-- Stage 5 · SYNTHETIC Gap / Action — WF-05 vertical slice.
-- THIS DATA IS SYNTHETIC. Runs gap analysis and action planning on the
-- fictional "合成测试精密工业有限公司". Idempotent: analyze_gaps / plan_actions
-- use deterministic dedup keys, so re-running creates no duplicates.
-- Expected (with the Stage 2/3/4 SYNTH seeds applied):
--   gaps      = 5  (1 ENGINE_VISIBILITY_GAP + 4 CONTENT_GAP)
--   actions   = 2  CONTENT_CREATION (purchase + visibility gap)
--   exceptions= 3  CLIENT_DATA_REQUIRED (product / compare / trust — no VERIFIED facts)
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

SELECT analyze_gaps('SYNTH-ACME') AS gaps_created;
SELECT plan_actions('SYNTH-ACME') AS actions_planned;

-- WF-05 handoff: schedule a gap-analysis job and enqueue CONTENT_FACTORY jobs
-- for the planned OPEN actions (bridging to WF-06).
SELECT schedule_gap_analysis_jobs('SYNTH-ACME') AS gap_job_id;
SELECT enqueue_content_factory_jobs('SYNTH-ACME') AS content_jobs_enqueued;

COMMIT;