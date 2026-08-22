import uuid

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
        return self.database.one("SELECT * FROM tenants WHERE id=?", (tenant_id,)) or {}

    def list(self) -> list[dict[str, object]]:
        return self.database.all("SELECT * FROM tenants ORDER BY created_at DESC")
