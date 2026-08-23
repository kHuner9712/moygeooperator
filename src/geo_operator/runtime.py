from __future__ import annotations

import json
from datetime import UTC, datetime
from typing import Any

from geo_operator.core.db import Database
from geo_operator.core.time import utc_now

ACTIVE_WORKER_STATES = {"STARTING", "IDLE", "CHECKING", "BUSY"}


class RuntimeWorkerRegistry:
    """Durable liveness registry for independently launched local workers."""

    def __init__(self, database: Database) -> None:
        self.database = database

    def register(
        self, worker_id: str, worker_type: str, details: dict[str, Any] | None = None
    ) -> None:
        now = utc_now()
        with self.database.transaction() as connection:
            connection.execute(
                """UPDATE runtime_workers SET status='SUPERSEDED',stopped_at=?
                   WHERE worker_type=? AND worker_id!=? AND status IN
                   ('STARTING','IDLE','CHECKING','BUSY')""",
                (now, worker_type, worker_id),
            )
            connection.execute(
                """INSERT INTO runtime_workers(
                       worker_id,worker_type,status,started_at,heartbeat_at,details_json
                   ) VALUES (?,?,'STARTING',?,?,?)
                   ON CONFLICT(worker_id) DO UPDATE SET
                       worker_type=excluded.worker_type,status='STARTING',
                       started_at=excluded.started_at,heartbeat_at=excluded.heartbeat_at,
                       stopped_at=NULL,details_json=excluded.details_json""",
                (
                    worker_id,
                    worker_type,
                    now,
                    now,
                    json.dumps(details or {}, ensure_ascii=False),
                ),
            )

    def heartbeat(self, worker_id: str, status: str) -> None:
        if status not in ACTIVE_WORKER_STATES:
            raise ValueError(f"Invalid active worker status: {status}")
        with self.database.transaction() as connection:
            cursor = connection.execute(
                """UPDATE runtime_workers SET status=?,heartbeat_at=?,stopped_at=NULL
                   WHERE worker_id=?""",
                (status, utc_now(), worker_id),
            )
            if cursor.rowcount != 1:
                raise KeyError("Runtime worker is not registered")

    def stop(self, worker_id: str) -> None:
        now = utc_now()
        with self.database.transaction() as connection:
            connection.execute(
                """UPDATE runtime_workers SET status='STOPPED',heartbeat_at=?,stopped_at=?
                   WHERE worker_id=?""",
                (now, now, worker_id),
            )

    def latest(self, worker_type: str, stale_after_seconds: float = 8.0) -> dict[str, Any]:
        row = self.database.one(
            """SELECT * FROM runtime_workers WHERE worker_type=?
               ORDER BY heartbeat_at DESC LIMIT 1""",
            (worker_type,),
        )
        if not row:
            return {
                "available": False,
                "status": "NOT_REGISTERED",
                "last_seen_at": None,
                "heartbeat_age_seconds": None,
            }
        heartbeat = datetime.fromisoformat(str(row["heartbeat_at"]))
        if heartbeat.tzinfo is None:
            heartbeat = heartbeat.replace(tzinfo=UTC)
        age = max(0.0, (datetime.now(UTC) - heartbeat).total_seconds())
        available = str(row["status"]) in ACTIVE_WORKER_STATES and age <= stale_after_seconds
        status = (
            str(row["status"])
            if available
            else (
                "STALE"
                if str(row["status"]) in ACTIVE_WORKER_STATES
                else str(row["status"])
            )
        )
        return {
            "available": available,
            "status": status,
            "worker_id": row["worker_id"],
            "last_seen_at": row["heartbeat_at"],
            "heartbeat_age_seconds": round(age, 3),
        }
