-- ============================================================================
-- Stage 6 · SYNTHETIC Content Factory — WF-06 vertical slice.
-- THIS DATA IS SYNTHETIC. Builds a canonical brief and VERIFIED-only content
-- assets for the fictional "合成测试精密工业有限公司" (SYNTH-ACME). Idempotent:
-- brief/asset creation uses deterministic dedup keys.
-- Expected: 2 CONTENT_CREATION actions -> 2 briefs -> canonical asset + a
-- per-surface variant each, all fact-checked VERIFIED (enterprise has 4
-- VERIFIED claims).
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

-- Build a canonical brief for each planned CONTENT_CREATION action.
CREATE OR REPLACE FUNCTION __synth_brief_for(int) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v uuid;
BEGIN
  FOR v IN
    SELECT create_content_brief('SYNTH-ACME', a.id)
    FROM geo_actions a
    WHERE a.client_id = (SELECT id FROM clients WHERE code='SYNTH-ACME')
      AND a.action_type='CONTENT_CREATION'
    ORDER BY a.priority DESC
  LOOP
    RETURN v;
  END LOOP;
  RETURN NULL;
END;
$$;
SELECT __synth_brief_for(1);
DROP FUNCTION __synth_brief_for(int);

-- Generate a VERIFIED canonical asset per READY brief.
CREATE OR REPLACE FUNCTION __synth_assets() RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_brief uuid;
  v_asset uuid;
  v_surface uuid;
BEGIN
  FOR v_brief IN
    SELECT b.id FROM content_briefs b
    WHERE b.client_id = (SELECT id FROM clients WHERE code='SYNTH-ACME')
      AND b.status='READY'
  LOOP
    v_asset := generate_content_asset('SYNTH-ACME', v_brief, 'MARKDOWN');
    -- P0.6 fact gate + compliance gate: an asset must be approved
    -- (fact_check_status=PASSED AND compliance_status=PASSED) before it can
    -- enter the publication queue. Synthetic content built from VERIFIED
    -- claims passes; a hallucinated asset would be BLOCKED here.
    PERFORM approve_content_asset(v_asset);
    -- Surface adaptation: one variant per active owned surface. P0.10: the
    -- adapted copy is a fresh DRAFT with PENDING gates (client-aware 4-arg
    -- overload), so we re-run approve_content_asset on each variant exactly
    -- as WF-06 does — the base's publication-ready status is never inherited.
    FOR v_surface IN
      SELECT s.id FROM surfaces s
      WHERE s.client_id = (SELECT id FROM clients WHERE code='SYNTH-ACME')
        AND s.owner_entity_id = (SELECT target_entity_id FROM content_briefs WHERE id=v_brief)
        AND s.active
    LOOP
      v_asset := adapt_content_for_surface('SYNTH-ACME', v_asset, v_surface, 'POST');
      IF v_asset IS NOT NULL THEN
        PERFORM approve_content_asset(v_asset);
      END IF;
    END LOOP;
  END LOOP;
END;
$$;
SELECT __synth_assets();
DROP FUNCTION __synth_assets();

COMMIT;