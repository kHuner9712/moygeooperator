-- ============================================================================
-- Stage 5 · Gap / Action views (NocoDB-facing). Read-only.
-- WF-05 results: prioritized gap queue, prioritized action queue, and the
-- gap→action linkage operators scan daily.
-- ============================================================================

-- Open gaps, prioritized (severity then intent priority, oldest first).
CREATE OR REPLACE VIEW v_gap_queue AS
SELECT
  g.id,
  c.code AS client_code,
  g.gap_type,
  g.severity,
  g.diagnosis,
  e.canonical_name AS entity_name,
  i.label AS intent_label,
  COALESCE(i.priority_score,0) AS intent_priority,
  pr.provider AS engine_provider,
  s.platform AS surface_platform, s.surface_type AS surface_type,
  g.evidence_refs,
  g.status,
  g.created_at
FROM geo_gaps g
LEFT JOIN clients c ON c.id = g.client_id
LEFT JOIN entities e ON e.id = g.entity_id
LEFT JOIN intents i ON i.id = g.intent_id
LEFT JOIN engines pr ON pr.id = g.engine_id
LEFT JOIN surfaces s ON s.id = g.surface_id
WHERE g.status = 'OPEN'
ORDER BY
  CASE g.severity WHEN 'CRITICAL' THEN 0 WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END,
  COALESCE(i.priority_score,0) DESC,
  g.created_at ASC;

-- Open actions, prioritized for the operator.
CREATE OR REPLACE VIEW v_action_queue AS
SELECT
  a.id,
  c.code AS client_code,
  a.action_type,
  a.title,
  a.instructions,
  a.priority,
  a.status,
  i.label AS intent_label,
  s.platform AS target_surface_platform, s.surface_type AS target_surface_type,
  a.due_at,
  a.evidence_refs,
  a.created_at,
  CASE WHEN a.due_at IS NOT NULL AND a.due_at < now() THEN 'OVERDUE' ELSE 'OK' END AS due_state
FROM geo_actions a
LEFT JOIN clients c ON c.id = a.client_id
LEFT JOIN intents i ON i.id = a.target_intent_id
LEFT JOIN surfaces s ON s.id = a.target_surface_id
WHERE a.status NOT IN ('DONE','CANCELLED')
ORDER BY a.priority DESC, a.due_at ASC;

-- Gap → Action linkage (why does this action exist?).
CREATE OR REPLACE VIEW v_gap_actions AS
SELECT
  g.id AS gap_id,
  g.gap_type,
  g.severity,
  g.diagnosis,
  a.id AS action_id,
  a.action_type,
  a.title AS action_title,
  a.priority AS action_priority,
  a.status AS action_status,
  c.code AS client_code,
  i.label AS intent_label
FROM geo_gaps g
JOIN geo_actions a ON a.gap_id = g.id
LEFT JOIN clients c ON c.id = g.client_id
LEFT JOIN intents i ON i.id = g.intent_id
ORDER BY g.severity, a.priority DESC;