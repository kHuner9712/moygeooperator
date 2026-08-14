-- ============================================================================
-- MOY GEO Operator · Migration 013 · N8N Runtime Closure & Shadow Run Gate
-- Closes the remaining runtime-contract gaps so a ONE REAL CLIENT shadow run
-- can actually execute through n8n. No new GEO product capability is added.
--
-- Covers (DB layer):
--   P0.1  import_truth_pack consumes evidence_locator (claim -> doc -> locator)
--   P0.2  ingest_extracted_truth_document(): store PDF/URL extraction result
--         (content, parser, parsed_at, checksum) into truth_documents
--   P0.9  claim_next_job / recover_expired_leases enforce max_attempts so a
--         job at max attempts is never reclaimed forever (JOB_RETRY_EXHAUSTED)
--   P0.10 adapt_content_for_surface re-enters DRAFT + gates (no inherited
--         publication-ready status)
--   P0.11 create_publication_task accepts ONLY READY_TO_PUBLISH with
--         fact_check_status=PASSED AND compliance_status=PASSED
-- ============================================================================

-- ============================================================================
-- P0.10 — Drop the legacy 3-arg adapt_content_for_surface(uuid, uuid, text)
-- overload (migration 008). It produced a variant with status='READY' that
-- INHERITED the base asset's fact/compliance status, bypassing the mandatory
-- re-gate. Only the 4-arg (client-aware) re-gating overload may exist, so no
-- path can adapt content without re-running the Fact + Compliance gates.
-- ============================================================================
DROP FUNCTION IF EXISTS adapt_content_for_surface(uuid, uuid, text);

-- ============================================================================
-- P0.2 — Ingest an externally-extracted Truth document (PDF / URL / any).
-- WF-01 calls this after the truth-extractor service returns real content.
-- Stores content + parser metadata + checksum and marks the document PARSED.
-- ============================================================================
CREATE OR REPLACE FUNCTION ingest_extracted_truth_document(
  p_client_code text,
  p_document_id uuid,
  p_content text,
  p_parser text DEFAULT NULL,
  p_parsed_at timestamptz DEFAULT now(),
  p_checksum text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_client uuid;
  v_doc truth_documents%ROWTYPE;
  v_checksum text := p_checksum;
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

  -- Fail closed: we must actually have extracted a non-empty content blob.
  IF p_content IS NULL OR trim(p_content) = '' THEN
    PERFORM raise_exception(v_client, 'PARSE_FAILED', 'HIGH',
      'Extractor returned no content',
      'document ' || p_document_id::text || ' (' || v_doc.document_type ||
        ') extraction produced empty content; route to MANUAL_EXTRACTION_REQUIRED.',
      NULL, 'TRUTH_DOCUMENT', v_doc.id);
    UPDATE truth_documents SET status='PARSE_FAILED', parser = COALESCE(p_parser, v_doc.parser)
      WHERE id = v_doc.id;
    RETURN jsonb_build_object('ok', false, 'reason', 'empty_content');
  END IF;

  IF v_checksum IS NULL THEN
    v_checksum := encode(digest(p_content, 'sha256'), 'hex');
  END IF;

  -- NOTE: status is set to 'PARSED' (content is present) but parsed_at is left
  -- UNCHANGED (NULL for a fresh doc). parsed_at is reserved for "claim extraction
  -- done" in WF-01; a PARSED-but-not-yet-claimed doc must still be picked up by
  -- the LLM extraction step. ingesting extracted content never marks claims done.
  UPDATE truth_documents SET
    content     = p_content,
    parser      = COALESCE(p_parser, v_doc.parser, v_doc.document_type),
    checksum    = COALESCE(v_checksum, checksum),
    status      = 'PARSED',
    metadata    = v_doc.metadata
                 || jsonb_build_object('parser', COALESCE(p_parser, v_doc.parser),
                                       'content_chars', length(p_content),
                                       'checksum', v_checksum)
    WHERE id = v_doc.id;

  RETURN jsonb_build_object('ok', true, 'document_id', v_doc.id,
                            'parser', COALESCE(p_parser, v_doc.parser),
                            'content_chars', length(p_content),
                            'checksum', v_checksum);
END;
$$;

-- ============================================================================
-- P0.1 — import_truth_pack consumes evidence_locator.
-- The claim contract now carries an optional evidence_locator object:
--   { document_id, page, section, table_ref, row_ref, source_uri, excerpt }
-- document_id (a real truth_documents.id) is authoritative; document_key
-- (import_key) remains a fallback. Evidence is bound claim -> truth_document ->
-- locator fields (page / section / table_ref / row_ref / excerpt / source_uri).
-- Claims whose document cannot be resolved fail closed (CLIENT_DATA_REQUIRED).
-- ============================================================================
CREATE OR REPLACE FUNCTION import_truth_pack(
  p_client_code text,
  p_documents   jsonb,   -- [{import_key,document_type,title,source_uri,file_path,checksum,document_status}]
  p_entities    jsonb,   -- [{entity_type,canonical_name,aliases}]
  p_claims      jsonb    -- [{import_key,entity_type,entity_name,field_key,claim_text,normalized_value,document_key,rule_verify,low_risk,evidence_locator}]
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_client uuid;
  v_doc_id uuid;
  v_ent_id uuid;
  v_claim_id uuid;
  v_doc RECORD;
  v_ent RECORD;
  v_cl  RECORD;
  v_loc jsonb;
  n_docs int := 0; n_ents int := 0; n_claims int := 0;
  n_evidence int := 0; n_verified int := 0; n_conflicts int := 0;
  v_missing_evidence int := 0;
  v_dup_notice text;
BEGIN
  SELECT id INTO v_client FROM clients WHERE code = p_client_code;
  IF v_client IS NULL THEN
    RAISE EXCEPTION 'client % not found', p_client_code;
  END IF;

  -- Documents (idempotent by import_key).
  FOR v_doc IN SELECT * FROM jsonb_to_recordset(p_documents)
    AS x(import_key text, document_type text, title text, source_uri text,
         file_path text, checksum text, document_status text)
  LOOP
    INSERT INTO truth_documents(client_id, import_key, document_type, title,
                                source_uri, file_path, checksum, status, provided_by)
    VALUES (v_client, v_doc.import_key, v_doc.document_type, v_doc.title,
            v_doc.source_uri, v_doc.file_path, v_doc.checksum,
            COALESCE(v_doc.document_status,'RECEIVED'), 'client')
    ON CONFLICT (import_key) WHERE import_key IS NOT NULL DO NOTHING;
    n_docs := n_docs + 1;
  END LOOP;

  -- Entities (idempotent by unique client+type+name).
  FOR v_ent IN SELECT * FROM jsonb_to_recordset(p_entities)
    AS x(entity_type text, canonical_name text, aliases jsonb)
  LOOP
    INSERT INTO entities(client_id, entity_type, canonical_name, aliases)
    VALUES (v_client, v_ent.entity_type, v_ent.canonical_name, COALESCE(v_ent.aliases,'[]'::jsonb))
    ON CONFLICT (client_id, entity_type, canonical_name) DO NOTHING;
    n_ents := n_ents + 1;
  END LOOP;

  -- Claims + Evidence.
  FOR v_cl IN SELECT * FROM jsonb_to_recordset(p_claims)
    AS x(import_key text, entity_type text, entity_name text, field_key text,
         claim_text text, normalized_value jsonb, document_key text,
         rule_verify boolean, low_risk boolean, evidence_locator jsonb)
  LOOP
    IF v_cl.import_key IS NOT NULL
       AND EXISTS (SELECT 1 FROM claims WHERE client_id=v_client AND import_key=v_cl.import_key) THEN
      CONTINUE;  -- already imported (idempotent)
    END IF;

    SELECT id INTO v_ent_id FROM entities
      WHERE client_id=v_client AND entity_type=v_cl.entity_type AND canonical_name=v_cl.entity_name
      LIMIT 1;

    v_loc := v_cl.evidence_locator;
    v_doc_id := NULL;
    -- P0.1: document_id (real truth_documents.id) is authoritative.
    IF v_loc IS NOT NULL AND v_loc ? 'document_id' AND v_loc->>'document_id' IS NOT NULL
       AND v_loc->>'document_id' <> '' THEN
      SELECT id INTO v_doc_id FROM truth_documents
        WHERE id = (v_loc->>'document_id')::uuid AND client_id = v_client LIMIT 1;
    END IF;
    -- Fallback: document_key (import_key prefix, legacy).
    IF v_doc_id IS NULL AND v_cl.document_key IS NOT NULL THEN
      SELECT id INTO v_doc_id FROM truth_documents
        WHERE client_id=v_client AND import_key=v_cl.document_key LIMIT 1;
    END IF;

    INSERT INTO claims(client_id, entity_id, field_key, claim_text,
                       normalized_value, verification, import_key)
    VALUES (v_client, v_ent_id, v_cl.field_key, v_cl.claim_text,
            v_cl.normalized_value, 'DRAFT', v_cl.import_key)
    RETURNING id INTO v_claim_id;
    n_claims := n_claims + 1;

    -- Evidence binding (fail-closed: every claim needs a Truth document).
    IF v_doc_id IS NOT NULL THEN
      INSERT INTO evidence_items(client_id, evidence_type, source_kind, source_uri,
                                 truth_document_id, claim_id, excerpt, confidence, checksum,
                                 section, page, table_ref, row_ref, metadata)
      VALUES (v_client, v_cl.field_key, 'TRUTH_DOCUMENT',
              COALESCE(
                CASE WHEN v_loc IS NOT NULL AND v_loc ? 'source_uri'
                       AND nullif(v_loc->>'source_uri','') IS NOT NULL
                     THEN v_loc->>'source_uri' END,
                (SELECT source_uri FROM truth_documents WHERE id = v_doc_id)),
              v_doc_id, v_claim_id,
              COALESCE(
                CASE WHEN v_loc IS NOT NULL AND v_loc ? 'excerpt'
                       AND nullif(v_loc->>'excerpt','') IS NOT NULL
                     THEN v_loc->>'excerpt' END,
                left(v_cl.claim_text, 500)),
              0.95,
              (SELECT checksum FROM truth_documents WHERE id = v_doc_id),
              NULLIF(v_loc->>'section','')::text,
              NULLIF(v_loc->>'page','')::int,
              NULLIF(v_loc->>'table_ref','')::text,
              NULLIF(v_loc->>'row_ref','')::int,
              jsonb_build_object('locator', COALESCE(v_loc, '{}'::jsonb)));
      n_evidence := n_evidence + 1;

      -- Rule-verify: only explicitly low-risk structured fields.
      IF COALESCE(v_cl.rule_verify,false) AND COALESCE(v_cl.low_risk,false) THEN
        UPDATE claims SET verification='VERIFIED', updated_at=now()
        WHERE id=v_claim_id AND verification='DRAFT';
        n_verified := n_verified + 1;
      END IF;
    ELSE
      v_missing_evidence := v_missing_evidence + 1;
      PERFORM raise_exception(v_client, 'CLIENT_DATA_REQUIRED', 'MEDIUM',
        'Claim missing Truth evidence',
        'Claim ' || COALESCE(v_cl.import_key,'?') || ' (' || v_cl.field_key ||
        ') has no resolvable source document; cannot proceed.',
        NULL, 'claim', v_claim_id, now());
    END IF;
  END LOOP;

  -- Conflict scan: same client+entity+field with >1 distinct claim_text.
  SELECT count(*) INTO n_conflicts FROM (
    SELECT client_id, entity_id, field_key
    FROM claims
    WHERE client_id = v_client
    GROUP BY client_id, entity_id, field_key
    HAVING count(DISTINCT claim_text) > 1
  ) d;

  IF n_conflicts > 0 THEN
    BEGIN
      PERFORM raise_exception(v_client, 'FACT_CONFLICT', 'HIGH',
        'Truth conflict detected in ' || n_conflicts || ' field(s)',
        'Multiple distinct claim_text values for the same entity+field require human resolution.',
        NULL, 'client', v_client, now());
    EXCEPTION WHEN unique_violation THEN
      GET STACKED DIAGNOSTICS v_dup_notice = MESSAGE_TEXT;  -- open conflict already exists
    END;
  END IF;

  RETURN jsonb_build_object(
    'client_code', p_client_code,
    'client_id', v_client,
    'documents_imported', n_docs,
    'entities_imported', n_ents,
    'claims_imported', n_claims,
    'evidence_bound', n_evidence,
    'rule_verified', n_verified,
    'missing_evidence', v_missing_evidence,
    'conflict_fields', n_conflicts
  );
END;
$$;

-- ============================================================================
-- P0.9 — max_attempts must really terminate.
-- A job may only be (re)claimed while attempts < max_attempts. Expired RUNNING
-- leases are reclaimed only when attempts < max_attempts; beyond that the job
-- is FAILED with JOB_RETRY_EXHAUSTED. This prevents infinite reclaim loops.
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
    -- A lease recovery (reclaiming an expired RUNNING lease) is NOT a new
    -- attempt; only PENDING/RETRY_WAIT claims count against max_attempts.
    attempts = CASE WHEN status = 'RUNNING' THEN attempts ELSE attempts + 1 END,
    lease_until = now() + make_interval(secs => p_lease_seconds)
  WHERE id = (
    SELECT id FROM jobs
    WHERE (
          (status IN ('PENDING','RETRY_WAIT') AND (lease_until IS NULL OR lease_until < now()))
       OR (status = 'RUNNING' AND lease_until IS NOT NULL AND lease_until < now()
           AND attempts < max_attempts)
    )
      AND due_at <= now()
      AND attempts < max_attempts
      AND (p_job_type IS NULL OR job_type = p_job_type)
    ORDER BY priority DESC, due_at ASC
    LIMIT 1
    FOR UPDATE SKIP LOCKED
  )
  RETURNING * INTO v_job;

  RETURN v_job;
END;
$$;

-- Recover expired RUNNING leases. Attempts-consuming failures are terminal:
-- a job at max_attempts is FAILED (JOB_RETRY_EXHAUSTED), never re-queued.
-- Returns the number of leases recovered to PENDING (backward compatible with
-- the int return consumed by existing worker/tests).
CREATE OR REPLACE FUNCTION recover_expired_leases() RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  n_recovered int := 0;
  n_exhausted int := 0;
BEGIN
  -- At max_attempts: terminal FAILED (never reclaimed again).
  UPDATE jobs SET
    status = 'FAILED',
    lease_until = NULL,
    finished_at = now(),
    last_error = 'JOB_RETRY_EXHAUSTED: attempts=' || attempts
  WHERE status = 'RUNNING' AND lease_until IS NOT NULL AND lease_until < now()
    AND attempts >= max_attempts;
  GET DIAGNOSTICS n_exhausted = ROW_COUNT;

  -- Below max_attempts: back to PENDING for reclaim (no attempt increment).
  UPDATE jobs SET
    status = 'PENDING',
    lease_until = NULL,
    last_error = CASE WHEN last_error IS NULL THEN
      'lease expired; recovered for reclaim'
      ELSE last_error || '; lease expired; recovered' END
  WHERE status = 'RUNNING' AND lease_until IS NOT NULL AND lease_until < now()
    AND attempts < max_attempts;
  GET DIAGNOSTICS n_recovered = ROW_COUNT;

  RETURN n_recovered;
END;
$$;

-- Detailed recovery report (observability): how many leases were recovered vs.
-- exhausted (terminal FAILED at max_attempts).
CREATE OR REPLACE FUNCTION recover_expired_leases_report() RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  n_recovered int := 0;
  n_exhausted int := 0;
BEGIN
  UPDATE jobs SET
    status = 'FAILED',
    lease_until = NULL,
    finished_at = now(),
    last_error = 'JOB_RETRY_EXHAUSTED: attempts=' || attempts
  WHERE status = 'RUNNING' AND lease_until IS NOT NULL AND lease_until < now()
    AND attempts >= max_attempts;
  GET DIAGNOSTICS n_exhausted = ROW_COUNT;

  UPDATE jobs SET
    status = 'PENDING',
    lease_until = NULL,
    last_error = CASE WHEN last_error IS NULL THEN
      'lease expired; recovered for reclaim'
      ELSE last_error || '; lease expired; recovered' END
  WHERE status = 'RUNNING' AND lease_until IS NOT NULL AND lease_until < now()
    AND attempts < max_attempts;
  GET DIAGNOSTICS n_recovered = ROW_COUNT;

  RETURN jsonb_build_object('recovered', n_recovered, 'exhausted', n_exhausted);
END;
$$;

-- ============================================================================
-- P0.10 — Surface Adaptation must re-enter the gates.
-- A surface-adapted copy must NOT inherit the base asset's publication-ready
-- status. It is stored as DRAFT with PENDING gates; only a fresh
-- run_content_fact_gate + run_compliance_gate marks it READY_TO_PUBLISH.
-- ============================================================================
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

  -- P0.10: the adapted copy is a fresh DRAFT with PENDING gates. It does NOT
  -- inherit the base's fact_check/compliance/status. The caller (WF-06) must
  -- re-run the Fact + Compliance gates before it can enter the publication queue.
  INSERT INTO content_assets(client_id, brief_id, surface_id, format,
                             title, body, media_refs, claim_ids,
                             fact_check_status, compliance_status, quality_score,
                             status, model_provider, dedup_key)
  VALUES (v_base.client_id, v_base.brief_id, p_surface_id, p_format,
          v_base.title, v_base.body, v_base.media_refs, v_base.claim_ids,
          'PENDING', 'PENDING', NULL, 'DRAFT', v_base.model_provider,
          'asset:' || v_base.brief_id::text || ':' || p_surface_id::text)
  ON CONFLICT (dedup_key) WHERE dedup_key IS NOT NULL DO NOTHING
  RETURNING id INTO v_asset;

  RETURN v_asset;
END;
$$;

-- ============================================================================
-- P0.12 — analyze_gaps must be idempotent and window-correct.
-- The visibility-gap scan previously looped over EVERY observation with
-- target_mentioned=false, including prior-period report baselines
-- (e.g. the WF-08 retest seed writes 14-day-old observations purely to compute
-- a mention-rate delta). Those historical baselines are NOT a current
-- visibility signal, so re-running analyze_gaps after a retest seed would
-- fabricate NEW gaps on each run (breaking idempotency).
--
-- Fix: for each (engine_id, query_id) only the LATEST observation determines
-- the current visibility state (DISTINCT ON ... ORDER BY observed_at DESC).
-- Gap analysis now reflects "what the current run shows", never a stale
-- baseline, and re-running is a true no-op on stable data.
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

  -- 1. Visibility: latest engine answer per (engine, query) never surfaced the
  --    target entity. Prior-period report baselines are ignored (window-correct).
  FOR r IN
    SELECT o.engine_id, q.intent_id, i.label AS intent_label,
           COALESCE(i.entity_id, NULL) AS entity_id,
           e.canonical_name AS entity_name,
           q.priority AS q_priority, o.run_key
    FROM (
      SELECT DISTINCT ON (engine_id, query_id)
             engine_id, query_id, target_mentioned, run_key
      FROM engine_observations
      WHERE client_id = v_client
      ORDER BY engine_id, query_id, observed_at DESC, id
    ) o
    JOIN queries q ON q.id = o.query_id
    JOIN intents i ON i.id = q.intent_id
    LEFT JOIN entities e ON e.id = i.entity_id
    WHERE o.target_mentioned = false
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
-- P0.11 — Publication Queue accepts ONLY READY_TO_PUBLISH.
-- The legacy 'READY' status is no longer a production-ready state. A task may
-- only be created when status=READY_TO_PUBLISH AND fact_check_status=PASSED
-- AND compliance_status=PASSED; otherwise BLOCK (raise an exception).
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

  -- P0.11: only a fully gated asset may enter the publication queue.
  IF v_asset.status <> 'READY_TO_PUBLISH'
     OR v_asset.fact_check_status <> 'PASSED'
     OR v_asset.compliance_status <> 'PASSED' THEN
    PERFORM raise_exception(v_client, 'CONTENT_QA_FAILED', 'HIGH',
      'Asset is not publication-ready',
      'asset ' || p_asset_id::text || ' status=' || v_asset.status ||
        ' fact=' || COALESCE(v_asset.fact_check_status,'PENDING') ||
        ' compliance=' || COALESCE(v_asset.compliance_status,'PENDING') ||
        '; only READY_TO_PUBLISH with PASSED fact+compliance may enter the queue.',
      NULL, 'CONTENT_ASSET', v_asset.id);
    RETURN NULL;   -- BLOCK (fail closed)
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