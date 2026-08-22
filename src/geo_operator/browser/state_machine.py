from __future__ import annotations

import json
import uuid
from typing import Any

from geo_operator.core.db import Database
from geo_operator.core.time import utc_now
from geo_operator.domain import ExecutionState, PauseReason

ALLOWED = {
    ExecutionState.CREATED: {ExecutionState.WAIT_LOGIN},
    ExecutionState.WAIT_LOGIN: {ExecutionState.READY},
    ExecutionState.READY: {ExecutionState.WAIT_HUMAN_APPROVAL},
    ExecutionState.WAIT_HUMAN_APPROVAL: {ExecutionState.OPEN_PLATFORM},
    ExecutionState.OPEN_PLATFORM: {ExecutionState.SEND_QUERY},
    ExecutionState.SEND_QUERY: {ExecutionState.WAIT_RESPONSE},
    ExecutionState.WAIT_RESPONSE: {ExecutionState.VERIFY_COMPLETE},
    ExecutionState.VERIFY_COMPLETE: {ExecutionState.SAVE_RESULT},
    ExecutionState.SAVE_RESULT: {ExecutionState.DELETE_CHAT},
    ExecutionState.DELETE_CHAT: {ExecutionState.VERIFY_DELETE},
    ExecutionState.VERIFY_DELETE: {ExecutionState.NEXT_TASK},
    ExecutionState.NEXT_TASK: {ExecutionState.OPEN_PLATFORM, ExecutionState.COMPLETED},
    ExecutionState.COMPLETED: set(),
    ExecutionState.PAUSED: set(),
    ExecutionState.FAILED: set(),
}
TERMINAL = {ExecutionState.COMPLETED, ExecutionState.FAILED}


class ExecutionStateMachine:
    def __init__(self, database: Database) -> None:
        self.database = database

    def create(
        self,
        tenant_id: str,
        platform: str,
        account_id: str,
        task_package_id: str | None = None,
        task_id: str | None = None,
    ) -> dict[str, Any]:
        execution_id, now = uuid.uuid4().hex, utc_now()
        with self.database.transaction() as connection:
            connection.execute(
                """INSERT INTO executions(id,tenant_id,task_package_id,platform,account_id,task_id,
                   state,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?)""",
                (
                    execution_id,
                    tenant_id,
                    task_package_id,
                    platform,
                    account_id,
                    task_id,
                    ExecutionState.CREATED.value,
                    now,
                    now,
                ),
            )
            self._event(
                connection, execution_id, "EXECUTION_CREATED", None, ExecutionState.CREATED, {}
            )
        return self.get(execution_id)

    def transition(
        self, execution_id: str, target: ExecutionState, payload: dict[str, Any] | None = None
    ) -> dict[str, Any]:
        with self.database.transaction() as connection:
            row = self._get(connection, execution_id)
            current = ExecutionState(row["state"])
            if target not in ALLOWED[current]:
                raise ValueError(f"Illegal transition: {current.value} -> {target.value}")
            self._update(connection, row, target)
            self._event(
                connection, execution_id, "STATE_TRANSITION", current, target, payload or {}
            )
        return self.get(execution_id)

    def wait_for_approval(
        self, execution_id: str, approval_id: str, resume_state: ExecutionState
    ) -> dict[str, Any]:
        with self.database.transaction() as connection:
            row = self._get(connection, execution_id)
            current = ExecutionState(row["state"])
            if current != ExecutionState.READY or resume_state != ExecutionState.OPEN_PLATFORM:
                raise ValueError("Task approval requires READY and must resume at OPEN_PLATFORM")
            connection.execute(
                """UPDATE executions SET state=?,resume_state=?,approval_id=?,
                   version=version+1,updated_at=? WHERE id=? AND version=?""",
                (
                    ExecutionState.WAIT_HUMAN_APPROVAL.value,
                    resume_state.value,
                    approval_id,
                    utc_now(),
                    execution_id,
                    row["version"],
                ),
            )
            self._event(
                connection,
                execution_id,
                "HUMAN_APPROVAL_REQUESTED",
                current,
                ExecutionState.WAIT_HUMAN_APPROVAL,
                {"approval_id": approval_id},
            )
        return self.get(execution_id)

    def resolve_approval(self, execution_id: str, approved: bool) -> dict[str, Any]:
        with self.database.transaction() as connection:
            row = self._get(connection, execution_id)
            if row["state"] != ExecutionState.WAIT_HUMAN_APPROVAL.value:
                raise ValueError("Execution is not waiting for approval")
            target = ExecutionState(str(row["resume_state"])) if approved else ExecutionState.PAUSED
            if approved and target != ExecutionState.OPEN_PLATFORM:
                raise ValueError("Unsafe approval resume state")
            connection.execute(
                """UPDATE executions SET state=?,pause_reason=?,paused_from_state=?,
                   version=version+1,updated_at=? WHERE id=? AND version=?""",
                (
                    target.value,
                    None if approved else PauseReason.OPERATOR_REQUESTED.value,
                    None if approved else ExecutionState.WAIT_HUMAN_APPROVAL.value,
                    utc_now(),
                    execution_id,
                    row["version"],
                ),
            )
            self._event(
                connection,
                execution_id,
                "HUMAN_APPROVAL_RESOLVED",
                ExecutionState.WAIT_HUMAN_APPROVAL,
                target,
                {"approved": approved},
            )
        return self.get(execution_id)

    def pause(
        self,
        execution_id: str,
        reason: PauseReason,
        safe_resume_state: ExecutionState | None = None,
        details: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        with self.database.transaction() as connection:
            row = self._get(connection, execution_id)
            current = ExecutionState(row["state"])
            if current in TERMINAL or current == ExecutionState.PAUSED:
                raise ValueError("Execution cannot be paused from its current state")
            resume = safe_resume_state or current
            if resume in TERMINAL or resume == ExecutionState.PAUSED:
                raise ValueError("Invalid safe resume state")
            connection.execute(
                """UPDATE executions SET state=?,resume_state=?,paused_from_state=?,pause_reason=?,
                   version=version+1,updated_at=? WHERE id=? AND version=?""",
                (
                    ExecutionState.PAUSED.value,
                    resume.value,
                    current.value,
                    reason.value,
                    utc_now(),
                    execution_id,
                    row["version"],
                ),
            )
            self._event(
                connection,
                execution_id,
                "EXECUTION_PAUSED",
                current,
                ExecutionState.PAUSED,
                {"reason": reason.value, **(details or {})},
            )
        return self.get(execution_id)

    def request_resume(self, execution_id: str, note: str = "") -> dict[str, Any]:
        """Record human completion; a worker must still revalidate before changing state."""
        with self.database.transaction() as connection:
            row = self._get(connection, execution_id)
            if row["state"] != ExecutionState.PAUSED.value:
                raise ValueError("Execution is not paused")
            self._event(
                connection,
                execution_id,
                "HUMAN_TAKEOVER_COMPLETED",
                ExecutionState.PAUSED,
                ExecutionState.PAUSED,
                {"note": note, "revalidation_required": True},
            )
        return self.get(execution_id)

    def record_resume_revalidation_failure(
        self, execution_id: str, reason: str, details: dict[str, Any] | None = None
    ) -> dict[str, Any]:
        with self.database.transaction() as connection:
            row = self._get(connection, execution_id)
            if row["state"] != ExecutionState.PAUSED.value:
                raise ValueError("Execution is not paused")
            self._event(
                connection,
                execution_id,
                "RESUME_REVALIDATION_FAILED",
                ExecutionState.PAUSED,
                ExecutionState.PAUSED,
                {"reason": reason, **(details or {})},
            )
        return self.get(execution_id)

    def resume(self, execution_id: str, revalidated: bool) -> dict[str, Any]:
        if not revalidated:
            raise ValueError("Human takeover must be revalidated before resume")
        with self.database.transaction() as connection:
            row = self._get(connection, execution_id)
            if row["state"] != ExecutionState.PAUSED.value:
                raise ValueError("Execution is not paused")
            target = ExecutionState(str(row["resume_state"]))
            if target in TERMINAL or target == ExecutionState.PAUSED:
                raise ValueError("Invalid stored resume state")
            connection.execute(
                """UPDATE executions SET state=?,pause_reason=NULL,paused_from_state=NULL,
                   version=version+1,updated_at=? WHERE id=? AND version=?""",
                (target.value, utc_now(), execution_id, row["version"]),
            )
            self._event(
                connection,
                execution_id,
                "RESUMED_AFTER_REVALIDATION",
                ExecutionState.PAUSED,
                target,
                {"revalidated": True},
            )
        return self.get(execution_id)

    def record_effect_intent(
        self, execution_id: str, effect_type: str, idempotency_key: str
    ) -> dict[str, Any]:
        effect_id = uuid.uuid4().hex
        with self.database.transaction() as connection:
            connection.execute(
                """INSERT INTO side_effects(id,execution_id,effect_type,idempotency_key,
                   status,observation_json,created_at) VALUES (?,?,?,?,'INTENT','{}',?)""",
                (effect_id, execution_id, effect_type, idempotency_key, utc_now()),
            )
        return self.database.one("SELECT * FROM side_effects WHERE id=?", (effect_id,)) or {}

    def mark_effect_not_attempted(
        self, effect_id: str, details: dict[str, Any] | None = None
    ) -> None:
        observation = {"action_attempted": False, **(details or {})}
        with self.database.transaction() as connection:
            effect = connection.execute(
                "SELECT * FROM side_effects WHERE id=?", (effect_id,)
            ).fetchone()
            if not effect or effect["status"] != "INTENT":
                raise ValueError("Side effect intent not found or already confirmed")
            connection.execute(
                "UPDATE side_effects SET observation_json=? WHERE id=?",
                (json.dumps(observation, ensure_ascii=False), effect_id),
            )
            execution = self._get(connection, str(effect["execution_id"]))
            current = ExecutionState(str(execution["state"]))
            self._event(
                connection,
                str(effect["execution_id"]),
                "SIDE_EFFECT_NOT_ATTEMPTED",
                current,
                current,
                {"effect_id": effect_id, "effect_type": effect["effect_type"], **observation},
            )

    def mark_effect_delivery_failed(
        self, effect_id: str, details: dict[str, Any] | None = None
    ) -> None:
        observation = {
            "action_attempted": True,
            "delivery_failed": True,
            **(details or {}),
        }
        with self.database.transaction() as connection:
            effect = connection.execute(
                "SELECT * FROM side_effects WHERE id=?", (effect_id,)
            ).fetchone()
            if not effect or effect["status"] != "INTENT":
                raise ValueError("Side effect intent not found or already confirmed")
            connection.execute(
                "UPDATE side_effects SET observation_json=? WHERE id=?",
                (json.dumps(observation, ensure_ascii=False), effect_id),
            )
            execution = self._get(connection, str(effect["execution_id"]))
            current = ExecutionState(str(execution["state"]))
            self._event(
                connection,
                str(effect["execution_id"]),
                "SIDE_EFFECT_DELIVERY_FAILED",
                current,
                current,
                {"effect_id": effect_id, "effect_type": effect["effect_type"], **observation},
            )

    def reconcile_confirmed_query_delivery_failure(
        self,
        execution_id: str,
        effect_id: str,
        pause_reason: PauseReason,
        evidence: dict[str, Any],
    ) -> dict[str, Any]:
        observation = {
            "action_attempted": True,
            "delivery_failed": True,
            "reconciled_from": "CONFIRMED",
            **evidence,
        }
        with self.database.transaction() as connection:
            execution = self._get(connection, execution_id)
            if execution["state"] != ExecutionState.PAUSED.value:
                raise ValueError("Execution must be paused for delivery reconciliation")
            effect = connection.execute(
                "SELECT * FROM side_effects WHERE id=? AND execution_id=?",
                (effect_id, execution_id),
            ).fetchone()
            if (
                not effect
                or effect["effect_type"] != "QUERY_SEND"
                or effect["status"] != "CONFIRMED"
            ):
                raise ValueError("Confirmed query effect not found")
            connection.execute(
                """UPDATE side_effects
                   SET status='INTENT',observation_json=?,confirmed_at=NULL
                   WHERE id=? AND status='CONFIRMED'""",
                (json.dumps(observation, ensure_ascii=False), effect_id),
            )
            connection.execute(
                """UPDATE executions
                   SET resume_state=?,pause_reason=?,version=version+1,updated_at=?
                   WHERE id=? AND version=?""",
                (
                    ExecutionState.SEND_QUERY.value,
                    pause_reason.value,
                    utc_now(),
                    execution_id,
                    execution["version"],
                ),
            )
            self._event(
                connection,
                execution_id,
                "SIDE_EFFECT_CONFIRMATION_REVOKED",
                ExecutionState.PAUSED,
                ExecutionState.PAUSED,
                {
                    "effect_id": effect_id,
                    "effect_type": "QUERY_SEND",
                    "resume_state": ExecutionState.SEND_QUERY.value,
                    "pause_reason": pause_reason.value,
                    **observation,
                },
            )
        return self.get(execution_id)

    def mark_effect_retry_started(self, effect_id: str) -> None:
        with self.database.transaction() as connection:
            effect = connection.execute(
                "SELECT * FROM side_effects WHERE id=?", (effect_id,)
            ).fetchone()
            if not effect or effect["status"] != "INTENT":
                raise ValueError("Side effect intent not found or already confirmed")
            connection.execute(
                "UPDATE side_effects SET observation_json='{}' WHERE id=?", (effect_id,)
            )
            execution = self._get(connection, str(effect["execution_id"]))
            current = ExecutionState(str(execution["state"]))
            self._event(
                connection,
                str(effect["execution_id"]),
                "SIDE_EFFECT_RETRY_STARTED",
                current,
                current,
                {"effect_id": effect_id, "effect_type": effect["effect_type"]},
            )

    def confirm_effect(self, effect_id: str, observation: dict[str, Any]) -> None:
        with self.database.transaction() as connection:
            cursor = connection.execute(
                """UPDATE side_effects SET status='CONFIRMED',observation_json=?,confirmed_at=?
                   WHERE id=? AND status='INTENT'""",
                (json.dumps(observation, ensure_ascii=False), utc_now(), effect_id),
            )
            if cursor.rowcount != 1:
                raise ValueError("Side effect intent not found or already confirmed")

    def bind_recovery_url(self, execution_id: str, page_url: str) -> dict[str, Any]:
        with self.database.transaction() as connection:
            row = self._get(connection, execution_id)
            current = ExecutionState(str(row["state"]))
            self._event(
                connection,
                execution_id,
                "SESSION_RECOVERY_URL_BOUND",
                current,
                current,
                {"page_url": page_url},
            )
        return self.get(execution_id)

    def get(self, execution_id: str) -> dict[str, Any]:
        row = self.database.one("SELECT * FROM executions WHERE id=?", (execution_id,))
        if not row:
            raise KeyError("Execution not found")
        return row

    @staticmethod
    def _get(connection: Any, execution_id: str) -> Any:
        row = connection.execute("SELECT * FROM executions WHERE id=?", (execution_id,)).fetchone()
        if not row:
            raise KeyError("Execution not found")
        return row

    @staticmethod
    def _update(connection: Any, row: Any, target: ExecutionState) -> None:
        cursor = connection.execute(
            "UPDATE executions SET state=?,version=version+1,updated_at=? WHERE id=? AND version=?",
            (target.value, utc_now(), row["id"], row["version"]),
        )
        if cursor.rowcount != 1:
            raise RuntimeError("Execution was modified concurrently")

    @staticmethod
    def _event(
        connection: Any,
        execution_id: str,
        kind: str,
        source: ExecutionState | None,
        target: ExecutionState,
        payload: dict[str, Any],
    ) -> None:
        connection.execute(
            """INSERT INTO execution_events(id,execution_id,event_type,from_state,to_state,
               payload_json,created_at) VALUES (?,?,?,?,?,?,?)""",
            (
                uuid.uuid4().hex,
                execution_id,
                kind,
                source.value if source else None,
                target.value,
                json.dumps(payload, ensure_ascii=False),
                utc_now(),
            ),
        )
