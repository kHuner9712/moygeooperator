-- ============================================================================
-- Stage 6 · Content Factory views (WF-06) for NocoDB / operator dashboard.
-- ============================================================================

-- Content factory queue: briefs and their readiness for generation.
CREATE OR REPLACE VIEW v_content_brief_queue AS
SELECT
  b.id,
  c.code AS client_code,
  a.title AS action_title,
  i.label AS intent_label,
  e.canonical_name AS entity_name,
  b.canonical_angle,
  jsonb_array_length(b.required_claim_ids) AS required_claims,
  b.target_surfaces,
  b.status,
  b.created_at
FROM content_briefs b
LEFT JOIN clients c ON c.id = b.client_id
LEFT JOIN geo_actions a ON a.id = b.action_id
LEFT JOIN intents i ON i.id = b.intent_id
LEFT JOIN entities e ON e.id = b.target_entity_id
ORDER BY b.created_at DESC;

-- Content asset queue: generated assets with fact-QA / compliance state.
CREATE OR REPLACE VIEW v_content_asset_queue AS
SELECT
  a.id,
  c.code AS client_code,
  b.canonical_angle AS brief_angle,
  i.label AS intent_label,
  e.canonical_name AS entity_name,
  s.platform AS surface_platform,
  s.surface_type AS surface_type,
  a.format,
  a.fact_check_status,
  a.compliance_status,
  a.quality_score,
  a.status,
  a.model_provider,
  a.created_at
FROM content_assets a
LEFT JOIN clients c ON c.id = a.client_id
LEFT JOIN content_briefs b ON b.id = a.brief_id
LEFT JOIN intents i ON i.id = b.intent_id
LEFT JOIN entities e ON e.id = b.target_entity_id
LEFT JOIN surfaces s ON s.id = a.surface_id
ORDER BY a.created_at DESC;