-- ============================================================================
-- MOY GEO Operator — Internal · Migration 001 · Core schema
-- System of Record. Faithful to the design schema (02_DATABASE_SCHEMA.sql),
-- plus: idempotency constraints and queue helpers for jobs/exceptions.
-- Runner keeps its own bookkeeping in schema_migrations (not created here).
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------- Enums ----------
CREATE TYPE client_status AS ENUM ('ONBOARDING','ACTIVE','PAUSED','ARCHIVED');
CREATE TYPE verification_state AS ENUM ('DRAFT','VERIFIED','REJECTED','SUPERSEDED');
CREATE TYPE job_status AS ENUM ('PENDING','RUNNING','RETRY_WAIT','SUCCEEDED','FAILED','CANCELLED');
CREATE TYPE action_status AS ENUM ('PROPOSED','APPROVED','IN_PROGRESS','DONE','BLOCKED','CANCELLED');
CREATE TYPE publication_mode AS ENUM ('AUTO_API','API_ASSISTED','BROWSER_ASSISTED','MANUAL_REQUIRED','BLOCKED');
CREATE TYPE publication_status AS ENUM ('DRAFT','READY','WAITING_APPROVAL','PUBLISHING','PUBLISHED','VERIFIED','FAILED','BLOCKED');
CREATE TYPE observation_kind AS ENUM ('API_OBSERVATION','UI_OBSERVATION','MANUAL_OBSERVATION');
CREATE TYPE exception_severity AS ENUM ('LOW','MEDIUM','HIGH','CRITICAL');

-- ---------- Clients ----------
CREATE TABLE clients (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code text NOT NULL UNIQUE,
  legal_name text NOT NULL,
  display_name text NOT NULL,
  status client_status NOT NULL DEFAULT 'ONBOARDING',
  primary_region text,
  primary_language text,
  timezone text NOT NULL DEFAULT 'Asia/Shanghai',
  target_markets jsonb NOT NULL DEFAULT '[]',
  target_languages jsonb NOT NULL DEFAULT '[]',
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE client_credentials (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id uuid NOT NULL REFERENCES clients(id),
  provider text NOT NULL,
  credential_ref text NOT NULL,        -- reference only; the secret lives outside PG
  status text NOT NULL DEFAULT 'ACTIVE',
  expires_at timestamptz,
  metadata jsonb NOT NULL DEFAULT '{}',
  UNIQUE(client_id, provider, credential_ref)
);

-- ---------- Truth ----------
CREATE TABLE truth_documents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id uuid NOT NULL REFERENCES clients(id),
  document_type text NOT NULL,
  title text NOT NULL,
  source_uri text,
  file_path text,
  checksum text,
  provided_by text,
  received_at timestamptz NOT NULL DEFAULT now(),
  parsed_at timestamptz,
  status text NOT NULL DEFAULT 'RECEIVED',
  metadata jsonb NOT NULL DEFAULT '{}'
);

CREATE TABLE entities (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id uuid NOT NULL REFERENCES clients(id),
  entity_type text NOT NULL,
  canonical_name text NOT NULL,
  aliases jsonb NOT NULL DEFAULT '[]',
  external_ids jsonb NOT NULL DEFAULT '{}',
  status text NOT NULL DEFAULT 'ACTIVE',
  metadata jsonb NOT NULL DEFAULT '{}',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(client_id, entity_type, canonical_name)
);

CREATE TABLE claims (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id uuid NOT NULL REFERENCES clients(id),
  entity_id uuid REFERENCES entities(id),
  field_key text NOT NULL,
  claim_text text NOT NULL,
  normalized_value jsonb,
  verification verification_state NOT NULL DEFAULT 'DRAFT',
  valid_from timestamptz,
  valid_until timestamptz,
  supersedes_claim_id uuid REFERENCES claims(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE evidence_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id uuid NOT NULL REFERENCES clients(id),
  evidence_type text NOT NULL,
  source_kind text NOT NULL,
  source_uri text,
  truth_document_id uuid REFERENCES truth_documents(id),
  claim_id uuid REFERENCES claims(id),
  excerpt text,
  observed_at timestamptz,
  confidence numeric(5,4),
  checksum text,
  metadata jsonb NOT NULL DEFAULT '{}',
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE entity_relations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id uuid NOT NULL REFERENCES clients(id),
  from_entity_id uuid NOT NULL REFERENCES entities(id),
  relation_type text NOT NULL,
  to_entity_id uuid NOT NULL REFERENCES entities(id),
  evidence_id uuid REFERENCES evidence_items(id),
  confidence numeric(5,4),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(client_id, from_entity_id, relation_type, to_entity_id)
);

-- ---------- Surface / Resource ----------
CREATE TABLE surfaces (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id uuid NOT NULL REFERENCES clients(id),
  surface_type text NOT NULL,
  platform text NOT NULL,
  account_or_property text,
  canonical_url text,
  owner_entity_id uuid REFERENCES entities(id),
  publication_mode publication_mode NOT NULL DEFAULT 'MANUAL_REQUIRED',
  active boolean NOT NULL DEFAULT true,
  credential_ref text,
  metadata jsonb NOT NULL DEFAULT '{}',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE surface_resources (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id uuid NOT NULL REFERENCES clients(id),
  surface_id uuid NOT NULL REFERENCES surfaces(id),
  resource_type text NOT NULL,
  url text,
  external_id text,
  title text,
  published_at timestamptz,
  last_observed_at timestamptz,
  content_hash text,
  metadata jsonb NOT NULL DEFAULT '{}'
);

-- ---------- Engine ----------
CREATE TABLE engines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider text NOT NULL,
  product text NOT NULL,
  mode text NOT NULL,
  region text,
  language text,
  enabled boolean NOT NULL DEFAULT true,
  config jsonb NOT NULL DEFAULT '{}'
);

CREATE TABLE engine_surface_profiles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  engine_id uuid NOT NULL REFERENCES engines(id),
  surface_type text NOT NULL,
  region text,
  language text,
  observed_from date NOT NULL,
  observed_until date,
  evidence_count integer NOT NULL DEFAULT 0,
  confidence numeric(5,4),
  findings jsonb NOT NULL DEFAULT '{}',
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- ---------- Intent / Query ----------
CREATE TABLE intents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id uuid NOT NULL REFERENCES clients(id),
  entity_id uuid REFERENCES entities(id),
  intent_type text NOT NULL,
  label text NOT NULL,
  description text,
  commercial_score numeric(5,2),
  relevance_score numeric(5,2),
  opportunity_score numeric(5,2),
  priority_score numeric(5,2),
  status text NOT NULL DEFAULT 'ACTIVE',
  metadata jsonb NOT NULL DEFAULT '{}',
  UNIQUE(client_id, label)
);

CREATE TABLE queries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id uuid NOT NULL REFERENCES clients(id),
  intent_id uuid NOT NULL REFERENCES intents(id),
  query_text text NOT NULL,
  language text,
  region text,
  priority integer NOT NULL DEFAULT 50,
  active boolean NOT NULL DEFAULT true
);

-- ---------- Observation ----------
CREATE TABLE engine_observations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id uuid NOT NULL REFERENCES clients(id),
  engine_id uuid NOT NULL REFERENCES engines(id),
  query_id uuid NOT NULL REFERENCES queries(id),
  observation_kind observation_kind NOT NULL,
  observed_at timestamptz NOT NULL,
  run_key text NOT NULL,
  answer_text text,
  target_mentioned boolean,
  target_recommended boolean,
  position_hint integer,
  factuality_status text,
  citations jsonb NOT NULL DEFAULT '[]',
  cited_surface_ids jsonb NOT NULL DEFAULT '[]',
  evidence_uri text,
  raw_artifact_ref text,
  latency_ms integer,
  cost_amount numeric(12,6),
  metadata jsonb NOT NULL DEFAULT '{}',
  UNIQUE(client_id, engine_id, query_id, run_key)
);

-- ---------- Gap / Action ----------
CREATE TABLE geo_gaps (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id uuid NOT NULL REFERENCES clients(id),
  entity_id uuid REFERENCES entities(id),
  intent_id uuid REFERENCES intents(id),
  engine_id uuid REFERENCES engines(id),
  surface_id uuid REFERENCES surfaces(id),
  gap_type text NOT NULL,
  severity text NOT NULL,
  diagnosis text NOT NULL,
  evidence_refs jsonb NOT NULL DEFAULT '[]',
  status text NOT NULL DEFAULT 'OPEN',
  created_at timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz
);

CREATE TABLE geo_actions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id uuid NOT NULL REFERENCES clients(id),
  gap_id uuid REFERENCES geo_gaps(id),
  action_type text NOT NULL,
  title text NOT NULL,
  instructions text,
  priority integer NOT NULL DEFAULT 50,
  status action_status NOT NULL DEFAULT 'PROPOSED',
  target_surface_id uuid REFERENCES surfaces(id),
  target_intent_id uuid REFERENCES intents(id),
  due_at timestamptz,
  outcome_json jsonb,
  evidence_refs jsonb NOT NULL DEFAULT '[]',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- ---------- Content ----------
CREATE TABLE content_briefs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id uuid NOT NULL REFERENCES clients(id),
  action_id uuid REFERENCES geo_actions(id),
  intent_id uuid REFERENCES intents(id),
  target_entity_id uuid REFERENCES entities(id),
  canonical_angle text NOT NULL,
  required_claim_ids jsonb NOT NULL DEFAULT '[]',
  prohibited_claims jsonb NOT NULL DEFAULT '[]',
  target_surfaces jsonb NOT NULL DEFAULT '[]',
  status text NOT NULL DEFAULT 'DRAFT',
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE content_assets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id uuid NOT NULL REFERENCES clients(id),
  brief_id uuid NOT NULL REFERENCES content_briefs(id),
  surface_id uuid REFERENCES surfaces(id),
  format text NOT NULL,
  title text,
  body text NOT NULL,
  media_refs jsonb NOT NULL DEFAULT '[]',
  claim_ids jsonb NOT NULL DEFAULT '[]',
  fact_check_status text NOT NULL DEFAULT 'PENDING',
  compliance_status text NOT NULL DEFAULT 'PENDING',
  quality_score numeric(5,2),
  status text NOT NULL DEFAULT 'DRAFT',
  prompt_version text,
  model_provider text,
  model_name text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- ---------- Publication ----------
CREATE TABLE publication_tasks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id uuid NOT NULL REFERENCES clients(id),
  content_asset_id uuid NOT NULL REFERENCES content_assets(id),
  surface_id uuid NOT NULL REFERENCES surfaces(id),
  mode publication_mode NOT NULL,
  status publication_status NOT NULL DEFAULT 'DRAFT',
  scheduled_for timestamptz,
  credential_ref text,
  payload_json jsonb NOT NULL DEFAULT '{}',
  last_error text,
  attempts integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE publication_records (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id uuid NOT NULL REFERENCES clients(id),
  publication_task_id uuid NOT NULL REFERENCES publication_tasks(id),
  platform text NOT NULL,
  external_id text,
  url text,
  published_at timestamptz,
  verified_at timestamptz,
  verification_status text NOT NULL DEFAULT 'PENDING',
  provider_response jsonb,
  evidence_uri text,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- ---------- Report ----------
CREATE TABLE reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id uuid NOT NULL REFERENCES clients(id),
  report_type text NOT NULL,
  period_start date NOT NULL,
  period_end date NOT NULL,
  status text NOT NULL DEFAULT 'DRAFT',
  metrics jsonb NOT NULL DEFAULT '{}',
  summary_md text,
  artifact_path text,
  generated_at timestamptz
);

-- ---------- Jobs / Exceptions queue ----------
CREATE TABLE jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id uuid REFERENCES clients(id),
  job_type text NOT NULL,
  status job_status NOT NULL DEFAULT 'PENDING',
  priority integer NOT NULL DEFAULT 50,
  due_at timestamptz NOT NULL DEFAULT now(),
  payload_json jsonb NOT NULL DEFAULT '{}',
  attempts integer NOT NULL DEFAULT 0,
  max_attempts integer NOT NULL DEFAULT 3,
  lease_until timestamptz,
  unique_key text,
  last_error text,
  started_at timestamptz,
  finished_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE exceptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id uuid REFERENCES clients(id),
  exception_type text NOT NULL,
  severity exception_severity NOT NULL,
  status text NOT NULL DEFAULT 'OPEN',
  title text NOT NULL,
  detail text,
  source_job_id uuid REFERENCES jobs(id),
  related_object_type text,
  related_object_id uuid,
  due_at timestamptz,
  resolution text,
  created_at timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz
);

-- ---------- LLM / Cost ledger ----------
CREATE TABLE llm_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id uuid REFERENCES clients(id),
  task_type text NOT NULL,
  provider text NOT NULL,
  model text NOT NULL,
  prompt_version text NOT NULL,
  input_classification text NOT NULL,
  input_hash text,
  output_hash text,
  validation_status text,
  tokens_in integer,
  tokens_out integer,
  cost_amount numeric(12,6),
  latency_ms integer,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE cost_ledger (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id uuid REFERENCES clients(id),
  cost_type text NOT NULL,
  source_type text NOT NULL,
  source_id uuid,
  amount numeric(12,6) NOT NULL DEFAULT 0,
  currency text NOT NULL DEFAULT 'CNY',
  units numeric(18,6),
  unit_name text,
  occurred_at timestamptz NOT NULL DEFAULT now(),
  metadata jsonb NOT NULL DEFAULT '{}'
);

-- ---------- Indexes ----------
CREATE INDEX idx_jobs_due ON jobs(status, due_at, priority DESC);
CREATE INDEX idx_observations_lookup ON engine_observations(client_id, query_id, engine_id, observed_at DESC);
CREATE INDEX idx_exceptions_open ON exceptions(status, severity, due_at);
CREATE INDEX idx_publication_queue ON publication_tasks(status, scheduled_for);
CREATE INDEX idx_actions_open ON geo_actions(client_id, status, priority DESC);

-- Idempotency: one live job per unique_key (retry-safe enqueue).
CREATE UNIQUE INDEX uq_jobs_unique_key ON jobs(unique_key) WHERE unique_key IS NOT NULL;

-- ============================================================================
-- Queue helpers (Stage 1 infra)
-- ============================================================================

-- Enqueue a job. If a live job with the same unique_key exists, return it
-- instead of inserting a duplicate (deterministic idempotency).
CREATE OR REPLACE FUNCTION enqueue_job(
  p_client_id uuid,
  p_job_type text,
  p_payload jsonb DEFAULT '{}',
  p_priority integer DEFAULT 50,
  p_due_at timestamptz DEFAULT now(),
  p_max_attempts integer DEFAULT 3,
  p_unique_key text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_existing uuid;
  v_id uuid;
BEGIN
  IF p_unique_key IS NOT NULL THEN
    SELECT id INTO v_existing FROM jobs
      WHERE unique_key = p_unique_key
        AND status IN ('PENDING','RUNNING','RETRY_WAIT')
      LIMIT 1;
    IF v_existing IS NOT NULL THEN
      RETURN v_existing;
    END IF;
  END IF;

  INSERT INTO jobs(client_id, job_type, priority, due_at, payload_json, max_attempts, unique_key)
  VALUES (p_client_id, p_job_type, p_priority, p_due_at, p_payload, p_max_attempts, p_unique_key)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

-- Lease the highest-priority due job for a worker (atomic claim).
-- Returns a single job row or NULL; caller must clear lease_until on finish
-- via finish_job() or fail_job().
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
    attempts = attempts + 1,
    lease_until = now() + make_interval(secs => p_lease_seconds)
  WHERE id = (
    SELECT id FROM jobs
    WHERE status IN ('PENDING','RETRY_WAIT')
      AND due_at <= now()
      AND (lease_until IS NULL OR lease_until < now())
      AND (p_job_type IS NULL OR job_type = p_job_type)
    ORDER BY priority DESC, due_at ASC
    LIMIT 1
    FOR UPDATE SKIP LOCKED
  )
  RETURNING * INTO v_job;

  RETURN v_job;
END;
$$;

-- Mark a job succeeded.
CREATE OR REPLACE FUNCTION finish_job(p_job_id uuid) RETURNS void
LANGUAGE sql AS $$
  UPDATE jobs SET status='SUCCEEDED', finished_at=now(), lease_until=NULL, last_error=NULL
  WHERE id = p_job_id;
$$;

-- Mark a job failed; auto-retry via RETRY_WAIT until max_attempts, else FAILED.
-- Returns the final status so the caller can decide whether to raise an exception.
CREATE OR REPLACE FUNCTION fail_job(p_job_id uuid, p_error text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
  v_max int;
  v_attempts int;
BEGIN
  SELECT max_attempts, attempts INTO v_max, v_attempts FROM jobs WHERE id = p_job_id;
  IF v_attempts >= v_max THEN
    UPDATE jobs SET status='FAILED', finished_at=now(), lease_until=NULL, last_error=p_error
    WHERE id = p_job_id;
    RETURN 'FAILED';
  ELSE
    UPDATE jobs SET status='RETRY_WAIT', lease_until=NULL, last_error=p_error,
           due_at = now() + make_interval(secs => power(2, v_attempts) * 60)
    WHERE id = p_job_id;
    RETURN 'RETRY_WAIT';
  END IF;
END;
$$;

-- Record an exception (fail-closed). Prevents duplicate open exceptions of the same
-- type on the same object via a partial unique index.
CREATE OR REPLACE FUNCTION raise_exception(
  p_client_id uuid,
  p_exception_type text,
  p_severity exception_severity,
  p_title text,
  p_detail text DEFAULT NULL,
  p_source_job_id uuid DEFAULT NULL,
  p_related_object_type text DEFAULT NULL,
  p_related_object_id uuid DEFAULT NULL,
  p_due_at timestamptz DEFAULT now()
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_id uuid;
BEGIN
  INSERT INTO exceptions(client_id, exception_type, severity, title, detail,
                         source_job_id, related_object_type, related_object_id, due_at)
  VALUES (p_client_id, p_exception_type, p_severity, p_title, p_detail,
          p_source_job_id, p_related_object_type, p_related_object_id, p_due_at)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

-- Dedupe open exceptions: only one open exception per (type, related_object).
CREATE UNIQUE INDEX uq_exceptions_open_object
  ON exceptions(exception_type, related_object_id)
  WHERE status = 'OPEN' AND related_object_id IS NOT NULL;

-- Resolve an exception.
CREATE OR REPLACE FUNCTION resolve_exception(p_exception_id uuid, p_resolution text) RETURNS void
LANGUAGE sql AS $$
  UPDATE exceptions SET status='RESOLVED', resolution=p_resolution, resolved_at=now()
  WHERE id = p_exception_id AND status='OPEN';
$$;