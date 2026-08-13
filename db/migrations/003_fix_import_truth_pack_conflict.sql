-- ============================================================================
-- MOY GEO Operator · Migration 003 · Fix import_truth_pack ON CONFLICT inference
-- uq_truth_documents_import_key is a PARTIAL unique index (WHERE import_key
-- IS NOT NULL). PostgreSQL cannot infer a partial unique index from a bare
-- `ON CONFLICT (import_key)`; the arbiter predicate must be stated explicitly.
-- This migration redefines the function with the corrected conflict target.
-- ============================================================================
CREATE OR REPLACE FUNCTION import_truth_pack(
  p_client_code text,
  p_documents   jsonb,   -- [{import_key,document_type,title,source_uri,file_path,checksum,document_status}]
  p_entities    jsonb,   -- [{entity_type,canonical_name,aliases}]
  p_claims      jsonb    -- [{import_key,entity_type,entity_name,field_key,claim_text,normalized_value,document_key,rule_verify,low_risk}]
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
         rule_verify boolean, low_risk boolean)
  LOOP
    IF v_cl.import_key IS NOT NULL
       AND EXISTS (SELECT 1 FROM claims WHERE client_id=v_client AND import_key=v_cl.import_key) THEN
      CONTINUE;  -- already imported (idempotent)
    END IF;

    SELECT id INTO v_ent_id FROM entities
      WHERE client_id=v_client AND entity_type=v_cl.entity_type AND canonical_name=v_cl.entity_name
      LIMIT 1;

    v_doc_id := NULL;
    IF v_cl.document_key IS NOT NULL THEN
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
                                 truth_document_id, claim_id, excerpt, confidence, checksum)
      VALUES (v_client, v_cl.field_key, 'TRUTH_DOCUMENT',
              (SELECT source_uri FROM truth_documents WHERE id = v_doc_id),
              v_doc_id, v_claim_id, left(v_cl.claim_text, 500), 0.95,
              (SELECT checksum FROM truth_documents WHERE id = v_doc_id));
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
        ') has no source document; cannot proceed.',
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