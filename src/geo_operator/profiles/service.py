from __future__ import annotations

import hashlib
import json
import os
import tempfile
import uuid
import zipfile
from pathlib import Path
from typing import Any

from geo_operator.core.db import Database
from geo_operator.core.storage import ArtifactStore
from geo_operator.core.time import utc_now
from geo_operator.domain import ApprovalStage


class ClientProfileService:
    def __init__(self, database: Database, artifacts: ArtifactStore) -> None:
        self.database, self.artifacts = database, artifacts

    def save_draft(self, tenant_id: str, profile: dict[str, Any]) -> dict[str, Any]:
        if not self.database.one("SELECT id FROM tenants WHERE id=?", (tenant_id,)):
            raise KeyError("Tenant not found")
        if not profile:
            raise ValueError("Client profile cannot be empty")
        profile_id, approval_id, now = uuid.uuid4().hex, uuid.uuid4().hex, utc_now()
        content = json.dumps(profile, ensure_ascii=False, indent=2).encode()
        relative = f"profile/{profile_id}.json"
        self.artifacts.atomic_write(tenant_id, relative, content)
        with self.database.transaction() as connection:
            connection.execute(
                """INSERT INTO client_profiles(
                   id,tenant_id,profile_json,status,approval_id,created_at,updated_at)
                   VALUES (?,?,?,'WAIT_HUMAN_APPROVAL',?,?,?)""",
                (profile_id, tenant_id, content.decode(), approval_id, now, now),
            )
            connection.execute(
                """INSERT INTO approvals(
                   id,tenant_id,stage,resource_type,resource_id,status,requested_at)
                   VALUES (?,?,?,?,?,'PENDING',?)""",
                (
                    approval_id,
                    tenant_id,
                    ApprovalStage.CLIENT_PROFILE_REVIEW.value,
                    "client_profile",
                    profile_id,
                    now,
                ),
            )
        return self.get(profile_id)

    def mark_decision(self, profile_id: str, approved: bool) -> dict[str, Any]:
        with self.database.transaction() as connection:
            row = connection.execute(
                "SELECT * FROM client_profiles WHERE id=?", (profile_id,)
            ).fetchone()
            if not row:
                raise KeyError("Client profile not found")
            if row["status"] != "WAIT_HUMAN_APPROVAL":
                raise ValueError("Client profile decision has already been applied")
            connection.execute(
                "UPDATE client_profiles SET status=?,updated_at=? WHERE id=?",
                ("APPROVED" if approved else "REJECTED", utc_now(), profile_id),
            )
        return self.get(profile_id)

    def latest(self, tenant_id: str) -> dict[str, Any] | None:
        row = self.database.one(
            """SELECT * FROM client_profiles WHERE tenant_id=?
               ORDER BY created_at DESC LIMIT 1""",
            (tenant_id,),
        )
        if row:
            row["profile"] = json.loads(str(row["profile_json"]))
        return row

    def get(self, profile_id: str) -> dict[str, Any]:
        row = self.database.one("SELECT * FROM client_profiles WHERE id=?", (profile_id,))
        if not row:
            raise KeyError("Client profile not found")
        row["profile"] = json.loads(str(row["profile_json"]))
        return row

    def has_approved(self, tenant_id: str) -> bool:
        return bool(
            self.database.one(
                """SELECT id FROM client_profiles WHERE tenant_id=? AND status='APPROVED'
               ORDER BY created_at DESC LIMIT 1""",
                (tenant_id,),
            )
        )

    def export(self, profile_id: str) -> Path:
        profile = self.get(profile_id)
        if profile["status"] != "APPROVED":
            raise ValueError("CLIENT_PROFILE_REVIEW approval is required")
        tenant_id = str(profile["tenant_id"])
        relative = f"exports/CLIENT_PROFILE_{profile_id}.zip"
        target = self.artifacts.resolve(tenant_id, relative)
        handle, temporary = tempfile.mkstemp(prefix=".client-profile.", dir=target.parent)
        os.close(handle)
        content = str(profile["profile_json"]).encode()
        try:
            with zipfile.ZipFile(temporary, "w", zipfile.ZIP_DEFLATED) as archive:
                archive.writestr("profile/client_profile.json", content)
                archive.writestr(
                    "manifest.json",
                    json.dumps(
                        {
                            "schema_version": "1.0",
                            "package_type": "CLIENT_PROFILE",
                            "tenant_id": tenant_id,
                            "profile_id": profile_id,
                            "created_at": utc_now(),
                            "files": [
                                {
                                    "path": "profile/client_profile.json",
                                    "sha256": hashlib.sha256(content).hexdigest(),
                                    "size": len(content),
                                }
                            ],
                        },
                        ensure_ascii=False,
                        indent=2,
                    ),
                )
            os.replace(temporary, target)
        except Exception:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass
            raise
        return target
