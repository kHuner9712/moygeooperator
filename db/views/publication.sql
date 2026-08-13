-- ============================================================================
-- Stage 7 · Publishing views (WF-07) for NocoDB / operator dashboard.
-- ============================================================================

-- Publication task queue with mode + status + error.
CREATE OR REPLACE VIEW v_publication_queue AS
SELECT
  t.id,
  c.code AS client_code,
  s.platform,
  s.surface_type,
  e.canonical_name AS entity_name,
  t.mode,
  t.status,
  t.credential_ref,
  t.payload_json,
  t.last_error,
  t.scheduled_for,
  t.created_at
FROM publication_tasks t
LEFT JOIN clients c ON c.id = t.client_id
LEFT JOIN surfaces s ON s.id = t.surface_id
LEFT JOIN content_assets a ON a.id = t.content_asset_id
LEFT JOIN content_briefs b ON b.id = a.brief_id
LEFT JOIN entities e ON e.id = b.target_entity_id
ORDER BY
  CASE t.status WHEN 'PUBLISHING' THEN 0 WHEN 'READY' THEN 1
               WHEN 'WAITING_APPROVAL' THEN 2 WHEN 'BLOCKED' THEN 3 ELSE 4 END,
  t.created_at ASC;

-- Publication records (what actually got published).
CREATE OR REPLACE VIEW v_publication_records AS
SELECT
  r.id,
  c.code AS client_code,
  r.platform,
  s.surface_type,
  r.external_id,
  r.url,
  r.published_at,
  r.verification_status,
  r.provider_response,
  r.evidence_uri,
  t.mode AS task_mode
FROM publication_records r
LEFT JOIN clients c ON c.id = r.client_id
LEFT JOIN publication_tasks t ON t.id = r.publication_task_id
LEFT JOIN surfaces s ON s.id = t.surface_id
ORDER BY r.published_at DESC;

-- Adapter capability registry (what AUTO_API may target).
CREATE OR REPLACE VIEW v_publication_adapters AS
SELECT
  platform,
  capability,
  official,
  requires_credential,
  enabled,
  config
FROM publication_adapters
ORDER BY platform, capability;