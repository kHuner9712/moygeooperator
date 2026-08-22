from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Any

from geo_operator.core.db import Database
from geo_operator.core.time import utc_now


def _expires(seconds: int) -> str:
    return (datetime.now(UTC) + timedelta(seconds=seconds)).isoformat()


class LeaseUnavailable(RuntimeError):
    pass


class ExecutionLeaseManager:
    def __init__(self, database: Database, ttl_seconds: int = 30) -> None:
        self.database, self.ttl_seconds = database, ttl_seconds

    def acquire(self, execution_id: str, worker_id: str) -> dict[str, Any]:
        now, expires = utc_now(), _expires(self.ttl_seconds)
        with self.database.transaction() as connection:
            execution = connection.execute(
                "SELECT * FROM executions WHERE id=?", (execution_id,)
            ).fetchone()
            if not execution:
                raise KeyError("Execution not found")
            connection.execute("DELETE FROM execution_leases WHERE expires_at < ?", (now,))
            connection.execute("DELETE FROM session_locks WHERE expires_at < ?", (now,))
            session_key = ":".join(
                (execution["tenant_id"], execution["platform"], execution["account_id"])
            )
            try:
                connection.execute(
                    """INSERT INTO execution_leases(
                       execution_id,worker_id,acquired_at,heartbeat_at,expires_at)
                       VALUES (?,?,?,?,?)""",
                    (execution_id, worker_id, now, now, expires),
                )
                connection.execute(
                    """INSERT INTO session_locks(
                       session_key,execution_id,worker_id,acquired_at,heartbeat_at,expires_at)
                       VALUES (?,?,?,?,?,?)""",
                    (session_key, execution_id, worker_id, now, now, expires),
                )
            except Exception as exc:
                raise LeaseUnavailable("Execution or browser Session is already leased") from exc
        return {
            "execution_id": execution_id,
            "worker_id": worker_id,
            "session_key": session_key,
            "expires_at": expires,
        }

    def heartbeat(self, execution_id: str, worker_id: str) -> None:
        now, expires = utc_now(), _expires(self.ttl_seconds)
        with self.database.transaction() as connection:
            lease = connection.execute(
                "SELECT * FROM execution_leases WHERE execution_id=? AND worker_id=?",
                (execution_id, worker_id),
            ).fetchone()
            if not lease or lease["expires_at"] < now:
                raise LeaseUnavailable("Execution lease was lost")
            first = connection.execute(
                """UPDATE execution_leases SET heartbeat_at=?,expires_at=?
                   WHERE execution_id=? AND worker_id=?""",
                (now, expires, execution_id, worker_id),
            )
            second = connection.execute(
                """UPDATE session_locks SET heartbeat_at=?,expires_at=?
                   WHERE execution_id=? AND worker_id=?""",
                (now, expires, execution_id, worker_id),
            )
            if first.rowcount != 1 or second.rowcount != 1:
                raise LeaseUnavailable("Execution or Session lock was lost")

    def release(self, execution_id: str, worker_id: str) -> None:
        with self.database.transaction() as connection:
            connection.execute(
                "DELETE FROM session_locks WHERE execution_id=? AND worker_id=?",
                (execution_id, worker_id),
            )
            connection.execute(
                "DELETE FROM execution_leases WHERE execution_id=? AND worker_id=?",
                (execution_id, worker_id),
            )

    def release_expired(self) -> list[str]:
        now = utc_now()
        with self.database.transaction() as connection:
            rows = connection.execute(
                "SELECT execution_id FROM execution_leases WHERE expires_at < ?", (now,)
            ).fetchall()
            ids = [row["execution_id"] for row in rows]
            connection.execute("DELETE FROM session_locks WHERE expires_at < ?", (now,))
            connection.execute("DELETE FROM execution_leases WHERE expires_at < ?", (now,))
            for execution_id in ids:
                connection.execute(
                    """INSERT INTO execution_events(
                       id,execution_id,event_type,from_state,to_state,payload_json,created_at)
                       SELECT lower(hex(randomblob(16))),id,'LEASE_EXPIRED',state,state,'{}',?
                       FROM executions WHERE id=?""",
                    (now, execution_id),
                )
        return ids
