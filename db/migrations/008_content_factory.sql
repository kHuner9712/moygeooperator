-- ============================================================================
-- MOY GEO Operator · Migration 008 · Stage 6 · Content Factory (WF-06)
-- Canonical Brief, generate-from-VERIFIED-claims-only, fact QA, surface
-- adaptation, and ContentAsset. LLM cannot fabricate canonical facts: every
-- body is assembled from VERIFIED claims only, and any brief that requires a
-- non-VERIFIED claim fails closed (BLOCKED asset + exception).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Idempotency keys (deterministic; retry-safe for expensive LLM generation).
-- ---------------------------------------------------------------------------
ALTER TABLE content_briefs ADD COLUMN IF NOT EXISTS dedup_key text;
ALTER TABLE content_assets ADD COLUMN IF NOT EXISTS dedup_key text;

CREATE UNIQUE INDEX IF NOT EXISTS uq_content_briefs_dedup
  ON content_briefs(dedup_key) WHERE dedup_key IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_content_assets_dedup
  ON content_assets(dedup_key) WHERE dedup_key IS NOT NULL;

-- ============================================================================
-- create_content_brief — build the canonical brief for a CONTENT_CREATION
-- action: resolve intent/entity, scope required claims to VERIFIED only,
-- collect active target surfaces, set the canonical angle.
-- Idempotent per action. Fails closed if the target has no VERIFIED claim.
-- ============================================================================
CREATE OR REPLACE FUNCTION create_content_brief(
  p_client_code text,
  p_action_id uuid
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_client uuid;
  v_action geo_actions%ROWTYPE;
  v_entity uuid;
  v_brief uuid;
  v_verified jsonb;
  v_surfaces jsonb;
  v_angle text;
BEGIN
  SELECT id INTO v_client FROM clients WHERE code = p_client_code;
  IF v_client IS NULL THEN
    RAISE EXCEPTION 'client % not found', p_client_code;
  END IF;

  SELECT * INTO v_action FROM geo_actions
    WHERE id = p_action_id AND client_id = v_client;
  IF v_action IS NULL THEN
    RAISE EXCEPTION 'action % not found for client %', p_action_id, p_client_code;
  END IF;

  -- Resolve target entity from the action's intent.
  SELECT i.entity_id INTO v_entity
    FROM intents i WHERE i.id = v_action.target_intent_id;
  IF v_entity IS NULL THEN
    RAISE EXCEPTION 'action % has no resolvable target entity', p_action_id;
  END IF;

  -- Fail closed: content cannot be authored without >=1 VERIFIED claim.
  SELECT COALESCE(jsonb_agg(c.id ORDER BY c.field_key), '[]'::jsonb)
    INTO v_verified
    FROM claims c
    WHERE c.entity_id = v_entity AND c.verification = 'VERIFIED';
  IF jsonb_array_length(v_verified) = 0 THEN
    PERFORM raise_exception(
      v_client, 'CLIENT_DATA_REQUIRED', 'HIGH',
      'Content brief blocked: no VERIFIED claims',
      'Cannot build a canonical brief for intent ' || COALESCE(v_action.title, '?')
        || ' — it has no VERIFIED canonical facts.',
      NULL, 'CONTENT_BRIEF', NULL);
    RETURN NULL;
  END IF;

  -- Target surfaces owned by the entity and active.
  SELECT COALESCE(jsonb_agg(s.id ORDER BY s.platform), '[]'::jsonb)
    INTO v_surfaces
    FROM surfaces s
    WHERE s.client_id = v_client AND s.owner_entity_id = v_entity AND s.active;

  SELECT COALESCE(i.description, i.label, 'Canonical content') INTO v_angle
    FROM intents i WHERE i.id = v_action.target_intent_id;

  INSERT INTO content_briefs(client_id, action_id, intent_id, target_entity_id,
                             canonical_angle, required_claim_ids, prohibited_claims,
                             target_surfaces, status, dedup_key)
  VALUES (v_client, v_action.id, v_action.target_intent_id, v_entity,
          v_angle, v_verified, '[]'::jsonb, v_surfaces, 'READY',
          'brief:' || v_action.id::text)
  ON CONFLICT (dedup_key) WHERE dedup_key IS NOT NULL DO NOTHING
  RETURNING id INTO v_brief;

  RETURN v_brief;
END;
$$;

-- ============================================================================
-- generate_content_asset — produce a ContentAsset from a READY brief, using
-- ONLY the brief's VERIFIED required claims. Fact QA: any required claim that
-- is not VERIFIED blocks the asset (fail closed). Returns the asset id.
-- ============================================================================
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

  -- Fact QA: the brief must only reference VERIFIED claims.
  SELECT ARRAY(SELECT jsonb_array_elements_text(v_brief.required_claim_ids)::uuid)
    INTO v_claim_ids;
  SELECT count(*) INTO v_verified_count FROM claims
    WHERE id = ANY(v_claim_ids) AND verification = 'VERIFIED';
  IF v_verified_count <> array_length(v_claim_ids, 1) THEN
    PERFORM raise_exception(
      v_client, 'FACT_CONFLICT', 'HIGH',
      'Content asset blocked: required claim not VERIFIED',
      'Brief ' || p_brief_id::text || ' references a non-VERIFIED claim.',
      NULL, 'CONTENT_ASSET', NULL);
    RETURN NULL;
  END IF;

  -- Deterministic body assembled ONLY from the VERIFIED canonical claims.
  -- (The WF-06 workflow may then run Ollama adaptation on this VERIFIED base.)
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
          'VERIFIED', 'PENDING', 100.0, 'READY', 'ollama',
          'asset:' || v_brief.id::text || ':' || COALESCE(p_surface_id::text,'canonical'))
  ON CONFLICT (dedup_key) WHERE dedup_key IS NOT NULL DO NOTHING
  RETURNING id INTO v_asset;

  RETURN v_asset;
END;
$$;

-- ============================================================================
-- adapt_content_for_surface — copy a VERIFIED base asset into a per-surface
-- variant (format/surface-specific). Idempotent per (base_asset, surface).
-- ============================================================================
CREATE OR REPLACE FUNCTION adapt_content_for_surface(
  p_base_asset_id uuid,
  p_surface_id uuid,
  p_format text
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_base content_assets%ROWTYPE;
  v_asset uuid;
BEGIN
  SELECT * INTO v_base FROM content_assets WHERE id = p_base_asset_id;
  IF v_base IS NULL THEN
    RAISE EXCEPTION 'base asset % not found', p_base_asset_id;
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

-- ============================================================================
-- store_content_asset — persist a WF-06 Ollama-generated asset. Same Fact QA
-- gate as generate_content_asset (only VERIFIED claims may be sourced), but the
-- body/title come from the LLM rather than a deterministic assembly. Idempotent
-- per (brief, surface). Records the LLM run for observability.
-- ============================================================================
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

  -- Fact QA: the brief (and thus the asset) must stand only on VERIFIED claims.
  SELECT ARRAY(SELECT jsonb_array_elements_text(v_brief.required_claim_ids)::uuid)
    INTO v_claim_ids;
  SELECT count(*) INTO v_verified_count FROM claims
    WHERE id = ANY(v_claim_ids) AND verification = 'VERIFIED';
  IF v_verified_count <> array_length(v_claim_ids, 1) THEN
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
          'VERIFIED', 'PENDING', 100.0, 'READY', 'ollama', p_model,
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

-- ============================================================================
-- record_llm_run — audit helper for the Ollama integration (WF-06 generation),
-- so every LLM call is observable via llm_runs / cost_ledger.
-- ============================================================================
CREATE OR REPLACE FUNCTION record_llm_run(
  p_client_code text,
  p_task_type text,
  p_provider text,
  p_model text,
  p_prompt_version text,
  p_input_classification text,
  p_input_hash text DEFAULT NULL,
  p_output_hash text DEFAULT NULL,
  p_tokens_in integer DEFAULT NULL,
  p_tokens_out integer DEFAULT NULL,
  p_cost_amount numeric DEFAULT NULL,
  p_latency_ms integer DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_client uuid;
  v_id uuid;
BEGIN
  IF p_client_code IS NOT NULL THEN
    SELECT id INTO v_client FROM clients WHERE code = p_client_code;
  END IF;
  INSERT INTO llm_runs(client_id, task_type, provider, model, prompt_version,
                       input_classification, input_hash, output_hash,
                       tokens_in, tokens_out, cost_amount, latency_ms)
  VALUES (v_client, p_task_type, p_provider, p_model, p_prompt_version,
          p_input_classification, p_input_hash, p_output_hash,
          p_tokens_in, p_tokens_out, p_cost_amount, p_latency_ms)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;