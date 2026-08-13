-- ============================================================================
-- MOY GEO Operator · Migration 012 · Runtime Convergence (P0 remediation)
-- Target: convert the synthetic vertical slice into a runtime that can safely
-- run ONE real client Shadow Run. No new GEO product capability is added.
--
-- Covers (DB layer):
--   P0.3  Unified 0-100 weighted intent scoring (0.35/0.40/0.25) + gap threshold
--   P0.4  Engine -> Observer Adapter contract; unsupported engines fail closed
--   P0.5  Claim-by-claim engine factuality (no more mentioned=CORRECT)
--   P0.6  Content Fact Gate + Compliance Gate (fact_check_status=PASSED, not VERIFIED)
--   P0.7  No simulated AUTO_API publish; real provider path only
--   P0.8  Job lease recovery for RUNNING jobs + retry/backoff bookkeeping
--   P0.9  Multi-client isolation on cross-object operators
--   P0.2  Truth document content parsing (TXT/MD/CSV) + evidence locator
-- ============================================================================

-- ============================================================================
-- P0.3 — Unified scoring scale (0-100 per component; priority = weighted 0-100)
-- ============================================================================

-- Normalize a component score to 0-100. Accepts legacy 0-1 inputs and scales
-- them up, so a 0-1 prompt can never silently produce a 0-300 priority again.
CREATE OR REPLACE FUNCTION normalize_score_100(p_value numeric) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_value IS NULL THEN NULL
    WHEN p_value BETWEEN 0 AND 1 THEN round(p_value * 100, 2)   -- legacy 0-1
    ELSE round(p_value, 2)                                       -- already 0-100
  END;
$$;

-- Weighted priority, 0-100. Weights: 0.35 commercial / 0.40 relevance / 0.25
-- opportunity. All DB intents, workflows and gap analysis share this scale.
CREATE OR REPLACE FUNCTION weighted_priority(
  p_commercial numeric, p_relevance numeric, p_opportunity numeric
) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$
  SELECT round(
      0.35 * normalize_score_100(p_commercial)
    + 0.40 * normalize_score_100(p_relevance)
    + 0.25 * normalize_score_100(p_opportunity), 2);
$$;

-- Rebuild register_intent_with_queries with the unified scale.
CREATE OR REPLACE FUNCTION register_intent_with_queries(
  p_client_code text,
  p_entity_name text,
  p_intent_type text,
  p_label text,
  p_description text DEFAULT NULL,
  p_commercial numeric DEFAULT NULL,
  p_relevance numeric DEFAULT NULL,
  p_opportunity numeric DEFAULT NULL,
  p_queries jsonb DEFAULT '[]'   -- [{query_text,language,region,priority}]
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_client uuid;
  v_ent uuid;
  v_intent uuid;
  v_q RECORD;
  n_queries int := 0;
  v_pri numeric;
  v_com numeric; v_rel numeric; v_opp numeric;
BEGIN
  SELECT id INTO v_client FROM clients WHERE code = p_client_code;
  IF v_client IS NULL THEN
    RAISE EXCEPTION 'client % not found', p_client_code;
  END IF;

  IF p_entity_name IS NOT NULL THEN
    SELECT id INTO v_ent FROM entities
      WHERE client_id = v_client AND canonical_name = p_entity_name
      LIMIT 1;
  END IF;

  v_com := normalize_score_100(p_commercial);
  v_rel := normalize_score_100(p_relevance);
  v_opp := normalize_score_100(p_opportunity);
  v_pri := weighted_priority(v_com, v_rel, v_opp);

  INSERT INTO intents(client_id, entity_id, intent_type, label, description,
                      commercial_score, relevance_score, opportunity_score,
                      priority_score)
  VALUES (v_client, v_ent, p_intent_type, p_label, p_description,
          v_com, v_rel, v_opp, v_pri)
  ON CONFLICT (client_id, label) DO UPDATE SET
    entity_id = COALESCE(EXCLUDED.entity_id, intents.entity_id),
    intent_type = EXCLUDED.intent_type,
    description = COALESCE(EXCLUDED.description, intents.description),
    commercial_score = COALESCE(EXCLUDED.commercial_score, intents.commercial_score),
    relevance_score  = COALESCE(EXCLUDED.relevance_score, intents.relevance_score),
    opportunity_score= COALESCE(EXCLUDED.opportunity_score, intents.opportunity_score),
    priority_score   = weighted_priority(
        COALESCE(EXCLUDED.commercial_score, intents.commercial_score),
        COALESCE(EXCLUDED.relevance_score, intents.relevance_score),
        COALESCE(EXCLUDED.opportunity_score, intents.opportunity_score)),
    status = 'ACTIVE'
  RETURNING id INTO v_intent;

  FOR v_q IN SELECT * FROM jsonb_to_recordset(p_queries)
    AS x(query_text text, language text, region text, priority int)
  LOOP
    INSERT INTO queries(client_id, intent_id, query_text, language, region, priority)
    VALUES (v_client, v_intent, v_q.query_text, v_q.language, v_q.region,
            COALESCE(v_q.priority, 50))
    ON CONFLICT (client_id, intent_id, query_text) DO NOTHING;
    n_queries := n_queries + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'intent_id', v_intent,
    'priority_score', v_pri,
    'queries_considered', n_queries);
END;
$$;

-- Re-scope analyze_gaps CONTENT_GAP threshold from 0-300 (>=220) to 0-100 (>=70).
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

  -- 2. Content readiness: high-priority active intents (priority >= 70 on 0-100)
  --    with no content brief.
  FOR r IN
    SELECT i.id AS intent_id, i.label AS intent_label, i.entity_id,
           e.canonical_name AS entity_name, i.priority_score
    FROM intents i
    LEFT JOIN entities e ON e.id = i.entity_id
    WHERE i.client_id = v_client AND i.status = 'ACTIVE'
      AND i.priority_score >= 70
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
-- P0.4 — Engine -> Observer Adapter contract
-- Every observation must come from an enabled, explicit adapter. An engine with
-- no enabled adapter is UNSUPPORTED and fails closed (never silently Ollama).
-- ============================================================================
CREATE TABLE IF NOT EXISTS engine_adapters (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  engine_id uuid NOT NULL REFERENCES engines(id),
  adapter text NOT NULL,                 -- LOCAL_OLLAMA / OPENAI_API / GEMINI_API /
                                         -- PERPLEXITY_API / UI_OBSERVATION / MANUAL_OBSERVATION
  adapter_version text NOT NULL DEFAULT '1.0.0',
  enabled boolean NOT NULL DEFAULT false,
  status text NOT NULL DEFAULT 'UNSUPPORTED',  -- UNSUPPORTED / READY / MANUAL_OBSERVATION_REQUIRED
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(engine_id, adapter)
);

-- Observation now records which adapter actually produced it.
ALTER TABLE engine_observations ADD COLUMN IF NOT EXISTS adapter text;
ALTER TABLE engine_observations ADD COLUMN IF NOT EXISTS adapter_version text;
ALTER TABLE engine_observations ADD COLUMN IF NOT EXISTS provider text;
ALTER TABLE engine_observations ADD COLUMN IF NOT EXISTS product text;
ALTER TABLE engine_observations ADD COLUMN IF NOT EXISTS mode text;
ALTER TABLE engine_observations ADD COLUMN IF NOT EXISTS region text;
ALTER TABLE engine_observations ADD COLUMN IF NOT EXISTS engine_language text;

-- Register an adapter for an engine (idempotent).
CREATE OR REPLACE FUNCTION register_engine_adapter(
  p_engine_id uuid,
  p_adapter text,
  p_enabled boolean DEFAULT false,
  p_adapter_version text DEFAULT '1.0.0',
  p_status text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_id uuid;
  v_status text := COALESCE(p_status,
    CASE WHEN p_enabled THEN 'READY'
         WHEN p_adapter IN ('UI_OBSERVATION','MANUAL_OBSERVATION') THEN 'MANUAL_OBSERVATION_REQUIRED'
         ELSE 'UNSUPPORTED' END);
BEGIN
  INSERT INTO engine_adapters(engine_id, adapter, enabled, adapter_version, status)
  VALUES (p_engine_id, p_adapter, p_enabled, p_adapter_version, v_status)
  ON CONFLICT (engine_id, adapter) DO UPDATE SET
    enabled = EXCLUDED.enabled,
    adapter_version = EXCLUDED.adapter_version,
    status = EXCLUDED.status,
    updated_at = now()
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

-- Resolve the single enabled adapter for an engine, or NULL when unsupported.
CREATE OR REPLACE FUNCTION resolve_engine_adapter(p_engine_id uuid) RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT adapter FROM engine_adapters
    WHERE engine_id = p_engine_id AND enabled
    ORDER BY created_at ASC LIMIT 1;
$$;

-- ============================================================================
-- P0.5 — Rule-based claim-by-claim factuality assessment
-- Removes the "mentioned => CORRECT" shortcut. Compares the answer's factual
-- content against the client's VERIFIED Truth claims (exact/overlap match on
-- the claim text). The generating model is never the sole judge: this is a
-- deterministic rule pass over Truth.
-- ============================================================================

-- Tokenize a string into a normalized set of "words" for overlap scoring.
CREATE OR REPLACE FUNCTION text_tokens(p_text text) RETURNS text[]
LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(array_agg(t), '{}'::text[])
  FROM (
    SELECT lower(regexp_replace(trim(w), '[^a-z0-9\u4e00-\u9fff%\-]', '', 'g')) AS t
    FROM unnest(string_to_array(p_text, ' ')) AS w
    WHERE length(trim(regexp_replace(w, '[^a-z0-9\u4e00-\u9fff%\-]', '', 'g'))) >= 2
  ) s;
$$;

-- Jaccard-ish overlap ratio between two token sets (0..1).
CREATE OR REPLACE FUNCTION token_overlap(p_a text, p_b text) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$
  WITH a AS (SELECT unnest(text_tokens(p_a)) t),
       b AS (SELECT unnest(text_tokens(p_b)) t),
       inter AS (SELECT count(*) n FROM a JOIN b USING (t)),
       uni AS (SELECT count(*) n FROM (SELECT t FROM a UNION SELECT t FROM b) u)
  SELECT COALESCE(round(inter.n::numeric / NULLIF(uni.n,0), 4), 0)
  FROM inter, uni;
$$;

-- Extract the numeric literals (integer / decimal) present in a text blob.
-- Used to catch numeric contradictions that pure token overlap would miss.
CREATE OR REPLACE FUNCTION extract_numbers(p_text text) RETURNS numeric[]
LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(array_agg(btrim(m[1], '.,')::numeric), '{}'::numeric[])
  FROM regexp_matches(coalesce(p_text,''), '([0-9]+(?:\.[0-9]+)?)', 'g') AS m;
$$;

-- Assess one answer against a set of VERIFIED claim ids for a client.
-- Returns:
--   status: CORRECT / PARTIALLY_CORRECT / INCORRECT / UNVERIFIABLE / NO_TARGET_FACTS
--   matched_claim_ids, wrong_claims, unsupported_claims, missing_claims
--   score: 0..1 fraction of matched claims
CREATE OR REPLACE FUNCTION assess_factuality(
  p_client_id uuid,
  p_answer_text text,
  p_claim_ids uuid[]
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  r RECORD;
  v_matched int := 0;
  v_total int := 0;
  v_matched_ids uuid[] := '{}';
  v_wrong text[] := '{}';
  v_unsupported text[] := '{}';
  v_missing text[] := '{}';
  v_status text;
  v_score numeric;
  v_answer text := COALESCE(NULLIF(trim(p_answer_text),''), '');
BEGIN
  IF v_answer = '' THEN
    RETURN jsonb_build_object('status','UNVERIFIABLE','score',0.0,
      'matched_claim_ids', '[]'::jsonb, 'wrong_claims', '[]'::jsonb,
      'unsupported_claims', '[]'::jsonb, 'missing_claims', '[]'::jsonb);
  END IF;

  FOR r IN
    SELECT c.id, c.claim_text, c.field_key
    FROM claims c
    WHERE c.id = ANY(COALESCE(p_claim_ids,'{}'::uuid[]))
      AND c.client_id = p_client_id
      AND c.verification = 'VERIFIED'
  LOOP
    v_total := v_total + 1;
    -- Numeric contradiction detection: if the VERIFIED claim asserts discrete
    -- numbers, the answer must state ALL of them. A claim with numbers that the
    -- answer omits (or replaces with other numbers) is wrong — never CORRECT —
    -- even when token overlap is high (e.g. "5000 PSI" vs "9000 PSI").
    IF EXISTS (SELECT 1 FROM unnest(extract_numbers(r.claim_text)) n
               WHERE NOT (v_answer LIKE '%' || n::text || '%')) THEN
      IF NOT EXISTS (SELECT 1 FROM unnest(extract_numbers(v_answer)) n) THEN
        v_missing := array_append(v_missing, r.claim_text);   -- number absent entirely
      ELSE
        v_wrong := array_append(v_wrong, r.claim_text);       -- contradicted by another number
      END IF;
      CONTINUE;
    END IF;
    -- A claim is "matched" when a strong overlap of its tokens appears in the
    -- answer (>= 0.6). Weak overlap => the answer advanced a wrong/unsupported fact.
    IF token_overlap(v_answer, r.claim_text) >= 0.6 THEN
      v_matched := v_matched + 1;
      v_matched_ids := array_append(v_matched_ids, r.id);
    ELSIF token_overlap(v_answer, r.claim_text) > 0 THEN
      v_wrong := array_append(v_wrong, r.claim_text);       -- contradicted/partial
    ELSE
      v_missing := array_append(v_missing, r.claim_text);   -- absent from answer
    END IF;
  END LOOP;

  v_score := round(v_matched::numeric / NULLIF(v_total,0), 4);
  IF v_total = 0 THEN
    v_status := 'UNVERIFIABLE';
  ELSIF v_matched = v_total THEN
    v_status := 'CORRECT';
  ELSIF v_matched > 0 THEN
    v_status := 'PARTIALLY_CORRECT';
  ELSE
    v_status := 'INCORRECT';
  END IF;

  -- Unsupported: answer asserts numeric/named facts that match no Truth claim,
  -- but token overlap finds some Truth vocabulary present (possible hallucination).
  IF v_total > 0 AND v_matched = 0 AND array_length(v_missing,1) IS NOT NULL THEN
    v_status := 'INCORRECT';
  END IF;

  RETURN jsonb_build_object(
    'status', v_status,
    'score', v_score,
    'matched_claim_ids', to_jsonb(v_matched_ids),
    'wrong_claims', to_jsonb(v_wrong),
    'unsupported_claims', to_jsonb(v_unsupported),
    'missing_claims', to_jsonb(v_missing));
END;
$$;

-- ============================================================================
-- P0.4 + P0.5 + P0.9 — record_observation (adapter-routed, client-isolated,
-- claim-by-claim factuality when not supplied by the caller).
-- ============================================================================
CREATE OR REPLACE FUNCTION record_observation(
  p_client_code text,
  p_engine_id uuid,
  p_query_id uuid,
  p_observation_kind observation_kind,
  p_observed_at timestamptz,
  p_run_key text,
  p_answer_text text DEFAULT NULL,
  p_target_mentioned boolean DEFAULT NULL,
  p_target_recommended boolean DEFAULT NULL,
  p_position_hint integer DEFAULT NULL,
  p_factuality_status text DEFAULT NULL,
  p_citations jsonb DEFAULT '[]',
  p_cited_surface_ids jsonb DEFAULT '[]',
  p_evidence_uri text DEFAULT NULL,
  p_raw_artifact_ref text DEFAULT NULL,
  p_latency_ms integer DEFAULT NULL,
  p_cost_amount numeric DEFAULT NULL,
  p_metadata jsonb DEFAULT '{}',
  p_adapter text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_client uuid;
  v_query_cid uuid;
  v_engine RECORD;
  v_adapter text := p_adapter;
  v_fact jsonb;
  v_id uuid;
  v_provider text; v_product text; v_mode text; v_region text; v_lang text;
BEGIN
  -- 1. Client scope (P0.9): query must belong to the requested client.
  SELECT id INTO v_client FROM clients WHERE code = p_client_code;
  IF v_client IS NULL THEN
    RAISE EXCEPTION 'client % not found', p_client_code;
  END IF;
  SELECT client_id INTO v_query_cid FROM queries WHERE id = p_query_id;
  IF v_query_cid IS NULL OR v_query_cid <> v_client THEN
    PERFORM raise_exception(v_client, 'CROSS_CLIENT_REFERENCE', 'CRITICAL',
      'Cross-client query reference blocked',
      'query ' || p_query_id::text || ' does not belong to client ' || p_client_code,
      NULL, 'query', p_query_id);
    RETURN NULL;   -- fail closed
  END IF;

  -- 2. Adapter contract (P0.4): the engine must have an ENABLED adapter.
  SELECT * INTO v_engine FROM engines WHERE id = p_engine_id;
  IF v_engine IS NULL THEN
    RAISE EXCEPTION 'engine % not found', p_engine_id;
  END IF;
  IF v_adapter IS NULL THEN
    v_adapter := resolve_engine_adapter(p_engine_id);
  END IF;
  IF v_adapter IS NULL OR NOT EXISTS (
      SELECT 1 FROM engine_adapters
      WHERE engine_id = p_engine_id AND adapter = v_adapter AND enabled) THEN
    PERFORM raise_exception(v_client, 'UNSUPPORTED_ENGINE', 'HIGH',
      'Engine has no enabled observer adapter',
      'engine ' || p_engine_id::text || ' (' || v_engine.provider || '/' ||
        v_engine.product || ') has no enabled adapter; refusing to record an ' ||
        'observation under it. Configure an adapter or route to MANUAL_OBSERVATION.',
      NULL, 'engine', p_engine_id);
    RETURN NULL;   -- fail closed
  END IF;

  -- 3. Factuality (P0.5): if not supplied, run the rule-based Truth comparison.
  IF p_factuality_status IS NULL OR p_factuality_status = '' THEN
    v_fact := assess_factuality(
      v_client, p_answer_text,
      ARRAY(SELECT id FROM claims c
            WHERE c.client_id = v_client
              AND (SELECT i.entity_id FROM intents i
                   JOIN queries q ON q.intent_id = i.id WHERE q.id = p_query_id) = c.entity_id
              AND c.verification = 'VERIFIED'));
    p_factuality_status := v_fact->>'status';
    p_metadata := COALESCE(p_metadata,'{}'::jsonb)
      || jsonb_build_object('factuality', v_fact);
  END IF;

  v_provider := v_engine.provider; v_product := v_engine.product;
  v_mode := v_engine.mode; v_region := v_engine.region; v_lang := v_engine.language;

  INSERT INTO engine_observations(client_id, engine_id, query_id, observation_kind,
    observed_at, run_key, answer_text, target_mentioned, target_recommended,
    position_hint, factuality_status, citations, cited_surface_ids, evidence_uri,
    raw_artifact_ref, latency_ms, cost_amount, metadata,
    adapter, adapter_version, provider, product, mode, region, engine_language)
  VALUES (v_client, p_engine_id, p_query_id, p_observation_kind,
    p_observed_at, p_run_key, p_answer_text, p_target_mentioned, p_target_recommended,
    p_position_hint, p_factuality_status, p_citations, p_cited_surface_ids, p_evidence_uri,
    p_raw_artifact_ref, p_latency_ms, p_cost_amount, COALESCE(p_metadata,'{}'),
    v_adapter, (SELECT adapter_version FROM engine_adapters
                WHERE engine_id = p_engine_id AND adapter = v_adapter LIMIT 1),
    v_provider, v_product, v_mode, v_region, v_lang)
  ON CONFLICT (client_id, engine_id, query_id, run_key)
  DO UPDATE SET
    metadata = EXCLUDED.metadata,
    factuality_status = COALESCE(EXCLUDED.factuality_status, engine_observations.factuality_status),
    adapter = COALESCE(EXCLUDED.adapter, engine_observations.adapter),
    adapter_version = COALESCE(EXCLUDED.adapter_version, engine_observations.adapter_version)
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

-- ============================================================================
-- P0.6 — Content Fact Gate + Compliance Gate
-- An asset is only ever marked READY_TO_PUBLISH after an independent gate
-- confirms  fact_check_status=PASSED AND compliance_status=PASSED. The LLM
-- output is never trusted as VERIFIED just because its input claims were.
-- ============================================================================

-- Extract plain "factual statements" (sentences) from the asset body.
CREATE OR REPLACE FUNCTION extract_factual_sentences(p_body text) RETURNS text[]
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  v_sents text[];
  s text;
BEGIN
  -- Split on newlines. Strip a leading markdown bullet ('- ') or list marker
  -- so a "factual statement" is the line content, not the bullet wrapper.
  -- Text bodies often render claims as "- claim" lines, so we must NOT drop
  -- them — otherwise the fact gate sees an empty sentence set and BLOCKs.
  FOREACH s IN ARRAY string_to_array(COALESCE(p_body,''), E'\n')
  LOOP
    s := trim(s);
    IF s <> '' THEN
      IF left(s,2) = '- ' THEN
        s := trim(substr(s, 3));
      ELSIF left(s,1) = '-' OR left(s,1) = '#' THEN
        s := trim(substr(s, 2));
      END IF;
      IF s <> '' THEN
        v_sents := array_append(v_sents, s);
      END IF;
    END IF;
  END LOOP;
  RETURN v_sents;
END;
$$;

-- Run the fact gate: every sentence in the body must be substantiable by one of
-- the brief's allowed VERIFIED claims (token overlap >= 0.5). Sentences that
-- introduce novel numeric/named facts with no Truth support are flagged and
-- BLOCK the asset (CONTENT_QA_FAILED). Returns PASSED / CONTENT_QA_FAILED.
CREATE OR REPLACE FUNCTION run_content_fact_gate(p_asset_id uuid) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
  v_asset content_assets%ROWTYPE;
  v_brief content_briefs%ROWTYPE;
  v_claim_ids uuid[];
  v_sents text[];
  v_unmatched text[] := '{}';
  v_claim_texts text[];
  s text;
  v_best numeric;
  cl RECORD;
  v_result text := 'PASSED';
BEGIN
  SELECT * INTO v_asset FROM content_assets WHERE id = p_asset_id;
  IF v_asset IS NULL THEN
    RAISE EXCEPTION 'content asset % not found', p_asset_id;
  END IF;
  SELECT * INTO v_brief FROM content_briefs WHERE id = v_asset.brief_id;
  IF v_brief IS NULL THEN
    RAISE EXCEPTION 'brief % not found', v_asset.brief_id;
  END IF;

  SELECT ARRAY(SELECT jsonb_array_elements_text(v_brief.required_claim_ids)::uuid)
    INTO v_claim_ids;
  SELECT COALESCE(array_agg(claim_text), '{}'::text[]) INTO v_claim_texts
    FROM claims WHERE id = ANY(v_claim_ids);

  v_sents := extract_factual_sentences(v_asset.body);
  IF array_length(v_sents,1) IS NULL THEN
    RETURN 'CONTENT_QA_FAILED';   -- empty body is unacceptable
  END IF;

  FOREACH s IN ARRAY v_sents
  LOOP
    v_best := 0;
    FOR cl IN SELECT unnest(v_claim_texts) t LOOP
      v_best := greatest(v_best, token_overlap(s, cl.t));
    END LOOP;
    -- Numeric fact gate: a sentence that asserts a number supported by NO
    -- allowed claim is a hallucinated figure (e.g. "9000 PSI" vs Truth "5000"),
    -- even when token overlap is high. Fail the sentence.
    IF array_length(extract_numbers(s), 1) IS NOT NULL
       AND NOT EXISTS (
         SELECT 1 FROM unnest(v_claim_texts) clt
         WHERE EXISTS (
           SELECT 1 FROM unnest(extract_numbers(s)) sn
           WHERE position(sn::text in clt) > 0)) THEN
      v_unmatched := array_append(v_unmatched, s || ' (unsupported number)');
    ELSIF v_best < 0.5 THEN
      v_unmatched := array_append(v_unmatched, s);
    END IF;
  END LOOP;

  IF array_length(v_unmatched,1) IS NOT NULL THEN
    v_result := 'CONTENT_QA_FAILED';
    -- Fail closed: raise a QA exception and BLOCK the asset.
    PERFORM raise_exception(
      v_asset.client_id, 'CONTENT_QA_FAILED', 'HIGH',
      'Asset contains facts unsupported by the Truth base (' || array_length(v_unmatched,1) || ' sentence(s))',
      'asset ' || p_asset_id::text || ' contains unsupported factual content: '
        || array_to_string(v_unmatched, ' | '),
      NULL, 'CONTENT_ASSET', v_asset.id);
    UPDATE content_assets SET
      fact_check_status = 'CONTENT_QA_FAILED', status = 'BLOCKED', updated_at = now()
      WHERE id = p_asset_id;
  ELSE
    UPDATE content_assets SET
      fact_check_status = 'PASSED', updated_at = now()
      WHERE id = p_asset_id;
  END IF;

  RETURN v_result;
END;
$$;

-- Compliance gate: only a PASSED fact-check may be approved; also enforces
-- prohibited claims and platform policy. Returns PASSED / BLOCKED.
CREATE OR REPLACE FUNCTION run_compliance_gate(p_asset_id uuid) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
  v_asset content_assets%ROWTYPE;
  v_brief content_briefs%ROWTYPE;
  v_fact text;
  v_result text;
BEGIN
  SELECT * INTO v_asset FROM content_assets WHERE id = p_asset_id;
  IF v_asset IS NULL THEN
    RAISE EXCEPTION 'content asset % not found', p_asset_id;
  END IF;

  -- Order matters: an asset cannot pass compliance before its facts are PASSED.
  IF v_asset.fact_check_status <> 'PASSED' THEN
    UPDATE content_assets SET compliance_status = 'BLOCKED', updated_at = now()
      WHERE id = p_asset_id;
    RETURN 'BLOCKED';
  END IF;

  SELECT * INTO v_brief FROM content_briefs WHERE id = v_asset.brief_id;
  IF v_brief IS NOT NULL AND jsonb_array_length(COALESCE(v_brief.prohibited_claims,'[]'::jsonb)) > 0
     AND EXISTS (
       SELECT 1 FROM jsonb_array_elements_text(v_brief.prohibited_claims) p
       WHERE position(lower(p) in lower(v_asset.body)) > 0) THEN
    v_result := 'BLOCKED';
  ELSE
    v_result := 'PASSED';
  END IF;

  UPDATE content_assets SET
    compliance_status = CASE WHEN v_result='PASSED' THEN 'PASSED' ELSE 'BLOCKED' END,
    status = CASE WHEN v_result='PASSED' THEN 'READY_TO_PUBLISH' ELSE 'BLOCKED' END,
    updated_at = now()
    WHERE id = p_asset_id;
  RETURN v_result;
END;
$$;

-- Two-step approval used by WF-06 after LLM generation: fact gate then
-- compliance gate. Only READY_TO_PUBLISH results may enter the publication queue.
CREATE OR REPLACE FUNCTION approve_content_asset(p_asset_id uuid) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_fact text;
  v_comp text;
BEGIN
  v_fact := run_content_fact_gate(p_asset_id);
  IF v_fact = 'PASSED' THEN
    v_comp := run_compliance_gate(p_asset_id);
  ELSE
    v_comp := 'BLOCKED';
  END IF;
  RETURN jsonb_build_object('fact_check', v_fact, 'compliance', v_comp);
END;
$$;

-- Rebuild store_content_asset: never stamp VERIFIED / quality 100. The LLM draft
-- is stored as DRAFT with fact_check_status=PENDING; the fact+compliance gates
-- decide READY_TO_PUBLISH. This removes the VERIFIED leak.
CREATE OR REPLACE FUNCTION store_content_asset(
  p_client_code text,
  p_brief_id uuid,
  p_surface_id uuid,
  p_format text,
  p_title text,
  p_body text,
  p_model text DEFAULT NULL,
  p_tokens_in integer DEFAULT NULL,
  p_tokens_out integer DEFAULT NULL,
  p_latency_ms integer DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_client uuid;
  v_brief content_briefs%ROWTYPE;
  v_claim_ids uuid[];
  v_verified_count int;
  v_asset uuid;
  v_surface_cid uuid;
BEGIN
  SELECT id INTO v_client FROM clients WHERE code = p_client_code;
  IF v_client IS NULL THEN
    RAISE EXCEPTION 'client % not found', p_client_code;
  END IF;

  SELECT * INTO v_brief FROM content_briefs
    WHERE id = p_brief_id AND client_id = v_client;
  IF v_brief IS NULL THEN
    RAISE EXCEPTION 'brief % not found for client %', p_brief_id, p_client_code;
  END IF;

  -- P0.9: surface (if any) must belong to the same client.
  IF p_surface_id IS NOT NULL THEN
    SELECT client_id INTO v_surface_cid FROM surfaces WHERE id = p_surface_id;
    IF v_surface_cid IS DISTINCT FROM v_client THEN
      PERFORM raise_exception(v_client, 'CROSS_CLIENT_REFERENCE', 'CRITICAL',
        'Cross-client surface reference blocked',
        'surface ' || p_surface_id::text || ' does not belong to client ' || p_client_code,
        NULL, 'surface', p_surface_id);
      RETURN NULL;
    END IF;
  END IF;

  -- Fact QA: the brief must stand only on VERIFIED claims.
  SELECT ARRAY(SELECT jsonb_array_elements_text(v_brief.required_claim_ids)::uuid)
    INTO v_claim_ids;
  SELECT count(*) INTO v_verified_count FROM claims
    WHERE id = ANY(v_claim_ids) AND verification = 'VERIFIED';
  IF array_length(v_claim_ids,1) IS NOT NULL AND v_verified_count <> array_length(v_claim_ids, 1) THEN
    PERFORM raise_exception(
      v_client, 'FACT_CONFLICT', 'HIGH',
      'Content asset blocked: required claim not VERIFIED',
      'Brief ' || p_brief_id::text || ' references a non-VERIFIED claim.',
      NULL, 'CONTENT_ASSET', NULL);
    RETURN NULL;
  END IF;

  INSERT INTO content_assets(client_id, brief_id, surface_id, format,
                             title, body, media_refs, claim_ids,
                             fact_check_status, compliance_status, quality_score,
                             status, model_provider, model_name, dedup_key)
  VALUES (v_client, v_brief.id, p_surface_id, p_format, p_title, p_body,
          '[]'::jsonb, v_brief.required_claim_ids,
          'PENDING', 'PENDING', NULL, 'DRAFT', 'ollama', p_model,
          'asset:' || v_brief.id::text || ':' || COALESCE(p_surface_id::text,'canonical'))
  ON CONFLICT (dedup_key) WHERE dedup_key IS NOT NULL DO NOTHING
  RETURNING id INTO v_asset;
  IF v_asset IS NOT NULL THEN
    PERFORM record_llm_run(p_client_code, 'CONTENT_GENERATION', 'ollama',
      COALESCE(p_model, 'qwen2.5'), 'wf06-v1', v_brief.canonical_angle,
      NULL, NULL, p_tokens_in, p_tokens_out, NULL, p_latency_ms);
  END IF;

  RETURN v_asset;
END;
$$;

-- Rebuild generate_content_asset to the same contract (DRAFT / PENDING, no
-- quality 100). Deterministic assembly is still gated before publication.
CREATE OR REPLACE FUNCTION generate_content_asset(
  p_client_code text,
  p_brief_id uuid,
  p_format text,
  p_surface_id uuid DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_client uuid;
  v_brief content_briefs%ROWTYPE;
  v_asset uuid;
  v_claim_ids uuid[];
  v_verified_count int;
  v_body text := '';
  r RECORD;
BEGIN
  SELECT id INTO v_client FROM clients WHERE code = p_client_code;
  IF v_client IS NULL THEN
    RAISE EXCEPTION 'client % not found', p_client_code;
  END IF;

  SELECT * INTO v_brief FROM content_briefs
    WHERE id = p_brief_id AND client_id = v_client;
  IF v_brief IS NULL THEN
    RAISE EXCEPTION 'brief % not found for client %', p_brief_id, p_client_code;
  END IF;
  IF v_brief.status <> 'READY' THEN
    RAISE EXCEPTION 'brief % is not READY (status=%)', p_brief_id, v_brief.status;
  END IF;

  SELECT ARRAY(SELECT jsonb_array_elements_text(v_brief.required_claim_ids)::uuid)
    INTO v_claim_ids;
  SELECT count(*) INTO v_verified_count FROM claims
    WHERE id = ANY(v_claim_ids) AND verification = 'VERIFIED';
  IF array_length(v_claim_ids,1) IS NOT NULL AND v_verified_count <> array_length(v_claim_ids, 1) THEN
    PERFORM raise_exception(
      v_client, 'FACT_CONFLICT', 'HIGH',
      'Content asset blocked: required claim not VERIFIED',
      'Brief ' || p_brief_id::text || ' references a non-VERIFIED claim.',
      NULL, 'CONTENT_ASSET', NULL);
    RETURN NULL;
  END IF;

  FOR r IN
    SELECT c.field_key, c.claim_text FROM claims c
    WHERE c.id = ANY(v_claim_ids)
    ORDER BY c.field_key
  LOOP
    v_body := v_body || '- ' || r.claim_text || E'\n';
  END LOOP;

  INSERT INTO content_assets(client_id, brief_id, surface_id, format,
                             title, body, media_refs, claim_ids,
                             fact_check_status, compliance_status, quality_score,
                             status, model_provider, dedup_key)
  VALUES (v_client, v_brief.id, p_surface_id, p_format,
          v_brief.canonical_angle, v_body, '[]'::jsonb,
          v_brief.required_claim_ids,
          'PENDING', 'PENDING', NULL, 'DRAFT', 'ollama',
          'asset:' || v_brief.id::text || ':' || COALESCE(p_surface_id::text,'canonical'))
  ON CONFLICT (dedup_key) WHERE dedup_key IS NOT NULL DO NOTHING
  RETURNING id INTO v_asset;

  RETURN v_asset;
END;
$$;

-- ============================================================================
-- P0.7 — Remove simulated AUTO_API publish
-- AUTO_API is only real when an official, enabled adapter produces a real
-- provider response. Without one, the task routes to MANUAL_REQUIRED, never a
-- fabricated PUBLISHED. complete_publication() is the single real path that
-- records genuine provider response before marking PUBLISHED.
-- ============================================================================
CREATE OR REPLACE FUNCTION complete_publication(
  p_task_id uuid,
  p_external_id text,
  p_url text,
  p_provider_response jsonb DEFAULT NULL,
  p_published_at timestamptz DEFAULT now()
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_task publication_tasks%ROWTYPE;
  v_surface surfaces%ROWTYPE;
  v_rec uuid;
BEGIN
  SELECT * INTO v_task FROM publication_tasks WHERE id = p_task_id;
  IF v_task IS NULL THEN
    RAISE EXCEPTION 'publication task % not found', p_task_id;
  END IF;
  -- Fail closed: only a PUBLISHING task may be completed, and only with a real
  -- provider external id (never a fabricated one).
  IF v_task.status <> 'PUBLISHING' THEN
    RAISE EXCEPTION 'cannot complete task % in status %', p_task_id, v_task.status;
  END IF;
  IF p_external_id IS NULL OR p_external_id = '' OR p_external_id LIKE 'ext-%' THEN
    RAISE EXCEPTION 'refusing fabricated provider external_id for task %', p_task_id;
  END IF;

  SELECT * INTO v_surface FROM surfaces WHERE id = v_task.surface_id;
  INSERT INTO publication_records(client_id, publication_task_id, platform,
                                  external_id, url, published_at, verification_status,
                                  provider_response, dedup_key)
  VALUES (v_task.client_id, v_task.id, v_surface.platform,
          p_external_id, p_url, p_published_at, 'PENDING',
          jsonb_build_object('simulated', false) || COALESCE(p_provider_response,'{}'::jsonb),
          'pubrec:' || v_task.id::text)
  ON CONFLICT (dedup_key) WHERE dedup_key IS NOT NULL DO NOTHING
  RETURNING id INTO v_rec;

  UPDATE publication_tasks SET status='PUBLISHED', updated_at=now() WHERE id=p_task_id;
  RETURN v_rec;
END;
$$;

CREATE OR REPLACE FUNCTION dispatch_publication(p_task_id uuid) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_task publication_tasks%ROWTYPE;
  v_surface surfaces%ROWTYPE;
  v_adapter publication_adapters%ROWTYPE;
  v_outcome text;
  v_hint text;
BEGIN
  SELECT * INTO v_task FROM publication_tasks WHERE id = p_task_id;
  IF v_task IS NULL THEN
    RAISE EXCEPTION 'publication task % not found', p_task_id;
  END IF;
  SELECT * INTO v_surface FROM surfaces WHERE id = v_task.surface_id;

  -- AUTO_API: real provider request only. No official/enabled adapter + real
  -- credential => route to MANUAL_REQUIRED (never simulated PUBLISHED).
  IF v_task.mode = 'AUTO_API' THEN
    SELECT * INTO v_adapter FROM publication_adapters
      WHERE platform = v_surface.platform AND capability = 'PUBLISH';
    IF v_adapter.id IS NULL OR NOT v_adapter.official OR NOT v_adapter.enabled THEN
      v_hint := 'No official, enabled adapter for platform ' || v_surface.platform
        || '; AUTO_API unavailable. Route to manual/assisted.';
      IF NOT EXISTS (SELECT 1 FROM exceptions
                     WHERE exception_type='UNSUPPORTED_PLATFORM'
                       AND related_object_id=v_task.id AND status='OPEN') THEN
        PERFORM raise_exception(v_task.client_id, 'UNSUPPORTED_PLATFORM', 'HIGH',
          'AUTO_API unavailable: adapter not official/enabled', v_hint,
          NULL, 'PUBLICATION_TASK', v_task.id);
      END IF;
      UPDATE publication_tasks
        SET status='WAITING_APPROVAL', mode='MANUAL_REQUIRED', last_error=v_hint,
            payload_json = payload_json || jsonb_build_object('outcome','MANUAL_REQUIRED')
        WHERE id=p_task_id;
      RETURN jsonb_build_object('mode', 'MANUAL_REQUIRED', 'outcome', 'MANUAL_REQUIRED');
    END IF;
    IF v_task.credential_ref IS NULL OR NOT EXISTS (
        SELECT 1 FROM client_credentials
        WHERE client_id=v_task.client_id AND provider=v_surface.platform
          AND credential_ref=v_task.credential_ref AND status='ACTIVE') THEN
      v_hint := 'Missing/inactive credential for ' || v_surface.platform;
      IF NOT EXISTS (SELECT 1 FROM exceptions
                     WHERE exception_type='CREDENTIAL_INVALID'
                       AND related_object_id=v_task.id AND status='OPEN') THEN
        PERFORM raise_exception(v_task.client_id, 'CREDENTIAL_INVALID', 'HIGH',
          'AUTO_API blocked: credential missing/inactive', v_hint,
          NULL, 'PUBLICATION_TASK', v_task.id);
      END IF;
      UPDATE publication_tasks
        SET status='WAITING_APPROVAL', mode='MANUAL_REQUIRED', last_error=v_hint,
            payload_json = payload_json || jsonb_build_object('outcome','MANUAL_REQUIRED')
        WHERE id=p_task_id;
      RETURN jsonb_build_object('mode', 'MANUAL_REQUIRED', 'outcome', 'MANUAL_REQUIRED');
    END IF;
    -- Official capability + credential present: drive a REAL provider request.
    -- The adapter is responsible for calling the provider and calling
    -- complete_publication() with the genuine response. No simulated insert here.
    UPDATE publication_tasks SET status='PUBLISHING' WHERE id=p_task_id;
    RETURN jsonb_build_object('mode', 'AUTO_API', 'outcome', 'PUBLISHING',
      'hint', 'adapter must produce a real provider response and call complete_publication()');
  END IF;

  IF v_task.mode IN ('API_ASSISTED','BROWSER_ASSISTED','MANUAL_REQUIRED') THEN
    UPDATE publication_tasks
      SET status='WAITING_APPROVAL',
          payload_json = payload_json || jsonb_build_object(
            'mode', v_task.mode,
            'note', v_task.mode || ': requires human/assisted action, not automated bypass')
      WHERE id = p_task_id;
    RETURN jsonb_build_object('mode', v_task.mode, 'outcome', 'WAITING_APPROVAL');
  END IF;

  IF v_task.mode = 'BLOCKED' THEN
    v_hint := 'Platform policy forbids automated publication';
    IF NOT EXISTS (SELECT 1 FROM exceptions
                   WHERE exception_type='PLATFORM_POLICY'
                     AND related_object_id=v_task.id AND status='OPEN') THEN
      PERFORM raise_exception(v_task.client_id, 'PLATFORM_POLICY', 'HIGH',
        'Publication blocked by platform policy', v_hint,
        NULL, 'PUBLICATION_TASK', v_task.id);
    END IF;
    UPDATE publication_tasks SET status='BLOCKED', last_error=v_hint WHERE id=p_task_id;
    RETURN jsonb_build_object('mode', 'BLOCKED', 'outcome', 'BLOCKED');
  END IF;

  RETURN jsonb_build_object('mode', v_task.mode, 'outcome', 'UNKNOWN');
END;
$$;

-- ============================================================================
-- P0.8 — Job lease recovery
-- A RUNNING job whose lease expires must become reclaimable (worker crash),
-- and retry/backoff bookkeeping is made explicit. claim_next_job now reclaims
-- expired RUNNING leases; recover_expired_leases() flips them back to PENDING
-- without counting a new attempt (retry bookkeeping).
-- ============================================================================
CREATE OR REPLACE FUNCTION claim_next_job(
  p_worker text,
  p_lease_seconds integer DEFAULT 600,
  p_job_type text DEFAULT NULL
) RETURNS jobs
LANGUAGE plpgsql AS $$
DECLARE
  v_job jobs;
BEGIN
  UPDATE jobs SET
    status = 'RUNNING',
    started_at = COALESCE(started_at, now()),
    attempts = attempts + 1,
    lease_until = now() + make_interval(secs => p_lease_seconds)
  WHERE id = (
    SELECT id FROM jobs
    WHERE status IN ('PENDING','RETRY_WAIT','RUNNING')
      AND due_at <= now()
      AND (lease_until IS NULL OR lease_until < now())
      AND (p_job_type IS NULL OR job_type = p_job_type)
    ORDER BY priority DESC, due_at ASC
    LIMIT 1
    FOR UPDATE SKIP LOCKED
  )
  RETURNING * INTO v_job;

  RETURN v_job;
END;
$$;

-- Flip expired RUNNING leases back to PENDING WITHOUT incrementing attempts
-- (a lease expiry is not a worker failure). Returns count recovered.
CREATE OR REPLACE FUNCTION recover_expired_leases() RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  n int;
BEGIN
  UPDATE jobs SET
    status = 'PENDING',
    lease_until = NULL,
    last_error = CASE WHEN last_error IS NULL THEN
      'lease expired; recovered for reclaim'
      ELSE last_error || '; lease expired; recovered' END
  WHERE status = 'RUNNING' AND lease_until IS NOT NULL AND lease_until < now();
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END;
$$;

-- ============================================================================
-- P0.9 + idempotency — make raise_exception idempotent on open exceptions.
-- The partial unique index (exception_type, related_object_id) WHERE OPEN would
-- otherwise make the same fail-closed exception a hard error on a re-run. If an
-- OPEN exception for the same (type, object) already exists, return its id and
-- refresh the severity/title instead of raising a duplicate-key error.
-- ============================================================================
CREATE OR REPLACE FUNCTION raise_exception(
  p_client_id uuid,
  p_exception_type text,
  p_severity exception_severity,
  p_title text,
  p_detail text DEFAULT NULL,
  p_source_job_id uuid DEFAULT NULL,
  p_related_object_type text DEFAULT NULL,
  p_related_object_id uuid DEFAULT NULL,
  p_due_at timestamptz DEFAULT now()
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_id uuid;
BEGIN
  SELECT id INTO v_id FROM exceptions
    WHERE exception_type = p_exception_type
      AND related_object_id IS NOT DISTINCT FROM p_related_object_id
      AND status = 'OPEN'
    LIMIT 1;
  IF v_id IS NOT NULL THEN
    UPDATE exceptions SET severity = p_severity, title = p_title,
      detail = COALESCE(p_detail, detail), due_at = p_due_at
    WHERE id = v_id;
    RETURN v_id;
  END IF;
  INSERT INTO exceptions(client_id, exception_type, severity, title, detail,
                         source_job_id, related_object_type, related_object_id, due_at)
  VALUES (p_client_id, p_exception_type, p_severity, p_title, p_detail,
          p_source_job_id, p_related_object_type, p_related_object_id, p_due_at)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

-- ============================================================================
-- P0.9 — Multi-client isolation on the remaining cross-object operators
-- ============================================================================

-- adapt_content_for_surface: now client-scoped. The base asset and the target
-- surface must belong to the SAME client, else fail closed.
CREATE OR REPLACE FUNCTION adapt_content_for_surface(
  p_client_code text,
  p_base_asset_id uuid,
  p_surface_id uuid,
  p_format text
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_client uuid;
  v_base content_assets%ROWTYPE;
  v_surface_cid uuid;
  v_asset uuid;
BEGIN
  SELECT id INTO v_client FROM clients WHERE code = p_client_code;
  IF v_client IS NULL THEN
    RAISE EXCEPTION 'client % not found', p_client_code;
  END IF;

  SELECT * INTO v_base FROM content_assets WHERE id = p_base_asset_id;
  IF v_base IS NULL THEN
    RAISE EXCEPTION 'base asset % not found', p_base_asset_id;
  END IF;
  IF v_base.client_id <> v_client THEN
    PERFORM raise_exception(v_client, 'CROSS_CLIENT_REFERENCE', 'CRITICAL',
      'Cross-client asset reference blocked',
      'base asset ' || p_base_asset_id::text || ' does not belong to client ' || p_client_code,
      NULL, 'CONTENT_ASSET', p_base_asset_id);
    RETURN NULL;
  END IF;

  SELECT client_id INTO v_surface_cid FROM surfaces WHERE id = p_surface_id;
  IF v_surface_cid IS DISTINCT FROM v_client THEN
    PERFORM raise_exception(v_client, 'CROSS_CLIENT_REFERENCE', 'CRITICAL',
      'Cross-client surface reference blocked',
      'surface ' || p_surface_id::text || ' does not belong to client ' || p_client_code,
      NULL, 'surface', p_surface_id);
    RETURN NULL;
  END IF;

  INSERT INTO content_assets(client_id, brief_id, surface_id, format,
                             title, body, media_refs, claim_ids,
                             fact_check_status, compliance_status, quality_score,
                             status, model_provider, dedup_key)
  VALUES (v_base.client_id, v_base.brief_id, p_surface_id, p_format,
          v_base.title, v_base.body, v_base.media_refs, v_base.claim_ids,
          v_base.fact_check_status, v_base.compliance_status, v_base.quality_score,
          'READY', v_base.model_provider,
          'asset:' || v_base.brief_id::text || ':' || p_surface_id::text)
  ON CONFLICT (dedup_key) WHERE dedup_key IS NOT NULL DO NOTHING
  RETURNING id INTO v_asset;

  RETURN v_asset;
END;
$$;

-- refresh_engine_surface_profiles: optional client scope so a caller can never
-- accidentally aggregate the wrong tenant into a profile.
CREATE OR REPLACE FUNCTION refresh_engine_surface_profiles(
  p_engine_id uuid,
  p_observed_from date,
  p_observed_until date DEFAULT NULL,
  p_client_code text DEFAULT NULL
) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  v_until date := COALESCE(p_observed_until, CURRENT_DATE);
  v_client uuid;
  v_region text;
  v_lang text;
  v_surface_type text;
  v_ev_count int;
  v_mention numeric;
  v_confidence numeric;
  n int := 0;
BEGIN
  IF p_client_code IS NOT NULL THEN
    SELECT id INTO v_client FROM clients WHERE code = p_client_code;
  END IF;

  FOR v_region, v_lang, v_surface_type, v_ev_count, v_mention IN
    SELECT e.region, e.language, s.surface_type,
           count(*)::int,
           round((count(*) FILTER (WHERE o.target_recommended)::numeric
                  / NULLIF(count(*)::numeric,0)), 4)
    FROM engine_observations o
    JOIN engines e ON e.id = o.engine_id
    LEFT JOIN LATERAL (
      SELECT (sid #>> '{}')::uuid AS sid_id
      FROM jsonb_array_elements(o.cited_surface_ids) AS sid
    ) u ON true
    LEFT JOIN surfaces s ON s.id = u.sid_id
    WHERE o.engine_id = p_engine_id
      AND (v_client IS NULL OR o.client_id = v_client)
      AND o.observed_at::date BETWEEN p_observed_from AND v_until
      AND s.surface_type IS NOT NULL
    GROUP BY e.region, e.language, s.surface_type
  LOOP
    v_confidence := round(least(1.0, v_ev_count::numeric / 10.0), 4);
    INSERT INTO engine_surface_profiles(engine_id, surface_type, region, language,
      observed_from, observed_until, evidence_count, confidence, findings)
    VALUES (p_engine_id, v_surface_type, v_region, v_lang,
      p_observed_from, v_until, v_ev_count, v_confidence,
      jsonb_build_object('target_recommend_rate', v_mention))
    ON CONFLICT (engine_id, surface_type, COALESCE(region,''), COALESCE(language,''),
                 observed_from, observed_until)
    DO UPDATE SET evidence_count = EXCLUDED.evidence_count,
                  confidence = EXCLUDED.confidence,
                  findings = EXCLUDED.findings,
                  updated_at = now();
    n := n + 1;
  END LOOP;

  RETURN n;
END;
$$;

-- ============================================================================
-- P0.2 — Truth document parsing (TXT / MD / CSV) + evidence locator
-- A document must actually be parsed (content extracted) before any claim may
-- be derived from it. LLM claim extraction is only allowed over real content.
-- PDF / WEBPAGE without a pre-extracted content blob are explicitly
-- NOT_SUPPORTED / PARSE_FAILED and fail closed (never pretend they were parsed).
-- ============================================================================
ALTER TABLE truth_documents ADD COLUMN IF NOT EXISTS content text;
ALTER TABLE truth_documents ADD COLUMN IF NOT EXISTS parser text;
ALTER TABLE claims ADD COLUMN IF NOT EXISTS evidence_locator jsonb;
ALTER TABLE evidence_items ADD COLUMN IF NOT EXISTS section text;
ALTER TABLE evidence_items ADD COLUMN IF NOT EXISTS page integer;
ALTER TABLE evidence_items ADD COLUMN IF NOT EXISTS table_ref text;
ALTER TABLE evidence_items ADD COLUMN IF NOT EXISTS row_ref integer;

-- Parse a truth document's content. Supported: TXT / MARKDOWN / CSV.
-- Returns { parsed, sections, rows, format } or raises PARSE_FAILED.
CREATE OR REPLACE FUNCTION parse_truth_document(
  p_client_code text,
  p_document_id uuid,
  p_content text,
  p_format text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_client uuid;
  v_doc truth_documents%ROWTYPE;
  v_fmt text;
  v_rows int := 0;
  v_sections int := 0;
  v_parse jsonb;
  v_meta jsonb;
BEGIN
  SELECT id INTO v_client FROM clients WHERE code = p_client_code;
  IF v_client IS NULL THEN
    RAISE EXCEPTION 'client % not found', p_client_code;
  END IF;
  SELECT * INTO v_doc FROM truth_documents
    WHERE id = p_document_id AND client_id = v_client;
  IF v_doc IS NULL THEN
    RAISE EXCEPTION 'document % not found for client %', p_document_id, p_client_code;
  END IF;

  v_fmt := upper(COALESCE(p_format, v_doc.document_type, 'TXT'));

  -- Fail closed: unsupported formats without a usable content blob.
  IF v_fmt IN ('PDF','WEBPAGE','URL','DOCX','XLSX') AND (p_content IS NULL OR trim(p_content)='') THEN
    PERFORM raise_exception(v_client, 'PARSE_FAILED', 'HIGH',
      'Document format not natively parseable', 
      'document ' || p_document_id::text || ' (' || v_fmt ||
        ') requires an external extractor; provide pre-extracted text or route to MANUAL_OBSERVATION.',
      NULL, 'TRUTH_DOCUMENT', v_doc.id);
    UPDATE truth_documents SET status='PARSE_FAILED', parser = v_fmt
      WHERE id = v_doc.id;
    RETURN jsonb_build_object('parsed', false, 'reason', 'format_not_supported');
  END IF;

  IF p_content IS NULL OR trim(p_content) = '' THEN
    PERFORM raise_exception(v_client, 'CLIENT_DATA_REQUIRED', 'MEDIUM',
      'Document has no content to parse',
      'document ' || p_document_id::text || ' (' || v_fmt || ') has no content.',
      NULL, 'TRUTH_DOCUMENT', v_doc.id);
    RETURN jsonb_build_object('parsed', false, 'reason', 'no_content');
  END IF;

  IF v_fmt = 'CSV' THEN
    -- Count data rows (ignoring a header row when present).
    v_rows := greatest(array_length(string_to_array(p_content, E'\n'),1) - 1, 1);
    v_parse := jsonb_build_object('format','CSV','rows', v_rows);
  ELSE
    -- TXT / MARKDOWN: count non-empty lines as sections.
    v_sections := count_lines(p_content);
    v_parse := jsonb_build_object('format','TXT','sections', v_sections);
  END IF;

  v_meta := v_doc.metadata || jsonb_build_object(
    'parsed_segments',
    CASE WHEN v_fmt='CSV' THEN v_rows ELSE v_sections END,
    'parser', v_fmt);

  UPDATE truth_documents SET
    content = p_content,
    parser = v_fmt,
    status = 'PARSED',
    parsed_at = now(),
    metadata = v_meta
    WHERE id = v_doc.id;

  RETURN v_parse || jsonb_build_object('parsed', true, 'document_id', v_doc.id);
END;
$$;

-- Count non-empty logical lines ("sections") in a text blob.
CREATE OR REPLACE FUNCTION count_lines(p_text text) RETURNS int
LANGUAGE sql IMMUTABLE AS $$
  SELECT count(*)::int FROM unnest(string_to_array(COALESCE(p_text,''), E'\n')) AS s
  WHERE trim(s) <> '';
$$;

-- ============================================================================
-- P0.6 + P0.7 — align publication queue with the fact/compliance gate.
-- create_publication_task (from 009) required status='READY', but the new
-- gate marks a passed asset READY_TO_PUBLISH. Re-open the queue to both.
-- compute_period_metrics (from 010) counted only 'READY' assets; include
-- READY_TO_PUBLISH so a gated asset is visible in reports.
-- ============================================================================
CREATE OR REPLACE FUNCTION create_publication_task(
  p_client_code text,
  p_asset_id uuid,
  p_surface_id uuid
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_client uuid;
  v_asset content_assets%ROWTYPE;
  v_surface surfaces%ROWTYPE;
  v_task uuid;
BEGIN
  SELECT id INTO v_client FROM clients WHERE code = p_client_code;
  IF v_client IS NULL THEN
    RAISE EXCEPTION 'client % not found', p_client_code;
  END IF;

  SELECT * INTO v_asset FROM content_assets
    WHERE id = p_asset_id AND client_id = v_client;
  IF v_asset IS NULL THEN
    RAISE EXCEPTION 'asset % not found for client %', p_asset_id, p_client_code;
  END IF;
  -- Only a fact+compliance PASSED asset may enter the publication queue.
  IF v_asset.status NOT IN ('READY','READY_TO_PUBLISH') THEN
    RAISE EXCEPTION 'asset % is not publication-ready (status=%)', p_asset_id, v_asset.status;
  END IF;

  SELECT * INTO v_surface FROM surfaces
    WHERE id = p_surface_id AND client_id = v_client;
  IF v_surface IS NULL THEN
    RAISE EXCEPTION 'surface % not found for client %', p_surface_id, p_client_code;
  END IF;

  INSERT INTO publication_tasks(client_id, content_asset_id, surface_id, mode,
                                status, scheduled_for, credential_ref, payload_json,
                                dedup_key)
  VALUES (v_client, v_asset.id, v_surface.id, v_surface.publication_mode,
          'DRAFT', now(), v_surface.credential_ref,
          jsonb_build_object('title', v_asset.title, 'body', v_asset.body,
                             'format', v_asset.format),
          'pubtask:' || v_asset.id::text || ':' || v_surface.id::text)
  ON CONFLICT (dedup_key) WHERE dedup_key IS NOT NULL DO NOTHING
  RETURNING id INTO v_task;

  RETURN v_task;
END;
$$;

CREATE OR REPLACE FUNCTION compute_period_metrics(
  p_client_code text,
  p_period_start date,
  p_period_end date
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_client uuid;
  v_past_start date := p_period_start - (p_period_end - p_period_start);
  v_obs int; v_mentioned int; v_recommended int;
  v_mention_rate numeric; v_recommend_rate numeric;
  v_avg_position numeric;
  v_prev_obs int; v_prev_mentioned int;
  v_prev_mention_rate numeric;
  v_verified int; v_assets int; v_published int;
  v_mention_delta numeric;
BEGIN
  SELECT id INTO v_client FROM clients WHERE code = p_client_code;
  IF v_client IS NULL THEN
    RAISE EXCEPTION 'client % not found', p_client_code;
  END IF;

  SELECT count(*), count(*) FILTER (WHERE target_mentioned),
         count(*) FILTER (WHERE target_recommended),
         COALESCE(round(avg(position_hint) FILTER (WHERE position_hint IS NOT NULL),2),0)
    INTO v_obs, v_mentioned, v_recommended, v_avg_position
    FROM engine_observations
    WHERE client_id = v_client
      AND observed_at::date BETWEEN p_period_start AND p_period_end;

  SELECT count(*), count(*) FILTER (WHERE target_mentioned)
    INTO v_prev_obs, v_prev_mentioned
    FROM engine_observations
    WHERE client_id = v_client
      AND observed_at::date BETWEEN v_past_start AND (p_period_start - 1);

  v_mention_rate := round(v_mentioned::numeric / NULLIF(v_obs,0), 4);
  v_recommend_rate := round(v_recommended::numeric / NULLIF(v_obs,0), 4);
  v_prev_mention_rate := round(v_prev_mentioned::numeric / NULLIF(v_prev_obs,0), 4);
  v_mention_delta := round(v_mention_rate - v_prev_mention_rate, 4);

  SELECT count(*) INTO v_verified FROM claims
    WHERE client_id = v_client AND verification = 'VERIFIED';
  SELECT count(*) INTO v_assets FROM content_assets
    WHERE client_id = v_client AND status IN ('READY','READY_TO_PUBLISH');
  SELECT count(*) INTO v_published FROM publication_tasks
    WHERE client_id = v_client AND status = 'PUBLISHED';

  RETURN jsonb_build_object(
    'period_start', p_period_start, 'period_end', p_period_end,
    'observations', v_obs,
    'target_mentioned', v_mentioned,
    'mention_rate', v_mention_rate,
    'target_recommended', v_recommended,
    'recommend_rate', v_recommend_rate,
    'avg_position', v_avg_position,
    'prev_observations', v_prev_obs,
    'prev_mention_rate', v_prev_mention_rate,
    'mention_delta', v_mention_delta,
    'verified_claims', v_verified,
    'ready_assets', v_assets,
    'published', v_published);
END;
$$;