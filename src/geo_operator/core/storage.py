from __future__ import annotations

import hashlib
import os
import tempfile
from pathlib import Path


class ArtifactStore:
    def __init__(self, data_root: Path) -> None:
        self.data_root = data_root.resolve()
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
            "source",
            "profile",
            "discovery/text",
            "discovery/screenshots",
            "tasks",
            "results/checkpoints",
            "results/screenshots",
            "exports",
            "sessions",
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
        return target, hashlib.sha256(content).hexdigest()
