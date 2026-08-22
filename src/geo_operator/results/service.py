from __future__ import annotations

import json
import uuid
from typing import Any

from geo_operator.core.db import Database
from geo_operator.core.storage import ArtifactStore
from geo_operator.core.time import utc_now
from geo_operator.domain import ExecutionState

REQUIRED_SIGNALS = {
    "streaming_indicator_absent",
    "stop_control_absent",
    "input_ready",
    "response_text_stable",
    "final_response_element_present",
    "platform_error_absent",
}


class ResultService:
    def __init__(self, database: Database, artifacts: ArtifactStore) -> None:
        self.database, self.artifacts = database, artifacts

    def checkpoint(
        self,
        execution_id: str,
        text: str,
        page_url: str,
        response_locator: str,
        screenshot: bytes | None = None,
    ) -> dict[str, Any] | None:
        execution = self._execution(execution_id)
        last = self.database.one(
            """SELECT * FROM response_checkpoints WHERE execution_id=?
               ORDER BY sequence DESC LIMIT 1""",
            (execution_id,),
        )
        import hashlib

        content_hash = hashlib.sha256(text.encode("utf-8")).hexdigest()
        if last and last["content_sha256"] == content_hash:
            return None
        sequence = int(last["sequence"]) + 1 if last else 1
        relative = f"results/checkpoints/{execution_id}-{sequence}.txt"
        self.artifacts.atomic_write(execution["tenant_id"], relative, text.encode("utf-8"))
        screenshot_path = None
        if screenshot:
            screenshot_path = f"results/checkpoints/{execution_id}-{sequence}.png"
            self.artifacts.atomic_write(execution["tenant_id"], screenshot_path, screenshot)
        checkpoint_id = uuid.uuid4().hex
        with self.database.transaction() as connection:
            connection.execute(
                """INSERT INTO response_checkpoints(
                   id,execution_id,sequence,relative_path,content_sha256,page_url,
                   captured_at,response_locator,screenshot_path)
                   VALUES (?,?,?,?,?,?,?,?,?)""",
                (
                    checkpoint_id,
                    execution_id,
                    sequence,
                    relative,
                    content_hash,
                    page_url,
                    utc_now(),
                    response_locator,
                    screenshot_path,
                ),
            )
        return self.database.one("SELECT * FROM response_checkpoints WHERE id=?", (checkpoint_id,))

    def save_final(
        self,
        execution_id: str,
        text: str,
        signals: dict[str, bool],
        screenshot: bytes,
        metadata: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        execution = self._execution(execution_id)
        if execution["state"] != ExecutionState.VERIFY_COMPLETE.value:
            raise ValueError("Final result may only be saved from VERIFY_COMPLETE")
        if (
            not text
            or not REQUIRED_SIGNALS.issubset(signals)
            or not all(signals[name] for name in REQUIRED_SIGNALS)
        ):
            raise ValueError("Final response completion signals are incomplete")
        if not screenshot:
            raise ValueError("Final result screenshot is required")
        result_id = uuid.uuid4().hex
        response_path = f"results/{result_id}.txt"
        screenshot_path = f"results/screenshots/{result_id}.png"
        _, content_hash = self.artifacts.atomic_write(
            execution["tenant_id"], response_path, text.encode("utf-8")
        )
        self.artifacts.atomic_write(execution["tenant_id"], screenshot_path, screenshot)
        now = utc_now()
        with self.database.transaction() as connection:
            row = connection.execute(
                "SELECT state,version FROM executions WHERE id=?", (execution_id,)
            ).fetchone()
            if not row or row["state"] != ExecutionState.VERIFY_COMPLETE.value:
                raise ValueError("Execution state changed before result commit")
            connection.execute(
                """INSERT INTO results(
                   id,execution_id,tenant_id,relative_path,content_sha256,
                   completion_signals_json,saved_at,task_id,screenshot_path,metadata_json)
                   VALUES (?,?,?,?,?,?,?,?,?,?)""",
                (
                    result_id,
                    execution_id,
                    execution["tenant_id"],
                    response_path,
                    content_hash,
                    json.dumps(signals),
                    now,
                    execution["task_id"],
                    screenshot_path,
                    json.dumps(metadata or {}, ensure_ascii=False),
                ),
            )
            connection.execute(
                """UPDATE executions SET state=?,version=version+1,updated_at=?
                   WHERE id=? AND version=?""",
                (ExecutionState.SAVE_RESULT.value, now, execution_id, row["version"]),
            )
            connection.execute(
                """INSERT INTO execution_events(
                   id,execution_id,event_type,from_state,to_state,payload_json,created_at)
                   VALUES (?,?,?,?,?,?,?)""",
                (
                    uuid.uuid4().hex,
                    execution_id,
                    "RESULT_SAVED",
                    ExecutionState.VERIFY_COMPLETE.value,
                    ExecutionState.SAVE_RESULT.value,
                    json.dumps({"result_id": result_id, "sha256": content_hash}),
                    now,
                ),
            )
        return self.get_for_execution(execution_id)

    def get_for_execution(self, execution_id: str) -> dict[str, Any]:
        row = self.database.one("SELECT * FROM results WHERE execution_id=?", (execution_id,))
        if not row:
            raise KeyError("Result not found")
        return row

    def has_saved_result(self, execution_id: str) -> bool:
        return bool(
            self.database.one("SELECT id FROM results WHERE execution_id=?", (execution_id,))
        )

    def _execution(self, execution_id: str) -> dict[str, Any]:
        row = self.database.one("SELECT * FROM executions WHERE id=?", (execution_id,))
        if not row:
            raise KeyError("Execution not found")
        return row
