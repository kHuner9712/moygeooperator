-- ============================================================================
-- Stage 7 · SYNTHETIC Publishing — WF-07 vertical slice.
-- THIS DATA IS SYNTHETIC. Demonstrates mode-routed dispatch on the fictional
-- "合成测试精密工业有限公司" (SYNTH-ACME) using the OFFICIAL_SITE / AMAP surfaces
-- that already carry VERIFIED content assets (from Stage 6).
--  - OFFICIAL_SITE -> AUTO_API  (official adapter + credential)  -> PUBLISHED
--  - AMAP          -> BROWSER_ASSISTED                           -> WAITING_APPROVAL
--  - BAIDU_BAIKE   -> AUTO_API   (adapter NOT registered)        -> BLOCKED (fail closed)
--  - ALIBABA_1688  -> MANUAL_REQUIRED                            -> WAITING_APPROVAL
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

-- A canonical brief to reuse for surfaces that lack a content asset yet.
CREATE OR REPLACE FUNCTION __synth_brief() RETURNS uuid LANGUAGE sql AS $$
  SELECT id FROM content_briefs
  WHERE client_id=(SELECT id FROM clients WHERE code='SYNTH-ACME') LIMIT 1;
$$;

-- Register an OFFICIAL, enabled adapter for the official site (requires cred).
CREATE OR REPLACE FUNCTION __synth_adapters() RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_cid uuid;
BEGIN
  SELECT id INTO v_cid FROM clients WHERE code='SYNTH-ACME';
  PERFORM register_publication_adapter('OFFICIAL_SITE','PUBLISH',true,true,true,
    '{"provider_check": "official CMS API", "captcha": false}');
  INSERT INTO client_credentials(client_id, provider, credential_ref, status)
  VALUES (v_cid, 'OFFICIAL_SITE', 'cred-official-site-v1', 'ACTIVE')
  ON CONFLICT (client_id, provider, credential_ref) DO NOTHING;
END;
$$;
SELECT __synth_adapters();
DROP FUNCTION __synth_adapters();

-- Configure surface publication modes.
UPDATE surfaces s SET publication_mode='AUTO_API', credential_ref='cred-official-site-v1'
  WHERE s.platform='OFFICIAL_SITE'
    AND s.client_id=(SELECT id FROM clients WHERE code='SYNTH-ACME');
UPDATE surfaces s SET publication_mode='BROWSER_ASSISTED'
  WHERE s.platform='AMAP'
    AND s.client_id=(SELECT id FROM clients WHERE code='SYNTH-ACME');
UPDATE surfaces s SET publication_mode='AUTO_API'
  WHERE s.platform='BAIDU_BAIKE'
    AND s.client_id=(SELECT id FROM clients WHERE code='SYNTH-ACME');
UPDATE surfaces s SET publication_mode='MANUAL_REQUIRED'
  WHERE s.platform='ALIBABA_1688'
    AND s.client_id=(SELECT id FROM clients WHERE code='SYNTH-ACME');

-- Ensure content assets exist for BAIDU_BAIKE and ALIBABA_1688.
CREATE OR REPLACE FUNCTION __synth_assets() RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_brief uuid; v_asset uuid; v_surf uuid;
BEGIN
  v_brief := __synth_brief();
  FOR v_surf IN
    SELECT s.id FROM surfaces s
    WHERE s.client_id=(SELECT id FROM clients WHERE code='SYNTH-ACME')
      AND s.platform IN ('BAIDU_BAIKE','ALIBABA_1688')
  LOOP
    v_asset := generate_content_asset('SYNTH-ACME', v_brief, 'POST', v_surf);
    IF v_asset IS NULL THEN
      v_asset := (SELECT a.id FROM content_assets a
                  WHERE a.brief_id=v_brief AND a.surface_id=v_surf LIMIT 1);
    END IF;
  END LOOP;
END;
$$;
SELECT __synth_assets();
DROP FUNCTION __synth_assets();

-- Create + dispatch a publication task per target surface.
CREATE OR REPLACE FUNCTION __synth_dispatch() RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_asset uuid;
  v_surf uuid;
  v_task uuid;
BEGIN
  FOR v_surf, v_asset IN
    SELECT s.id, a.id
    FROM surfaces s
    JOIN content_assets a ON a.surface_id = s.id
    WHERE s.client_id=(SELECT id FROM clients WHERE code='SYNTH-ACME')
      AND s.platform IN ('OFFICIAL_SITE','AMAP','BAIDU_BAIKE','ALIBABA_1688')
      AND a.id = (SELECT a2.id FROM content_assets a2
                  WHERE a2.surface_id=s.id ORDER BY a2.id LIMIT 1)
  LOOP
    v_task := create_publication_task('SYNTH-ACME', v_asset, v_surf);
    IF v_task IS NOT NULL THEN
      PERFORM dispatch_publication(v_task);
    END IF;
  END LOOP;
END;
$$;
SELECT __synth_dispatch();
DROP FUNCTION __synth_dispatch();
DROP FUNCTION __synth_brief();

COMMIT;