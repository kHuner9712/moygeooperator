from __future__ import annotations

import shutil
import uuid
from typing import Any

from geo_operator.core.db import Database
from geo_operator.core.storage import ArtifactStore
from geo_operator.core.time import utc_now


class TenantService:
    def __init__(self, database: Database, artifacts: ArtifactStore) -> None:
        self.database, self.artifacts = database, artifacts

    def create(self, name: str) -> dict[str, object]:
        name = name.strip()
        if not name:
            raise ValueError("Tenant name is required")
        tenant_id, created_at = uuid.uuid4().hex, utc_now()
        self.artifacts.initialize_tenant(tenant_id)
        with self.database.transaction() as connection:
            connection.execute(
                "INSERT INTO tenants(id,name,status,created_at) VALUES (?,?,'ACTIVE',?)",
                (tenant_id, name, created_at),
            )
        return self.get(tenant_id)

    def get(self, tenant_id: str) -> dict[str, Any]:
        tenant = self.database.one("SELECT * FROM tenants WHERE id=?", (tenant_id,))
        if not tenant:
            raise KeyError("Tenant not found")
        return tenant

    def list(self) -> list[dict[str, object]]:
        return self.database.all("SELECT * FROM tenants ORDER BY created_at DESC")

    def begin_delete(self, tenant_id: str, confirm_name: str) -> dict[str, Any]:
        with self.database.transaction() as connection:
            tenant = connection.execute("SELECT * FROM tenants WHERE id=?", (tenant_id,)).fetchone()
            if not tenant:
                raise KeyError("Tenant not found")
            if confirm_name.strip() != tenant["name"]:
                raise ValueError("Customer name confirmation does not match")
            connection.execute(
                "UPDATE tenants SET status='DELETING' WHERE id=?",
                (tenant_id,),
            )
        return self.get(tenant_id)

    def has_active_leases(self, tenant_id: str) -> bool:
        row = self.database.one(
            """SELECT COUNT(*) AS count FROM execution_leases lease
               JOIN executions execution ON execution.id=lease.execution_id
               WHERE execution.tenant_id=?""",
            (tenant_id,),
        )
        return bool(row and int(row["count"]) > 0)

    def has_open_sessions(self, tenant_id: str) -> bool:
        row = self.database.one(
            """SELECT COUNT(*) AS count FROM browser_sessions
               WHERE tenant_id=? AND status='OPEN'""",
            (tenant_id,),
        )
        return bool(row and int(row["count"]) > 0)

    def purge(self, tenant_id: str) -> dict[str, Any]:
        tenant = self.get(tenant_id)
        if tenant["status"] != "DELETING":
            raise ValueError("Tenant must be marked DELETING before purge")
        if self.has_active_leases(tenant_id):
            raise ValueError("Tenant still has an active browser execution")

        root = self.artifacts.tenant_root(tenant_id)
        if root.exists():
            shutil.rmtree(root)

        deleted: dict[str, int] = {}
        statements = (
            (
                "session_locks",
                """DELETE FROM session_locks WHERE execution_id IN
                   (SELECT id FROM executions WHERE tenant_id=?)""",
            ),
            (
                "execution_leases",
                """DELETE FROM execution_leases WHERE execution_id IN
                   (SELECT id FROM executions WHERE tenant_id=?)""",
            ),
            (
                "response_checkpoints",
                """DELETE FROM response_checkpoints WHERE execution_id IN
                   (SELECT id FROM executions WHERE tenant_id=?)""",
            ),
            (
                "side_effects",
                """DELETE FROM side_effects WHERE execution_id IN
                   (SELECT id FROM executions WHERE tenant_id=?)""",
            ),
            (
                "execution_events",
                """DELETE FROM execution_events WHERE execution_id IN
                   (SELECT id FROM executions WHERE tenant_id=?)""",
            ),
            ("results", "DELETE FROM results WHERE tenant_id=?"),
            ("executions", "DELETE FROM executions WHERE tenant_id=?"),
            ("tasks", "DELETE FROM tasks WHERE tenant_id=?"),
            ("task_packages", "DELETE FROM task_packages WHERE tenant_id=?"),
            ("client_profiles", "DELETE FROM client_profiles WHERE tenant_id=?"),
            ("platform_calibrations", "DELETE FROM platform_calibrations WHERE tenant_id=?"),
            ("browser_sessions", "DELETE FROM browser_sessions WHERE tenant_id=?"),
            ("exports", "DELETE FROM exports WHERE tenant_id=?"),
            ("artifacts", "DELETE FROM artifacts WHERE tenant_id=?"),
            ("discovery_evidence", "DELETE FROM discovery_evidence WHERE tenant_id=?"),
            ("website_pages", "DELETE FROM website_pages WHERE tenant_id=?"),
            ("source_assets", "DELETE FROM source_assets WHERE tenant_id=?"),
            ("approvals", "DELETE FROM approvals WHERE tenant_id=?"),
        )
        with self.database.transaction() as connection:
            current = connection.execute(
                "SELECT status FROM tenants WHERE id=?", (tenant_id,)
            ).fetchone()
            if not current or current["status"] != "DELETING":
                raise ValueError("Tenant deletion state changed during purge")
            for table, sql in statements:
                deleted[table] = connection.execute(sql, (tenant_id,)).rowcount
            deleted["tenants"] = connection.execute(
                "DELETE FROM tenants WHERE id=? AND status='DELETING'",
                (tenant_id,),
            ).rowcount
            if deleted["tenants"] != 1:
                raise RuntimeError("Tenant was not deleted")

        if root.exists():
            shutil.rmtree(root)
        return {
            "status": "deleted",
            "tenant_id": tenant_id,
            "name": tenant["name"],
            "deleted_rows": deleted,
        }
