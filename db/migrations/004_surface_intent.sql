-- ============================================================================
-- MOY GEO Operator · Migration 004 · Stage 3 · Surface + Intent (WF-02/WF-03)
-- Adds deterministic idempotency keys + dedup constraints + upsert functions
-- for surface discovery (WF-02) and intent/query generation (WF-03). All
-- writes are client-scoped; every workflow entry requires client_code.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Idempotency / dedup keys
-- ---------------------------------------------------------------------------

-- Surfaces: workflow idempotency (import_key) + natural dedup (client+url).
ALTER TABLE surfaces ADD COLUMN import_key text;
CREATE UNIQUE INDEX uq_surfaces_import_key
  ON surfaces(import_key) WHERE import_key IS NOT NULL;
CREATE UNIQUE INDEX uq_surfaces_client_url
  ON surfaces(client_id, canonical_url) WHERE canonical_url IS NOT NULL;

-- Surface resources: dedup by client+url, client+surface+external_id.
ALTER TABLE surface_resources ADD COLUMN import_key text;
CREATE UNIQUE INDEX uq_surface_resources_import_key
  ON surface_resources(import_key) WHERE import_key IS NOT NULL;
CREATE UNIQUE INDEX uq_surface_resources_client_url
  ON surface_resources(client_id, url) WHERE url IS NOT NULL;
CREATE UNIQUE INDEX uq_surface_resources_surface_external
  ON surface_resources(client_id, surface_id, external_id) WHERE external_id IS NOT NULL;

-- Evidence idempotency (public crawl evidence is an expensive/external action).
ALTER TABLE evidence_items ADD COLUMN import_key text;
CREATE UNIQUE INDEX uq_evidence_import_key
  ON evidence_items(import_key) WHERE import_key IS NOT NULL;

-- Queries: dedup query generation per intent.
CREATE UNIQUE INDEX uq_queries_intent_text
  ON queries(client_id, intent_id, query_text);

-- ============================================================================
-- WF-02 write path: idempotent surface + resource upsert.
-- ============================================================================

-- Idempotent surface upsert. Primary key is import_key (workflow idempotency);
-- client_id+canonical_url is the natural dedup fallback.
CREATE OR REPLACE FUNCTION upsert_surface(
  p_client_code text,
  p_surface_type text,
  p_platform text,
  p_account_or_property text DEFAULT NULL,
  p_canonical_url text DEFAULT NULL,
  p_owner_entity_name text DEFAULT NULL,
  p_publication_mode publication_mode DEFAULT 'MANUAL_REQUIRED',
  p_credential_ref text DEFAULT NULL,
  p_import_key text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_client uuid;
  v_ent uuid;
  v_id uuid;
BEGIN
  SELECT id INTO v_client FROM clients WHERE code = p_client_code;
  IF v_client IS NULL THEN
    RAISE EXCEPTION 'client % not found', p_client_code;
  END IF;

  IF p_owner_entity_name IS NOT NULL THEN
    SELECT id INTO v_ent FROM entities
      WHERE client_id = v_client AND canonical_name = p_owner_entity_name
      LIMIT 1;
  END IF;

  -- Already imported by this workflow -- refresh and return.
  IF p_import_key IS NOT NULL AND EXISTS (
    SELECT 1 FROM surfaces WHERE import_key = p_import_key) THEN
    SELECT id INTO v_id FROM surfaces WHERE import_key = p_import_key;
    UPDATE surfaces SET
      surface_type = p_surface_type,
      platform = p_platform,
      account_or_property = COALESCE(p_account_or_property, account_or_property),
      canonical_url  = COALESCE(p_canonical_url, canonical_url),
      owner_entity_id = COALESCE(v_ent, owner_entity_id),
      updated_at = now()
    WHERE id = v_id;
    RETURN v_id;
  END IF;

  INSERT INTO surfaces(client_id, surface_type, platform, account_or_property,
                       canonical_url, owner_entity_id, publication_mode,
                       credential_ref, import_key)
  VALUES (v_client, p_surface_type, p_platform, p_account_or_property,
          p_canonical_url, v_ent, p_publication_mode, p_credential_ref, p_import_key)
  ON CONFLICT (client_id, canonical_url) WHERE canonical_url IS NOT NULL
  DO UPDATE SET
    surface_type = EXCLUDED.surface_type,
    platform = EXCLUDED.platform,
    owner_entity_id = COALESCE(EXCLUDED.owner_entity_id, surfaces.owner_entity_id),
    import_key = COALESCE(EXCLUDED.import_key, surfaces.import_key),
    updated_at = now()
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

-- Idempotent surface resource upsert. content is hashed for de-dup/change
-- detection; every re-observation bumps last_observed_at.
CREATE OR REPLACE FUNCTION upsert_surface_resource(
  p_client_code text,
  p_surface_import_key text,
  p_resource_type text,
  p_url text DEFAULT NULL,
  p_external_id text DEFAULT NULL,
  p_title text DEFAULT NULL,
  p_published_at timestamptz DEFAULT NULL,
  p_content text DEFAULT NULL,
  p_import_key text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_client uuid;
  v_surface uuid;
  v_id uuid;
  v_hash text;
BEGIN
  SELECT id INTO v_client FROM clients WHERE code = p_client_code;
  IF v_client IS NULL THEN
    RAISE EXCEPTION 'client % not found', p_client_code;
  END IF;

  SELECT id INTO v_surface FROM surfaces
    WHERE client_id = v_client AND import_key = p_surface_import_key;
  IF v_surface IS NULL THEN
    RAISE EXCEPTION 'surface % not found for client %', p_surface_import_key, p_client_code;
  END IF;

  v_hash := NULL;
  IF p_content IS NOT NULL THEN
    v_hash := encode(digest(p_content, 'sha256'), 'hex');
  END IF;

  IF p_import_key IS NOT NULL AND EXISTS (
    SELECT 1 FROM surface_resources WHERE import_key = p_import_key) THEN
    SELECT id INTO v_id FROM surface_resources WHERE import_key = p_import_key;
    UPDATE surface_resources SET
      resource_type = COALESCE(p_resource_type, resource_type),
      title          = COALESCE(p_title, title),
      published_at   = COALESCE(p_published_at, published_at),
      last_observed_at = now(),
      content_hash   = COALESCE(v_hash, content_hash),
      metadata = metadata || jsonb_build_object('re_observed_at', to_char(now(),'YYYY-MM-DD"T"HH24:MI:SS'))
    WHERE id = v_id;
    RETURN v_id;
  END IF;

  INSERT INTO surface_resources(client_id, surface_id, resource_type, url,
                                external_id, title, published_at, last_observed_at,
                                content_hash, import_key)
  VALUES (v_client, v_surface, p_resource_type, p_url, p_external_id,
          p_title, p_published_at, now(), v_hash, p_import_key)
  ON CONFLICT (client_id, url) WHERE url IS NOT NULL
  DO UPDATE SET
    last_observed_at = now(),
    content_hash = COALESCE(EXCLUDED.content_hash, surface_resources.content_hash),
    import_key = COALESCE(EXCLUDED.import_key, surface_resources.import_key)
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

-- Record public evidence for a discovered resource (idempotent by import_key).
CREATE OR REPLACE FUNCTION record_public_evidence(
  p_client_code text,
  p_resource_import_key text,
  p_evidence_type text,
  p_excerpt text DEFAULT NULL,
  p_confidence numeric DEFAULT 0.9,
  p_import_key text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_client uuid;
  v_res surface_resources;
  v_id uuid;
BEGIN
  SELECT id INTO v_client FROM clients WHERE code = p_client_code;
  IF v_client IS NULL THEN
    RAISE EXCEPTION 'client % not found', p_client_code;
  END IF;

  SELECT * INTO v_res FROM surface_resources
    WHERE client_id = v_client AND import_key = p_resource_import_key;
  IF v_res IS NULL THEN
    RAISE EXCEPTION 'resource % not found for client %', p_resource_import_key, p_client_code;
  END IF;

  INSERT INTO evidence_items(client_id, evidence_type, source_kind, source_uri,
                             excerpt, observed_at, confidence, import_key, metadata)
  VALUES (v_client, p_evidence_type, 'PUBLIC_WEB', v_res.url,
          p_excerpt, now(), p_confidence, p_import_key,
          jsonb_build_object('surface_resource_id', v_res.id, 'resource_title', v_res.title))
  ON CONFLICT (import_key) WHERE import_key IS NOT NULL DO NOTHING
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

-- ============================================================================
-- WF-03 write path: idempotent intent + query registration.
-- intents are keyed by (client_id, label); queries dedup by intent+text.
-- ============================================================================
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

  INSERT INTO intents(client_id, entity_id, intent_type, label, description,
                      commercial_score, relevance_score, opportunity_score,
                      priority_score)
  VALUES (v_client, v_ent, p_intent_type, p_label, p_description,
          p_commercial, p_relevance, p_opportunity,
          COALESCE(p_commercial,0) + COALESCE(p_relevance,0) + COALESCE(p_opportunity,0))
  ON CONFLICT (client_id, label) DO UPDATE SET
    entity_id = COALESCE(EXCLUDED.entity_id, intents.entity_id),
    intent_type = EXCLUDED.intent_type,
    description = COALESCE(EXCLUDED.description, intents.description),
    commercial_score = COALESCE(EXCLUDED.commercial_score, intents.commercial_score),
    relevance_score  = COALESCE(EXCLUDED.relevance_score, intents.relevance_score),
    opportunity_score= COALESCE(EXCLUDED.opportunity_score, intents.opportunity_score),
    priority_score   = COALESCE(EXCLUDED.commercial_score,0)
                     + COALESCE(EXCLUDED.relevance_score,0)
                     + COALESCE(EXCLUDED.opportunity_score,0),
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

  RETURN jsonb_build_object('intent_id', v_intent, 'queries_considered', n_queries);
END;
$$;