-- ============================================================================
-- Stage 2 · Truth Intake views (NocoDB-facing). Read-only.
-- Show the operator the per-client truth intake state from WF-01.
-- ============================================================================

-- Per-client truth intake summary.
CREATE OR REPLACE VIEW v_truth_intake_summary AS
SELECT
  c.id AS client_id, c.code, c.display_name, c.status,
  count(DISTINCT td.id) AS documents,
  count(DISTINCT e.id)  AS entities,
  count(DISTINCT cl.id) AS claims,
  count(DISTINCT cl.id) FILTER (WHERE cl.verification='DRAFT')     AS draft_claims,
  count(DISTINCT cl.id) FILTER (WHERE cl.verification='VERIFIED')  AS verified_claims,
  count(DISTINCT cl.id) FILTER (WHERE cl.verification='REJECTED')  AS rejected_claims,
  count(DISTINCT ev.id) AS evidence_items,
  count(DISTINCT ex.id) FILTER (WHERE ex.status='OPEN')            AS open_exceptions
FROM clients c
LEFT JOIN truth_documents td ON td.client_id = c.id
LEFT JOIN entities e         ON e.client_id  = c.id
LEFT JOIN claims cl          ON cl.client_id = c.id
LEFT JOIN evidence_items ev  ON ev.client_id = c.id
LEFT JOIN exceptions ex      ON ex.client_id = c.id
GROUP BY c.id, c.code, c.display_name, c.status;

-- Every claim with its entity, verification, evidence count and conflicts.
CREATE OR REPLACE VIEW v_truth_claims AS
SELECT
  cl.id,
  c.code AS client_code,
  ent.entity_type,
  ent.canonical_name AS entity,
  cl.field_key,
  cl.claim_text,
  cl.normalized_value,
  cl.verification,
  cl.valid_from,
  cl.valid_until,
  cl.created_at,
  count(ev.id) AS evidence_count,
  (SELECT count(*) FROM claims c2
     WHERE c2.client_id = cl.client_id AND c2.entity_id = cl.entity_id
       AND c2.field_key = cl.field_key AND c2.id <> cl.id) AS conflicting_claims
FROM claims cl
JOIN clients c  ON c.id  = cl.client_id
LEFT JOIN entities ent ON ent.id = cl.entity_id
LEFT JOIN evidence_items ev ON ev.claim_id = cl.id
GROUP BY cl.id, c.code, ent.entity_type, ent.canonical_name, cl.field_key,
         cl.claim_text, cl.normalized_value, cl.verification, cl.valid_from,
         cl.valid_until, cl.created_at
ORDER BY c.code, ent.canonical_name, cl.field_key;

-- Evidence items bound to claims.
CREATE OR REPLACE VIEW v_truth_evidence AS
SELECT
  ev.id,
  c.code AS client_code,
  ev.claim_id,
  cl.field_key,
  cl.claim_text,
  ev.source_kind,
  ev.source_uri,
  ev.excerpt,
  ev.confidence,
  ev.checksum,
  ev.created_at
FROM evidence_items ev
JOIN clients c  ON c.id  = ev.client_id
LEFT JOIN claims cl ON cl.id = ev.claim_id
ORDER BY c.code, cl.field_key;

-- Open truth conflicts (FACT_CONFLICT) — the operator must resolve these.
CREATE OR REPLACE VIEW v_truth_conflicts AS
SELECT
  ex.id,
  c.code AS client_code,
  ex.exception_type,
  ex.severity,
  ex.status,
  ex.title,
  ex.detail,
  ex.related_object_type,
  ex.related_object_id,
  ex.created_at
FROM exceptions ex
JOIN clients c ON c.id = ex.client_id
WHERE ex.exception_type = 'FACT_CONFLICT'
ORDER BY ex.created_at DESC;