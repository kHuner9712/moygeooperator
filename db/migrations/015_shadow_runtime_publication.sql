-- ============================================================================
-- MOY GEO Operator · Migration 015 · Shadow Runtime Publication Closure (P0.14/15/16)
--
-- WF-06 previously stopped at "canonical asset READY_TO_PUBLISH". This migration
-- adds the closing orchestration so a canonical asset actually flows:
--
--   canonical READY_TO_PUBLISH
--     -> per target Surface: adapt_content_for_surface()  -> adapted DRAFT
--     -> approve_content_asset()                          -> Fact + Compliance re-gate
--     -> only fact=PASSED & compliance=PASSED
--        -> create_publication_task()                     -> publication task
--        -> schedule_publication_jobs()                   -> enqueue PUBLICATION job (WF-07)
--
-- One adapted asset per target surface. The base canonical asset is NEVER
-- published to every surface directly. Publication still fails closed (a task is
-- only created for a fully-gated adapted asset).
-- ============================================================================

-- ============================================================================
-- close_content_to_publication — turn a canonical READY_TO_PUBLISH asset into
-- per-surface adapted assets, re-run both gates on each, and enqueue a PUBLICATION
-- job per surface. Returns a summary {result, adapted, passed, blocked}.
-- Idempotent: adapt_content_for_surface / create_publication_task / enqueue_job
-- all dedup on their unique keys, so re-running yields the same state.
-- ============================================================================
CREATE OR REPLACE FUNCTION close_content_to_publication(
  p_client_code text,
  p_base_asset_id uuid
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_client uuid;
  v_base content_assets%ROWTYPE;
  v_brief content_briefs%ROWTYPE;
  v_surface_ids uuid[];
  v_surface uuid;
  v_adapted uuid;
  v_gate jsonb;
  v_task uuid;
  n_adapted int := 0;
  n_passed int := 0;
  n_blocked int := 0;
  v_errors text[] := '{}';
BEGIN
  SELECT id INTO v_client FROM clients WHERE code = p_client_code;
  IF v_client IS NULL THEN
    RAISE EXCEPTION 'client % not found', p_client_code;
  END IF;

  SELECT * INTO v_base FROM content_assets
    WHERE id = p_base_asset_id AND client_id = v_client;
  IF v_base IS NULL THEN
    RAISE EXCEPTION 'base asset % not found for client %', p_base_asset_id, p_client_code;
  END IF;

  -- The base must be a fully-gated CANONICAL asset (no surface binding).
  IF v_base.status <> 'READY_TO_PUBLISH'
     OR v_base.fact_check_status <> 'PASSED'
     OR v_base.compliance_status <> 'PASSED'
     OR v_base.surface_id IS NOT NULL THEN
    PERFORM raise_exception(v_client, 'CONTENT_QA_FAILED', 'HIGH',
      'Canonical asset is not publication-ready',
      'asset ' || p_base_asset_id::text || ' status=' || v_base.status ||
        ' fact=' || COALESCE(v_base.fact_check_status,'PENDING') ||
        ' compliance=' || COALESCE(v_base.compliance_status,'PENDING') ||
        ' surface_id=' || COALESCE(v_base.surface_id::text,'NULL') ||
        '; only a gated canonical asset (surface_id NULL) may be closed to publication.',
      NULL, 'CONTENT_ASSET', v_base.id);
    RETURN jsonb_build_object('result', 'BLOCKED', 'adapted', 0, 'passed', 0, 'blocked', 0);
  END IF;

  SELECT * INTO v_brief FROM content_briefs WHERE id = v_base.brief_id;
  IF v_brief IS NULL THEN
    PERFORM raise_exception(v_client, 'CLIENT_DATA_REQUIRED', 'HIGH',
      'No brief for canonical asset',
      'asset ' || p_base_asset_id::text || ' has no resolvable brief.',
      NULL, 'CONTENT_ASSET', v_base.id);
    RETURN jsonb_build_object('result', 'BLOCKED', 'adapted', 0, 'passed', 0, 'blocked', 0);
  END IF;

  v_surface_ids := ARRAY(SELECT jsonb_array_elements_text(v_brief.target_surfaces)::uuid);
  IF array_length(v_surface_ids, 1) IS NULL THEN
    PERFORM raise_exception(v_client, 'CLIENT_DATA_REQUIRED', 'HIGH',
      'No target surfaces for publication closure',
      'brief ' || v_brief.id::text || ' has no target_surfaces; nothing to close.',
      NULL, 'CONTENT_BRIEF', v_brief.id);
    RETURN jsonb_build_object('result', 'BLOCKED', 'adapted', 0, 'passed', 0, 'blocked', 0);
  END IF;

  FOREACH v_surface IN ARRAY v_surface_ids LOOP
    -- Fail closed on any cross-client surface (surface must belong to THIS client).
    IF NOT EXISTS (SELECT 1 FROM surfaces WHERE id = v_surface AND client_id = v_client) THEN
      v_errors := array_append(v_errors, 'cross-client surface ' || v_surface::text);
      PERFORM raise_exception(v_client, 'CROSS_CLIENT_REFERENCE', 'CRITICAL',
        'Cross-client surface reference blocked',
        'surface ' || v_surface::text || ' does not belong to client ' || p_client_code,
        NULL, 'surface', v_surface);
      CONTINUE;
    END IF;

    -- 1) adapt: per-surface DRAFT asset with PENDING gates (never inherits base gates).
    v_adapted := adapt_content_for_surface(p_client_code, v_base.id, v_surface, 'MARKDOWN');
    IF v_adapted IS NULL THEN
      v_errors := array_append(v_errors, 'adapt ' || v_surface::text || ' produced no asset');
      CONTINUE;
    END IF;
    n_adapted := n_adapted + 1;

    -- 2) re-gate the adapted copy.
    v_gate := approve_content_asset(v_adapted);
    IF (v_gate->>'fact_check') = 'PASSED' AND (v_gate->>'compliance') = 'PASSED' THEN
      -- 3) only a fully-gated adapted asset enters the publication queue (WF-07).
      n_passed := n_passed + 1;
      v_task := schedule_publication_jobs(p_client_code, v_adapted, v_surface);
    ELSE
      n_blocked := n_blocked + 1;
      v_errors := array_append(v_errors,
        'surface ' || v_surface::text || ' gate fact=' || (v_gate->>'fact_check') ||
        ' compliance=' || (v_gate->>'compliance'));
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'result', CASE WHEN n_passed > 0 THEN 'OK' ELSE 'BLOCKED' END,
    'adapted', n_adapted, 'passed', n_passed, 'blocked', n_blocked,
    'errors', to_jsonb(v_errors));
END;
$$;