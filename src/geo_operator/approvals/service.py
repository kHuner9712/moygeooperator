import uuid

from geo_operator.core.db import Database
from geo_operator.core.time import utc_now
from geo_operator.domain import ApprovalStage


class ApprovalService:
    def __init__(self, database: Database) -> None:
        self.database = database

    def request(
        self, tenant_id: str, stage: ApprovalStage, resource_type: str, resource_id: str
    ) -> dict[str, object]:
        with self.database.transaction() as connection:
            existing = connection.execute(
                """SELECT * FROM approvals WHERE tenant_id=? AND stage=?
                   AND resource_type=? AND resource_id=? AND status='PENDING'""",
                (tenant_id, stage.value, resource_type, resource_id),
            ).fetchone()
            if existing:
                return dict(existing)
            approval_id = uuid.uuid4().hex
            connection.execute(
                """INSERT INTO approvals(id,tenant_id,stage,resource_type,resource_id,
                   status,requested_at) VALUES (?,?,?,?,?,'PENDING',?)""",
                (approval_id, tenant_id, stage.value, resource_type, resource_id, utc_now()),
            )
        return self.get(approval_id)

    def decide(
        self, approval_id: str, approved: bool, actor: str, note: str = ""
    ) -> dict[str, object]:
        if not actor.strip():
            raise ValueError("Approval actor is required")
        with self.database.transaction() as connection:
            row = connection.execute(
                "SELECT * FROM approvals WHERE id=?", (approval_id,)
            ).fetchone()
            if not row:
                raise KeyError("Approval not found")
            if row["status"] != "PENDING":
                raise ValueError("Approval has already been decided")
            connection.execute(
                "UPDATE approvals SET status=?,decided_at=?,actor=?,note=? WHERE id=?",
                (
                    "APPROVED" if approved else "REJECTED",
                    utc_now(),
                    actor.strip(),
                    note,
                    approval_id,
                ),
            )
        return self.get(approval_id)

    def get(self, approval_id: str) -> dict[str, object]:
        row = self.database.one("SELECT * FROM approvals WHERE id=?", (approval_id,))
        if not row:
            raise KeyError("Approval not found")
        return row

    def list_pending(self) -> list[dict[str, object]]:
        return self.database.all(
            "SELECT * FROM approvals WHERE status='PENDING' ORDER BY requested_at"
        )
