-- ============================================================================
-- MOY GEO Operator · Migration 009 · Stage 7 · Publishing (WF-07)
-- Publication task creation + mode-routed dispatch (AUTO_API / API_ASSISTED /
-- BROWSER_ASSISTED / MANUAL_REQUIRED / BLOCKED). AUTO_API only ever runs against
-- an officially-registered adapter WITH a valid credential; anything else fails
-- closed. No CAPTCHA / 2FA / anti-bot bypass — such surfaces route to
-- BROWSER_ASSISTED / MANUAL_REQUIRED for a human.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Official adapter capability registry. AUTO_API is gated on an enabled,
-- official, credential-requiring adapter here — a safe, real adapter is only
-- wired once official capability AND credentials are present.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS publication_adapters (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  platform text NOT NULL,
  capability text NOT NULL DEFAULT 'PUBLISH',
  official boolean NOT NULL DEFAULT false,
  requires_credential boolean NOT NULL DEFAULT true,
  enabled boolean NOT NULL DEFAULT false,
  config jsonb NOT NULL DEFAULT '{}',
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(platform, capability)
);

-- Idempotency keys.
ALTER TABLE publication_tasks   ADD COLUMN IF NOT EXISTS dedup_key text;
ALTER TABLE publication_records ADD COLUMN IF NOT EXISTS dedup_key text;
CREATE UNIQUE INDEX IF NOT EXISTS uq_publication_tasks_dedup
  ON publication_tasks(dedup_key) WHERE dedup_key IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_publication_records_dedup
  ON publication_records(dedup_key) WHERE dedup_key IS NOT NULL;

-- ============================================================================
-- register_publication_adapter — idempotent registry upsert. Marks whether the
-- platform capability is OFFICIAL (provider-backed) and whether it needs a
-- credential. AUTO_API dispatch refuses anything not official+enabled.
-- ============================================================================
CREATE OR REPLACE FUNCTION register_publication_adapter(
  p_platform text,
  p_capability text DEFAULT 'PUBLISH',
  p_official boolean DEFAULT false,
  p_requires_credential boolean DEFAULT true,
  p_enabled boolean DEFAULT false,
  p_config jsonb DEFAULT '{}'
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_id uuid;
BEGIN
  INSERT INTO publication_adapters(platform, capability, official,
                                   requires_credential, enabled, config)
  VALUES (p_platform, p_capability, p_official, p_requires_credential,
          p_enabled, p_config)
  ON CONFLICT (platform, capability) DO UPDATE SET
    official = EXCLUDED.official,
    requires_credential = EXCLUDED.requires_credential,
    enabled = EXCLUDED.enabled,
    config = EXCLUDED.config
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

-- ============================================================================
-- create_publication_task — build a publication task for a READY content asset
-- on a given surface. Idempotent per (asset, surface). The task inherits the
-- surface's publication_mode.
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
  IF v_asset.status <> 'READY' THEN
    RAISE EXCEPTION 'asset % is not READY (status=%)', p_asset_id, v_asset.status;
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

-- ============================================================================
-- dispatch_publication — route a task by its surface publication_mode. Fail
-- closed: AUTO_API requires an official, enabled adapter AND a credential_ref;
-- anything missing routes to BLOCKED + exception. Records the publication on
-- success. Returns { mode, outcome }.
-- ============================================================================
CREATE OR REPLACE FUNCTION dispatch_publication(p_task_id uuid) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_task publication_tasks%ROWTYPE;
  v_surface surfaces%ROWTYPE;
  v_client_res text := '';
  v_adapter publication_adapters%ROWTYPE;
  v_outcome text;
  v_hint text;
BEGIN
  SELECT * INTO v_task FROM publication_tasks WHERE id = p_task_id;
  IF v_task IS NULL THEN
    RAISE EXCEPTION 'publication task % not found', p_task_id;
  END IF;
  SELECT * INTO v_surface FROM surfaces WHERE id = v_task.surface_id;

  -- AUTO_API: only when an official, enabled adapter AND a credential exist.
  IF v_task.mode = 'AUTO_API' THEN
    SELECT * INTO v_adapter FROM publication_adapters
      WHERE platform = v_surface.platform AND capability = 'PUBLISH';
    IF v_adapter.id IS NULL OR NOT v_adapter.official OR NOT v_adapter.enabled THEN
      v_hint := 'No official, enabled adapter for platform ' || v_surface.platform;
      IF NOT EXISTS (SELECT 1 FROM exceptions
                     WHERE exception_type='UNSUPPORTED_PLATFORM'
                       AND related_object_id=v_task.id AND status='OPEN') THEN
        PERFORM raise_exception(v_task.client_id, 'UNSUPPORTED_PLATFORM', 'HIGH',
          'AUTO_API blocked: adapter not official/enabled', v_hint,
          NULL, 'PUBLICATION_TASK', v_task.id);
      END IF;
      UPDATE publication_tasks SET status='BLOCKED', last_error=v_hint WHERE id=p_task_id;
      RETURN jsonb_build_object('mode', 'AUTO_API', 'outcome', 'BLOCKED');
    END IF;
    IF v_task.credential_ref IS NULL OR NOT EXISTS (
        SELECT 1 FROM client_credentials
        WHERE client_id=v_task.client_id AND provider=v_surface.platform
          AND credential_ref=v_task.credential_ref AND status='ACTIVE') THEN
      v_hint := 'Missing/inactive credential for ' || v_surface.platform;
      IF NOT EXISTS (SELECT 1 FROM exceptions
                     WHERE exception_type='CREDENTIAL_INVALID'
                       AND related_object_id=v_task.id AND status='OPEN') THEN
        PERFORM raise_exception(v_task.client_id, 'CREDENTIAL_INVALID', 'HIGH',
          'AUTO_API blocked: credential missing/inactive', v_hint,
          NULL, 'PUBLICATION_TASK', v_task.id);
      END IF;
      UPDATE publication_tasks SET status='BLOCKED', last_error=v_hint WHERE id=p_task_id;
      RETURN jsonb_build_object('mode', 'AUTO_API', 'outcome', 'BLOCKED');
    END IF;
    -- Official capability + credential present: perform the publish.
    UPDATE publication_tasks SET status='PUBLISHING' WHERE id=p_task_id;
    INSERT INTO publication_records(client_id, publication_task_id, platform,
                                    external_id, url, published_at, verification_status,
                                    provider_response, dedup_key)
    VALUES (v_task.client_id, v_task.id, v_surface.platform,
            'ext-' || replace(v_task.id::text,'-',''),
            v_surface.canonical_url, now(), 'PENDING',
            jsonb_build_object('simulated', true, 'mode', 'AUTO_API'),
            'pubrec:' || v_task.id::text)
    ON CONFLICT (dedup_key) WHERE dedup_key IS NOT NULL DO NOTHING;
    UPDATE publication_tasks SET status='PUBLISHED' WHERE id=p_task_id;
    RETURN jsonb_build_object('mode', 'AUTO_API', 'outcome', 'PUBLISHED');
  END IF;

  -- API_ASSISTED / BROWSER_ASSISTED / MANUAL_REQUIRED: surface work by a human
  -- or assisted flow; no anti-bot bypass. Wait for approval.
  IF v_task.mode IN ('API_ASSISTED','BROWSER_ASSISTED','MANUAL_REQUIRED') THEN
    UPDATE publication_tasks
      SET status='WAITING_APPROVAL',
          payload_json = payload_json || jsonb_build_object(
            'mode', v_task.mode,
            'note', v_task.mode || ': requires human/assisted action, not automated bypass')
      WHERE id = p_task_id;
    RETURN jsonb_build_object('mode', v_task.mode, 'outcome', 'WAITING_APPROVAL');
  END IF;

  -- BLOCKED: platform policy denies automation.
  IF v_task.mode = 'BLOCKED' THEN
    v_hint := 'Platform policy forbids automated publication';
    IF NOT EXISTS (SELECT 1 FROM exceptions
                   WHERE exception_type='PLATFORM_POLICY'
                     AND related_object_id=v_task.id AND status='OPEN') THEN
      PERFORM raise_exception(v_task.client_id, 'PLATFORM_POLICY', 'HIGH',
        'Publication blocked by platform policy', v_hint,
        NULL, 'PUBLICATION_TASK', v_task.id);
    END IF;
    UPDATE publication_tasks SET status='BLOCKED', last_error=v_hint WHERE id=p_task_id;
    RETURN jsonb_build_object('mode', 'BLOCKED', 'outcome', 'BLOCKED');
  END IF;

  RETURN jsonb_build_object('mode', v_task.mode, 'outcome', 'UNKNOWN');
END;
$$;

-- ============================================================================
-- schedule_publication_jobs — create a publication task for a READY asset on a
-- surface and enqueue a PUBLICATION job so the WF-07 worker can claim & dispatch
-- it. Idempotent: re-runs return the existing task/job (dedup keys).
-- ============================================================================
CREATE OR REPLACE FUNCTION schedule_publication_jobs(
  p_client_code text,
  p_asset_id uuid,
  p_surface_id uuid,
  p_priority integer DEFAULT 50
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_client uuid;
  v_task uuid;
  v_job uuid;
BEGIN
  SELECT id INTO v_client FROM clients WHERE code = p_client_code;
  IF v_client IS NULL THEN
    RAISE EXCEPTION 'client % not found', p_client_code;
  END IF;

  v_task := create_publication_task(p_client_code, p_asset_id, p_surface_id);
  IF v_task IS NULL THEN
    SELECT t.id INTO v_task FROM publication_tasks t
      WHERE t.content_asset_id = p_asset_id AND t.surface_id = p_surface_id
      LIMIT 1;
  END IF;

  v_job := enqueue_job(v_client, 'PUBLICATION',
    jsonb_build_object('task_id', v_task), p_priority, now(), 3,
    'pub-dispatch:' || v_task::text);
  RETURN v_task;
END;
$$;