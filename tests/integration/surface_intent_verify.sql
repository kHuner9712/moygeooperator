-- ============================================================================
-- Stage 3 · WF-02/WF-03 integration assertions (SYNTH-ACME).
-- Run AFTER db/seeds/synthetic_surface_intent.sql.
-- ============================================================================
\set ON_ERROR_STOP on

SELECT id INTO TEMP TABLE _t3_cid FROM clients WHERE code='SYNTH-ACME';
DO $$
DECLARE
  v_cid uuid;
  v_surface int; v_resource int; v_intent int; v_query int; v_evid int;
  v_active_surface int; v_priority numeric; v_orphans int;
  v_has_evidence int;
BEGIN
  SELECT id INTO v_cid FROM _t3_cid;
  IF v_cid IS NULL THEN RAISE EXCEPTION 'FAIL: SYNTH-ACME client not found'; END IF;

  SELECT count(*) INTO v_surface FROM surfaces WHERE client_id=v_cid;
  IF v_surface <> 5 THEN RAISE EXCEPTION 'FAIL surfaces expected 5 got %', v_surface; END IF;

  SELECT count(*) INTO v_resource FROM surface_resources WHERE client_id=v_cid;
  IF v_resource <> 5 THEN RAISE EXCEPTION 'FAIL resources expected 5 got %', v_resource; END IF;

  SELECT count(*) INTO v_intent FROM intents WHERE client_id=v_cid;
  IF v_intent <> 5 THEN RAISE EXCEPTION 'FAIL intents expected 5 got %', v_intent; END IF;

  SELECT count(*) INTO v_query FROM queries WHERE client_id=v_cid;
  IF v_query <> 10 THEN RAISE EXCEPTION 'FAIL queries expected 10 got %', v_query; END IF;

  SELECT count(*) INTO v_evid FROM evidence_items
    WHERE client_id=v_cid AND source_kind='PUBLIC_WEB';
  IF v_evid <> 2 THEN RAISE EXCEPTION 'FAIL public evidence expected 2 got %', v_evid; END IF;

  -- All discovered surfaces active.
  SELECT count(*) INTO v_active_surface FROM surfaces WHERE client_id=v_cid AND active;
  IF v_active_surface <> v_surface THEN RAISE EXCEPTION 'FAIL some surfaces inactive'; END IF;

  -- priority_score computed from commercial+relevance+opportunity (P0.3:
  -- unified 0-100 weighted scale, 0.35/0.40/0.25). Values are 0-100, not 0-300.
  SELECT priority_score INTO v_priority FROM intents
    WHERE client_id=v_cid AND label='采购精密气缸供应商';
  IF v_priority IS DISTINCT FROM round(0.35*95 + 0.40*85 + 0.25*75, 2) THEN
    RAISE EXCEPTION 'FAIL purchase priority expected weighted 0-100 got %', v_priority; END IF;
  IF v_priority < 0 OR v_priority > 100 THEN
    RAISE EXCEPTION 'FAIL priority outside 0-100 scale: %', v_priority; END IF;

  -- Every intent has at least one query.
  SELECT count(*) INTO v_orphans FROM intents i
    WHERE i.client_id=v_cid AND NOT EXISTS (SELECT 1 FROM queries q WHERE q.intent_id=i.id);
  IF v_orphans <> 0 THEN RAISE EXCEPTION 'FAIL % intents have no queries', v_orphans; END IF;

  -- Every resource belongs to a surface of the same client (no cross-client leak).
  SELECT count(*) INTO v_orphans FROM surface_resources r
    JOIN surfaces s ON s.id=r.surface_id
    WHERE r.client_id=v_cid AND s.client_id <> r.client_id;
  IF v_orphans <> 0 THEN RAISE EXCEPTION 'FAIL cross-client resource leak detected'; END IF;

  -- Evidence carries a surface resource reference.
  SELECT count(*) INTO v_has_evidence FROM evidence_items
    WHERE client_id=v_cid AND source_kind='PUBLIC_WEB'
      AND metadata ? 'surface_resource_id';
  IF v_has_evidence <> 2 THEN RAISE EXCEPTION 'FAIL evidence missing resource ref'; END IF;

  RAISE NOTICE 'PASS surface_intent: surfaces=% resources=% intents=% queries=% evidence=% priority=%',
    v_surface, v_resource, v_intent, v_query, v_evid, v_priority;
END $$;
DROP TABLE _t3_cid;