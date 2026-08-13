-- ============================================================================
-- Stage 3 · Surface + Intent views (NocoDB-facing). Read-only.
-- WF-02 results: discovered surfaces/resources + public evidence.
-- WF-03 results: intent/query priority status.
-- ============================================================================

-- Discovered surfaces with resource counts and last observation.
CREATE OR REPLACE VIEW v_surface_discovery AS
SELECT
  c.code, c.display_name,
  s.id AS surface_id, s.surface_type, s.platform,
  s.canonical_url, s.account_or_property,
  s.publication_mode, s.active, s.updated_at,
  e.canonical_name AS owner_entity,
  count(r.id) AS resources,
  max(r.last_observed_at) AS last_observed_at
FROM surfaces s
JOIN clients c ON c.id = s.client_id
LEFT JOIN entities e ON e.id = s.owner_entity_id
LEFT JOIN surface_resources r ON r.surface_id = s.id
GROUP BY c.code, c.display_name, s.id, s.surface_type, s.platform,
         s.canonical_url, s.account_or_property, s.publication_mode,
         s.active, s.updated_at, e.canonical_name
ORDER BY c.code, s.surface_type, s.platform;

-- Every discovered resource under its surface.
CREATE OR REPLACE VIEW v_surface_resources_list AS
SELECT
  c.code AS client_code,
  s.surface_type, s.platform,
  r.id AS resource_id, r.resource_type, r.url, r.external_id, r.title,
  r.published_at, r.last_observed_at, r.content_hash
FROM surface_resources r
JOIN surfaces s ON s.id = r.surface_id
JOIN clients c ON c.id = r.client_id
ORDER BY c.code, s.platform, r.last_observed_at DESC;

-- Intent/query priority status (highest priority first).
CREATE OR REPLACE VIEW v_intent_query_status AS
SELECT
  c.code, c.display_name,
  i.id AS intent_id, i.intent_type, i.label, i.status, i.priority_score,
  i.commercial_score, i.opportunity_score,
  e.canonical_name AS entity,
  count(q.id) AS queries,
  count(q.id) FILTER (WHERE q.active) AS active_queries
FROM intents i
JOIN clients c ON c.id = i.client_id
LEFT JOIN entities e ON e.id = i.entity_id
LEFT JOIN queries q ON q.intent_id = i.id
GROUP BY c.code, c.display_name, i.id, i.intent_type, i.label, i.status,
         i.priority_score, i.commercial_score, i.opportunity_score,
         e.canonical_name
ORDER BY c.code, i.priority_score DESC;