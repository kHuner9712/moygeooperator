from __future__ import annotations

import sqlite3
from collections.abc import Iterator
from contextlib import closing, contextmanager
from pathlib import Path
from typing import Any

SCHEMA = """
CREATE TABLE IF NOT EXISTS tenants (
 id TEXT PRIMARY KEY, name TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'ACTIVE',
 created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS approvals (
 id TEXT PRIMARY KEY, tenant_id TEXT NOT NULL REFERENCES tenants(id),
 stage TEXT NOT NULL, resource_type TEXT NOT NULL, resource_id TEXT NOT NULL,
 status TEXT NOT NULL CHECK(status IN ('PENDING','APPROVED','REJECTED')),
 requested_at TEXT NOT NULL, decided_at TEXT, actor TEXT, note TEXT
);
CREATE INDEX IF NOT EXISTS idx_approvals_pending ON approvals(tenant_id,status,requested_at);
CREATE TABLE IF NOT EXISTS discovery_evidence (
 id TEXT PRIMARY KEY, tenant_id TEXT NOT NULL REFERENCES tenants(id),
 source_url TEXT NOT NULL, captured_at TEXT NOT NULL, raw_text_path TEXT NOT NULL,
 screenshot_path TEXT NOT NULL, source_type TEXT NOT NULL,
 credibility_status TEXT NOT NULL CHECK(credibility_status='AI_PENDING'),
 content_sha256 TEXT NOT NULL, screenshot_sha256 TEXT NOT NULL,
 collection_status TEXT NOT NULL, collection_error TEXT, created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_evidence_tenant ON discovery_evidence(tenant_id,captured_at);
CREATE TABLE IF NOT EXISTS source_assets (
 id TEXT PRIMARY KEY, tenant_id TEXT NOT NULL REFERENCES tenants(id),
 original_name TEXT NOT NULL, media_type TEXT NOT NULL, relative_path TEXT NOT NULL,
 extracted_text_path TEXT, content_sha256 TEXT NOT NULL, size INTEGER NOT NULL,
 extraction_status TEXT NOT NULL, metadata_json TEXT NOT NULL DEFAULT '{}',
 created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_source_assets_tenant ON source_assets(tenant_id,created_at);
CREATE TABLE IF NOT EXISTS website_pages (
 id TEXT PRIMARY KEY, tenant_id TEXT NOT NULL REFERENCES tenants(id),
 crawl_id TEXT NOT NULL, source_url TEXT NOT NULL, final_url TEXT,
 title TEXT, text_path TEXT, content_sha256 TEXT,
 status TEXT NOT NULL, error TEXT, captured_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_website_pages_tenant ON website_pages(tenant_id,captured_at);
CREATE TABLE IF NOT EXISTS platform_calibrations (
 id TEXT PRIMARY KEY, tenant_id TEXT NOT NULL REFERENCES tenants(id),
 platform TEXT NOT NULL, account_id TEXT NOT NULL, stage TEXT NOT NULL,
 page_url TEXT NOT NULL, origin TEXT NOT NULL, relative_path TEXT NOT NULL,
 privacy TEXT NOT NULL, created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_platform_calibrations
 ON platform_calibrations(tenant_id,platform,account_id,created_at);
CREATE TABLE IF NOT EXISTS executions (
 id TEXT PRIMARY KEY, tenant_id TEXT NOT NULL REFERENCES tenants(id),
 task_package_id TEXT, platform TEXT NOT NULL, account_id TEXT NOT NULL,
 state TEXT NOT NULL, resume_state TEXT, paused_from_state TEXT, pause_reason TEXT,
 approval_id TEXT, task_id TEXT, version INTEGER NOT NULL DEFAULT 1,
 created_at TEXT NOT NULL, updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_executions_tenant ON executions(tenant_id,updated_at);
CREATE INDEX IF NOT EXISTS idx_executions_platform_gate
 ON executions(tenant_id,platform,account_id,state,pause_reason);
CREATE UNIQUE INDEX IF NOT EXISTS idx_execution_task ON executions(task_id) WHERE task_id IS NOT NULL;
CREATE TABLE IF NOT EXISTS execution_events (
 sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
 execution_id TEXT NOT NULL REFERENCES executions(id), event_type TEXT NOT NULL,
 from_state TEXT, to_state TEXT, payload_json TEXT NOT NULL, created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_execution_events ON execution_events(execution_id,sequence);
CREATE TABLE IF NOT EXISTS side_effects (
 id TEXT PRIMARY KEY, execution_id TEXT NOT NULL REFERENCES executions(id),
 effect_type TEXT NOT NULL, idempotency_key TEXT NOT NULL,
 status TEXT NOT NULL CHECK(status IN ('INTENT','CONFIRMED')),
 observation_json TEXT NOT NULL, created_at TEXT NOT NULL, confirmed_at TEXT,
 UNIQUE(execution_id,effect_type,idempotency_key)
);
CREATE TABLE IF NOT EXISTS response_checkpoints (
 id TEXT PRIMARY KEY, execution_id TEXT NOT NULL REFERENCES executions(id),
 sequence INTEGER NOT NULL, relative_path TEXT NOT NULL, content_sha256 TEXT NOT NULL,
 page_url TEXT, captured_at TEXT NOT NULL, UNIQUE(execution_id,sequence)
);
CREATE TABLE IF NOT EXISTS results (
 id TEXT PRIMARY KEY, execution_id TEXT NOT NULL UNIQUE REFERENCES executions(id),
 tenant_id TEXT NOT NULL REFERENCES tenants(id), relative_path TEXT NOT NULL,
 content_sha256 TEXT NOT NULL, completion_signals_json TEXT NOT NULL, saved_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS artifacts (
 id TEXT PRIMARY KEY, tenant_id TEXT NOT NULL REFERENCES tenants(id),
 artifact_type TEXT NOT NULL, relative_path TEXT NOT NULL,
 sha256 TEXT NOT NULL, size INTEGER NOT NULL, media_type TEXT NOT NULL,
 created_at TEXT NOT NULL, UNIQUE(tenant_id,relative_path)
);
CREATE INDEX IF NOT EXISTS idx_artifacts_tenant ON artifacts(tenant_id,created_at);
CREATE TABLE IF NOT EXISTS exports (
 id TEXT PRIMARY KEY, tenant_id TEXT NOT NULL REFERENCES tenants(id),
 package_type TEXT NOT NULL, relative_path TEXT NOT NULL, sha256 TEXT NOT NULL,
 created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS client_profiles (
 id TEXT PRIMARY KEY, tenant_id TEXT NOT NULL REFERENCES tenants(id),
 profile_json TEXT NOT NULL, status TEXT NOT NULL, approval_id TEXT NOT NULL,
 source_asset_ids_json TEXT NOT NULL DEFAULT '[]',
 website_page_ids_json TEXT NOT NULL DEFAULT '[]',
 created_at TEXT NOT NULL, updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_client_profiles_tenant
 ON client_profiles(tenant_id,created_at);
CREATE TABLE IF NOT EXISTS task_packages (
 id TEXT PRIMARY KEY, tenant_id TEXT NOT NULL REFERENCES tenants(id),
 package_id TEXT NOT NULL, schema_version TEXT NOT NULL, source_path TEXT NOT NULL,
 package_sha256 TEXT NOT NULL, status TEXT NOT NULL, approval_id TEXT,
 imported_at TEXT NOT NULL, UNIQUE(tenant_id,package_id), UNIQUE(tenant_id,package_sha256)
);
CREATE TABLE IF NOT EXISTS tasks (
 id TEXT PRIMARY KEY, tenant_id TEXT NOT NULL REFERENCES tenants(id),
 task_package_id TEXT NOT NULL REFERENCES task_packages(id),
 external_task_id TEXT NOT NULL, prompt TEXT NOT NULL, platform TEXT NOT NULL,
 account_id TEXT NOT NULL, sequence INTEGER NOT NULL, metadata_json TEXT NOT NULL,
 idempotency_key TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'PENDING',
 created_at TEXT NOT NULL, UNIQUE(task_package_id,external_task_id),
 UNIQUE(tenant_id,platform,idempotency_key)
);
CREATE INDEX IF NOT EXISTS idx_tasks_ready
 ON tasks(tenant_id,platform,status,sequence);
CREATE TABLE IF NOT EXISTS execution_leases (
 execution_id TEXT PRIMARY KEY REFERENCES executions(id), worker_id TEXT NOT NULL,
 acquired_at TEXT NOT NULL, heartbeat_at TEXT NOT NULL, expires_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS session_locks (
 session_key TEXT PRIMARY KEY, execution_id TEXT NOT NULL REFERENCES executions(id),
 worker_id TEXT NOT NULL, acquired_at TEXT NOT NULL, heartbeat_at TEXT NOT NULL,
 expires_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS browser_sessions (
 id TEXT PRIMARY KEY, tenant_id TEXT NOT NULL REFERENCES tenants(id),
 platform TEXT NOT NULL, account_id TEXT NOT NULL, status TEXT NOT NULL,
 profile_path TEXT NOT NULL, updated_at TEXT NOT NULL,
 UNIQUE(tenant_id,platform,account_id)
);
CREATE TABLE IF NOT EXISTS runtime_workers (
 worker_id TEXT PRIMARY KEY, worker_type TEXT NOT NULL, status TEXT NOT NULL,
 started_at TEXT NOT NULL, heartbeat_at TEXT NOT NULL, stopped_at TEXT,
 details_json TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS idx_runtime_workers_type_heartbeat
 ON runtime_workers(worker_type,heartbeat_at);
"""


class Database:
    def __init__(self, path: Path) -> None:
        self.path = path

    def connect(self) -> sqlite3.Connection:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        connection = sqlite3.connect(self.path, timeout=30)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys=ON")
        connection.execute("PRAGMA journal_mode=WAL")
        connection.execute("PRAGMA busy_timeout=30000")
        return connection

    def initialize(self) -> None:
        with closing(self.connect()) as connection:
            connection.executescript(SCHEMA)
            self._ensure_column(connection, "executions", "task_id", "TEXT")
            self._ensure_column(connection, "response_checkpoints", "response_locator", "TEXT")
            self._ensure_column(connection, "response_checkpoints", "screenshot_path", "TEXT")
            self._ensure_column(connection, "results", "task_id", "TEXT")
            self._ensure_column(connection, "results", "screenshot_path", "TEXT")
            self._ensure_column(
                connection, "results", "metadata_json", "TEXT NOT NULL DEFAULT '{}'"
            )
            self._ensure_column(
                connection, "client_profiles", "source_asset_ids_json",
                "TEXT NOT NULL DEFAULT '[]'",
            )
            self._ensure_column(
                connection, "client_profiles", "website_page_ids_json",
                "TEXT NOT NULL DEFAULT '[]'",
            )
            connection.execute(
                "CREATE UNIQUE INDEX IF NOT EXISTS idx_execution_task "
                "ON executions(task_id) WHERE task_id IS NOT NULL"
            )
            connection.commit()

    @staticmethod
    def _ensure_column(
        connection: sqlite3.Connection, table: str, column: str, declaration: str
    ) -> None:
        existing = {row[1] for row in connection.execute(f"PRAGMA table_info({table})")}
        if column not in existing:
            connection.execute(f"ALTER TABLE {table} ADD COLUMN {column} {declaration}")

    @contextmanager
    def transaction(self) -> Iterator[sqlite3.Connection]:
        connection = self.connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            yield connection
            connection.commit()
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def all(self, sql: str, params: tuple[Any, ...] = ()) -> list[dict[str, Any]]:
        with closing(self.connect()) as connection:
            return [dict(row) for row in connection.execute(sql, params).fetchall()]

    def one(self, sql: str, params: tuple[Any, ...] = ()) -> dict[str, Any] | None:
        with closing(self.connect()) as connection:
            row = connection.execute(sql, params).fetchone()
            return dict(row) if row else None
