-- ============================================================================
-- MOY GEO Operator · Migration 014 · Shadow Gate Hotfix & Full Runtime E2E
-- Final P0 closure before ONE REAL CLIENT SHADOW RUN. No new GEO capability,
-- engine, platform, report type, or core-model change. Closes the remaining
-- runtime-blocking contracts:
--
--   P0.2  import_truth_pack refuses ORPHAN claims (entity_id would be NULL):
--         unresolved entity -> CLAIM_ENTITY_UNRESOLVED, claim skipped, exception
--         recorded. Never INSERT a claim with NULL entity_id.
--   P0.7  claim_next_job unifies lease/attempts semantics: it may ONLY claim
--         PENDING/RETRY_WAIT and ALWAYS counts the claim as a new attempt.
--         Expired RUNNING leases are handled exclusively by recover_expired_leases()
--         (RUNNING -> PENDING [next claim consumes one attempt] or -> FAILED at
--         max_attempts). claim_next_job no longer directly reclaims RUNNING.
--   P0.3  client-aware dispatch_publication(p_client_id, p_task_id): WF-07 must
--         prove the task belongs to the job's client before dispatch. A
--         cross-client task_id -> CROSS_CLIENT_REFERENCE (CRITICAL), never dispatch.
-- ============================================================================

-- ============================================================================
-- P0.2 — import_truth_pack: refuse orphan claims.
-- The legacy implementation could INSERT a claim with entity_id = NULL when the
-- claim's (entity_type, entity_name) could not be resolved to an entity. That is
-- a P0 data-integrity hole. Now a claim whose entity cannot be resolved is
-- SKIPPED, an CLAIM_ENTITY_UNRESOLVED exception is recorded (with client_id,
-- import_key, entity_name, entity_type, document_key), and the import summary
-- reports it. No claim with NULL entity_id is ever written.
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
  n_missing_evidence int := 0;
  n_orphan int := 0;
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

  -- Claims + Evidence. P0.2: a claim whose entity cannot be resolved is SKIPPED
  -- (never a NULL-entity_id claim), an exception is recorded, and the summary
  -- reports it. Claims are imported together with their entities in the same
  -- pack, but the entity lookup is re-run here so a claim may reference an
  -- entity declared later in the same payload.
  FOR v_cl IN SELECT * FROM jsonb_to_recordset(p_claims)
    AS x(import_key text, entity_type text, entity_name text, field_key text,
         claim_text text, normalized_value jsonb, document_key text,
         rule_verify boolean, low_risk boolean, evidence_locator jsonb)
  LOOP
    IF v_cl.import_key IS NOT NULL
       AND EXISTS (SELECT 1 FROM claims WHERE client_id=v_client AND import_key=v_cl.import_key) THEN
      CONTINUE;  -- already imported (idempotent)
    END IF;

    -- Required contract fields (P0.1): every claim must name an entity.
    IF COALESCE(v_cl.entity_type,'') = '' OR COALESCE(v_cl.entity_name,'') = '' THEN
      n_orphan := n_orphan + 1;
      PERFORM raise_exception(v_client, 'CLAIM_ENTITY_UNRESOLVED', 'HIGH',
        'Claim missing entity binding',
        'Claim ' || COALESCE(v_cl.import_key,'?') || ' field=' || COALESCE(v_cl.field_key,'?') ||
          ' has no entity_type/entity_name; cannot resolve entity_id.',
        NULL, 'claim', NULL, now());
      CONTINUE;
    END IF;

    SELECT id INTO v_ent_id FROM entities
      WHERE client_id=v_client AND entity_type=v_cl.entity_type AND canonical_name=v_cl.entity_name
      LIMIT 1;

    -- P0.2: unresolved entity -> skip + exception (NEVER a NULL entity_id claim).
    IF v_ent_id IS NULL THEN
      n_orphan := n_orphan + 1;
      PERFORM raise_exception(v_client, 'CLAIM_ENTITY_UNRESOLVED', 'HIGH',
        'Claim entity not found',
        'Claim ' || COALESCE(v_cl.import_key,'?') || ' field=' || COALESCE(v_cl.field_key,'?') ||
          ' references entity_type=' || v_cl.entity_type || ' entity_name=' || v_cl.entity_name ||
          ' document=' || COALESCE(v_cl.document_key,'?') || ', which is not declared in this client pack.',
        NULL, 'claim', NULL, now());
      CONTINUE;
    END IF;

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
      n_missing_evidence := n_missing_evidence + 1;
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
    'missing_evidence', n_missing_evidence,
    'orphan_claims_skipped', n_orphan,
    'conflict_fields', n_conflicts
  );
END;
$$;

-- ============================================================================
-- P0.7 — UNIFIED lease/attempts semantics.
-- Decision taken: an expired RUNNING lease is recovered ONLY by
-- recover_expired_leases() (RUNNING -> PENDING, or -> FAILED at max_attempts).
-- claim_next_job() therefore claims ONLY PENDING / RETRY_WAIT jobs, and every
-- claim consumes one retry attempt (attempts + 1). A worker that crashes leaves
-- its job RUNNING; the recovery step puts it back to PENDING; the next claim is
-- a fresh attempt. This removes the previous mixed behavior where claim_next_job
-- could directly reclaim an expired RUNNING lease WITHOUT incrementing attempts.
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
    attempts = attempts + 1,           -- every claim consumes one retry attempt
    lease_until = now() + make_interval(secs => p_lease_seconds)
  WHERE id = (
    SELECT id FROM jobs
    WHERE status IN ('PENDING','RETRY_WAIT')
      AND (lease_until IS NULL OR lease_until < now())
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

-- NOTE: recover_expired_leases() / recover_expired_leases_report() from 013
-- already implement the RUNNING->PENDING / ->FAILED transition and remain
-- unchanged. claim_next_job now hands ALL expired-RUNNING recovery to them.

-- ============================================================================
-- P0.3 — client-aware dispatch_publication.
-- Adds a (p_client_id, p_task_id) overload so WF-07 can prove a task belongs to
-- the job's client BEFORE dispatching. A task whose client_id differs from the
-- caller's p_client_id is rejected with a CRITICAL CROSS_CLIENT_REFERENCE
-- exception and NOT dispatched. The legacy single-arg overload is kept for
-- backward compatibility but WF-07 must use the client-aware form.
-- ============================================================================
CREATE OR REPLACE FUNCTION dispatch_publication(p_client_id uuid, p_task_id uuid) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_task publication_tasks%ROWTYPE;
BEGIN
  SELECT * INTO v_task FROM publication_tasks WHERE id = p_task_id;
  IF v_task IS NULL THEN
    RAISE EXCEPTION 'publication task % not found', p_task_id;
  END IF;
  -- P0.3: the task MUST belong to the claiming job's client. Fail closed.
  IF v_task.client_id IS DISTINCT FROM p_client_id THEN
    PERFORM raise_exception(p_client_id, 'CROSS_CLIENT_REFERENCE', 'CRITICAL',
      'Cross-client publication task blocked',
      'task ' || p_task_id::text || ' belongs to client ' || v_task.client_id::text ||
      ', not caller client ' || p_client_id::text || '; refusing to dispatch.',
      NULL, 'PUBLICATION_TASK', p_task_id, now());
    RETURN jsonb_build_object('mode', v_task.mode, 'outcome', 'BLOCKED',
      'error', 'CROSS_CLIENT_REFERENCE');
  END IF;
  RETURN dispatch_publication(p_task_id);
END;
$$;