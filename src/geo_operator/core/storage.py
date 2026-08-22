from __future__ import annotations

import hashlib
import mimetypes
import os
import tempfile
import uuid
from pathlib import Path
from typing import TYPE_CHECKING

from geo_operator.core.time import utc_now

if TYPE_CHECKING:
    from geo_operator.core.db import Database


class ArtifactStore:
    def __init__(self, data_root: Path, database: Database | None = None) -> None:
        self.data_root = data_root.resolve()
        self.database = database
        self.tenants_root = self.data_root / "tenants"
        self.tenants_root.mkdir(parents=True, exist_ok=True)

    def tenant_root(self, tenant_id: str) -> Path:
        allowed = "abcdefghijklmnopqrstuvwxyz0123456789-"
        if not tenant_id or any(char not in allowed for char in tenant_id):
            raise ValueError("Invalid tenant_id")
        root = (self.tenants_root / tenant_id).resolve()
        if not root.is_relative_to(self.tenants_root):
            raise ValueError("Tenant path escapes data root")
        return root

    def initialize_tenant(self, tenant_id: str) -> Path:
        root = self.tenant_root(tenant_id)
        for name in (
            "source", "source/extracted", "website/text", "profile",
            "discovery/text", "discovery/screenshots", "tasks",
            "results/checkpoints", "results/screenshots", "exports", "sessions",
        ):
            (root / name).mkdir(parents=True, exist_ok=True)
        return root

    def resolve(self, tenant_id: str, relative_path: str) -> Path:
        root = self.tenant_root(tenant_id)
        path = (root / relative_path).resolve()
        if not path.is_relative_to(root):
            raise ValueError("Artifact path escapes tenant root")
        return path

    def atomic_write(self, tenant_id: str, relative_path: str, content: bytes) -> tuple[Path, str]:
        target = self.resolve(tenant_id, relative_path)
        target.parent.mkdir(parents=True, exist_ok=True)
        handle, temporary = tempfile.mkstemp(prefix=f".{target.name}.", dir=target.parent)
        try:
            with os.fdopen(handle, "wb") as stream:
                stream.write(content)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, target)
        except Exception:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass
            raise
        digest = hashlib.sha256(content).hexdigest()
        self.record(tenant_id, relative_path, digest, len(content))
        return target, digest

    def record_existing(self, tenant_id: str, relative_path: str) -> str:
        path = self.resolve(tenant_id, relative_path)
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        self.record(tenant_id, relative_path, digest, path.stat().st_size)
        return digest

    def record(self, tenant_id: str, relative_path: str, digest: str, size: int) -> None:
        if self.database is None:
            return
        artifact_type = relative_path.split("/", 1)[0].upper()
        media_type = mimetypes.guess_type(relative_path)[0] or "application/octet-stream"
        with self.database.transaction() as connection:
            connection.execute(
                """INSERT INTO artifacts(
                   id,tenant_id,artifact_type,relative_path,sha256,size,media_type,created_at)
                   VALUES (?,?,?,?,?,?,?,?)
                   ON CONFLICT(tenant_id,relative_path) DO UPDATE SET
                   artifact_type=excluded.artifact_type,sha256=excluded.sha256,
                   size=excluded.size,media_type=excluded.media_type,
                   created_at=excluded.created_at""",
                (
                    uuid.uuid4().hex, tenant_id, artifact_type, relative_path,
                    digest, size, media_type, utc_now(),
                ),
            )
