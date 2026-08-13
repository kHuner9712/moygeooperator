-- ============================================================================
-- MOY GEO Operator · Migration 006 · Stage 5 · Gap / Action (WF-05)
-- idempotent gap recording, rule-driven gap analysis, action planning with
-- priority, and fail-closed CLIENT_DATA_REQUIRED exceptions.
-- Gap taxonomy (design WF-05): MISSING_ENTITY / ENTITY_AMBIGUITY /
-- MISSING_SURFACE / WRONG_FACT / STALE_FACT / CITATION_GAP / EVIDENCE_GAP /
-- INTENT_GAP / CONTENT_GAP / AUTHORITY_GAP / ENGINE_VISIBILITY_GAP.
-- This slice implements the deterministic, observation/readiness-driven subset
-- (ENGINE_VISIBILITY_GAP, CONTENT_GAP); fact-classification gaps (WRONG_FACT,
-- STALE_FACT, ...) are raised via record_gap by WF-02/WF-06 at their boundary.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Idempotency keys for gaps and actions (deterministic; retry-safe).
-- ---------------------------------------------------------------------------
ALTER TABLE geo_gaps    ADD COLUMN IF NOT EXISTS dedup_key text;
ALTER TABLE geo_actions ADD COLUMN IF NOT EXISTS dedup_key text;

CREATE UNIQUE INDEX IF NOT EXISTS uq_geo_gaps_dedup
  ON geo_gaps(dedup_key) WHERE dedup_key IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_geo_actions_dedup
  ON geo_actions(dedup_key) WHERE dedup_key IS NOT NULL;

-- ============================================================================
-- record_gap — idempotent gap creation. Resolves entity/intent by code/label.
-- Returns the gap id, or NULL if a duplicate (same dedup_key) already exists.
-- Cross-client: any client mismatch raises (never silently attaches a gap to
-- the wrong client).
-- ============================================================================
CREATE OR REPLACE FUNCTION record_gap(
  p_client_code text,
  p_gap_type text,
  p_severity text,
  p_diagnosis text,
  p_entity_code text DEFAULT NULL,
  p_intent_label text DEFAULT NULL,
  p_engine_id uuid DEFAULT NULL,
  p_surface_id uuid DEFAULT NULL,
  p_evidence_refs jsonb DEFAULT '[]',
  p_dedup_key text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_client uuid;
  v_entity uuid;
  v_intent uuid;
  v_entity_cid uuid;
  v_intent_cid uuid;
  v_id uuid;
BEGIN
  SELECT id INTO v_client FROM clients WHERE code = p_client_code;
  IF v_client IS NULL THEN
    RAISE EXCEPTION 'client % not found', p_client_code;
  END IF;

  IF p_entity_code IS NOT NULL THEN
    SELECT id, client_id INTO v_entity, v_entity_cid FROM entities
      WHERE client_id = v_client AND canonical_name = p_entity_code;
    IF v_entity IS NULL THEN
      RAISE EXCEPTION 'entity % not found for client %', p_entity_code, p_client_code;
    END IF;
    IF v_entity_cid IS DISTINCT FROM v_client THEN
      RAISE EXCEPTION 'cross-client mismatch on entity %', p_entity_code;
    END IF;
  END IF;

  IF p_intent_label IS NOT NULL THEN
    SELECT id, client_id INTO v_intent, v_intent_cid FROM intents
      WHERE client_id = v_client AND label = p_intent_label;
    IF v_intent IS NULL THEN
      RAISE EXCEPTION 'intent % not found for client %', p_intent_label, p_client_code;
    END IF;
    IF v_intent_cid IS DISTINCT FROM v_client THEN
      RAISE EXCEPTION 'cross-client mismatch on intent %', p_intent_label;
    END IF;
  END IF;

  INSERT INTO geo_gaps(client_id, entity_id, intent_id, engine_id, surface_id,
                       gap_type, severity, diagnosis, evidence_refs, dedup_key)
  VALUES (v_client, v_entity, v_intent, p_engine_id, p_surface_id,
          p_gap_type, p_severity, p_diagnosis, COALESCE(p_evidence_refs,'[]'),
          p_dedup_key)
  ON CONFLICT (dedup_key) WHERE dedup_key IS NOT NULL DO NOTHING
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

-- ============================================================================
-- analyze_gaps — deterministic WF-05 gap detection for a client.
--  1. ENGINE_VISIBILITY_GAP : the engine did not surface the target
--     (target_mentioned = false in an observation).
--  2. CONTENT_GAP           : high-priority active intent with no content brief.
-- Returns the number of NEW gaps created (idempotent on re-run).
-- ============================================================================
CREATE OR REPLACE FUNCTION analyze_gaps(p_client_code text) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  v_client uuid;
  n int := 0;
  v_gap uuid;
  r RECORD;
BEGIN
  SELECT id INTO v_client FROM clients WHERE code = p_client_code;
  IF v_client IS NULL THEN
    RAISE EXCEPTION 'client % not found', p_client_code;
  END IF;

  -- 1. Visibility: engine answered but never surfaced the target entity.
  FOR r IN
    SELECT o.engine_id, q.intent_id, i.label AS intent_label,
           COALESCE(i.entity_id, NULL) AS entity_id,
           e.canonical_name AS entity_name,
           q.priority AS q_priority, o.run_key
    FROM engine_observations o
    JOIN queries q ON q.id = o.query_id
    JOIN intents i ON i.id = q.intent_id
    LEFT JOIN entities e ON e.id = i.entity_id
    WHERE o.client_id = v_client AND o.target_mentioned = false
  LOOP
    v_gap := record_gap(
      p_client_code, 'ENGINE_VISIBILITY_GAP',
      CASE WHEN r.q_priority >= 80 THEN 'HIGH' ELSE 'MEDIUM' END,
      'Engine did not surface target for intent '
        || COALESCE(r.intent_label,'?') || ' (run ' || r.run_key || ').',
      r.entity_name, r.intent_label, r.engine_id, NULL, '[]'::jsonb,
      'vis:' || v_client::text || ':' || r.engine_id::text || ':' || r.intent_id::text);
    IF v_gap IS NOT NULL THEN n := n + 1; END IF;
  END LOOP;

  -- 2. Content readiness: high-priority active intents with no content brief.
  FOR r IN
    SELECT i.id AS intent_id, i.label AS intent_label, i.entity_id,
           e.canonical_name AS entity_name, i.priority_score
    FROM intents i
    LEFT JOIN entities e ON e.id = i.entity_id
    WHERE i.client_id = v_client AND i.status = 'ACTIVE'
      AND i.priority_score >= 220
      AND NOT EXISTS (SELECT 1 FROM content_briefs cb WHERE cb.intent_id = i.id)
  LOOP
    v_gap := record_gap(
      p_client_code, 'CONTENT_GAP', 'HIGH',
      'High-priority intent has no content brief; priority=' || r.priority_score,
      r.entity_name, r.intent_label, NULL, NULL, '[]'::jsonb,
      'content:' || v_client::text || ':' || r.intent_id::text);
    IF v_gap IS NOT NULL THEN n := n + 1; END IF;
  END LOOP;

  RETURN n;
END;
$$;

-- ============================================================================
-- plan_actions — turn OPEN gaps into GEO actions (priority-ordered) or, when
-- the target entity has no VERIFIED canonical fact, into a fail-closed
-- CLIENT_DATA_REQUIRED exception (content cannot be authored without verified
-- facts). Idempotent: re-runs do not duplicate actions or exceptions.
-- Returns { content_actions, data_exceptions } created this run.
-- ============================================================================
CREATE OR REPLACE FUNCTION plan_actions(p_client_code text) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_client uuid;
  n_content int := 0;
  n_data int := 0;
  v_has_verified boolean;
  v_priority int;
  v_action_key text;
  r RECORD;
BEGIN
  SELECT id INTO v_client FROM clients WHERE code = p_client_code;
  IF v_client IS NULL THEN
    RAISE EXCEPTION 'client % not found', p_client_code;
  END IF;

  FOR r IN
    SELECT g.id AS gap_id, g.gap_type, g.intent_id,
           COALESCE(g.entity_id, i.entity_id) AS resolved_entity,
           i.label AS intent_label, i.priority_score
    FROM geo_gaps g
    LEFT JOIN intents i ON i.id = g.intent_id
    WHERE g.client_id = v_client AND g.status = 'OPEN'
    ORDER BY COALESCE(i.priority_score, 0) DESC
  LOOP
    IF r.gap_type IN ('ENGINE_VISIBILITY_GAP','CONTENT_GAP') THEN
      -- Content route: only allowed when the target has >=1 VERIFIED claim.
      SELECT EXISTS (SELECT 1 FROM claims c
                     WHERE c.entity_id = r.resolved_entity
                       AND c.verification = 'VERIFIED')
        INTO v_has_verified;

      IF v_has_verified THEN
        v_action_key := 'action:' || v_client::text || ':' || r.gap_id::text;
        IF NOT EXISTS (SELECT 1 FROM geo_actions WHERE dedup_key = v_action_key) THEN
          v_priority := COALESCE(r.priority_score, 50)::int;
          INSERT INTO geo_actions(client_id, gap_id, action_type, title,
                                  instructions, priority, target_intent_id,
                                  due_at, dedup_key)
          VALUES (v_client, r.gap_id, 'CONTENT_CREATION',
                  'Create GEO content for intent: ' || COALESCE(r.intent_label,'?'),
                  'Author canonical content from VERIFIED claims, then adapt per surface (WF-06).',
                  v_priority, r.intent_id, now() + interval '7 days', v_action_key);
          n_content := n_content + 1;
        END IF;
      ELSE
        IF NOT EXISTS (SELECT 1 FROM exceptions
                       WHERE exception_type = 'CLIENT_DATA_REQUIRED'
                         AND related_object_id = r.gap_id AND status = 'OPEN') THEN
          PERFORM raise_exception(
            v_client, 'CLIENT_DATA_REQUIRED', 'HIGH',
            'No VERIFIED claim for content target',
            'Cannot author content for intent ' || COALESCE(r.intent_label,'?')
              || ' — it has no VERIFIED canonical facts. Provide client data first.',
            NULL, 'GEO_GAP', r.gap_id);
          n_data := n_data + 1;
        END IF;
      END IF;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('content_actions', n_content, 'data_exceptions', n_data);
END;
$$;