from __future__ import annotations

import hashlib
import json
import os
import tempfile
import uuid
import zipfile
from pathlib import Path
from typing import Any

from geo_operator.approvals import ApprovalService
from geo_operator.core.db import Database
from geo_operator.core.storage import ArtifactStore
from geo_operator.core.time import utc_now
from geo_operator.domain import ApprovalStage


class ResultPackageService:
    def __init__(
        self, database: Database, artifacts: ArtifactStore, approvals: ApprovalService
    ) -> None:
        self.database, self.artifacts, self.approvals = database, artifacts, approvals

    def request_approval(self, task_package_id: str) -> dict[str, Any]:
        package = self._package(task_package_id)
        incomplete = self.database.one(
            """SELECT id FROM tasks WHERE task_package_id=?
               AND status NOT IN ('COMPLETED','SKIPPED') LIMIT 1""",
            (task_package_id,),
        )
        if incomplete:
            raise ValueError("All selected tasks must be COMPLETED before result export approval")
        return self.approvals.request(
            str(package["tenant_id"]),
            ApprovalStage.RESULT_EXPORT,
            "result_package",
            task_package_id,
        )

    def export(self, task_package_id: str) -> Path:
        package = self._package(task_package_id)
        approval = self.database.one(
            """SELECT * FROM approvals WHERE resource_type='result_package'
               AND resource_id=? ORDER BY requested_at DESC LIMIT 1""",
            (task_package_id,),
        )
        if not approval or approval["status"] != "APPROVED":
            raise ValueError("RESULT_EXPORT approval is required")
        rows = self.database.all(
            """SELECT r.*,t.external_task_id,t.prompt,t.platform,
                      e.id AS execution_ref,e.created_at AS started_at,
                      e.updated_at AS completed_at
               FROM results r JOIN executions e ON e.id=r.execution_id
               JOIN tasks t ON t.id=e.task_id
               WHERE e.task_package_id=? ORDER BY t.sequence""",
            (task_package_id,),
        )
        expected = self.database.one(
            """SELECT COUNT(*) AS count FROM tasks
               WHERE task_package_id=? AND status!='SKIPPED'""",
            (task_package_id,),
        )
        if not rows or len(rows) != int(expected["count"]):
            raise ValueError("Result set is incomplete")

        tenant_id = str(package["tenant_id"])
        export_id = uuid.uuid4().hex
        relative = f"exports/RESULT_PACKAGE_{package['package_id']}_{export_id}.zip"
        target = self.artifacts.resolve(tenant_id, relative)
        handle, temporary = tempfile.mkstemp(prefix=".result-package.", dir=target.parent)
        os.close(handle)
        try:
            with zipfile.ZipFile(temporary, "w", zipfile.ZIP_DEFLATED) as archive:
                result_lines: list[str] = []
                event_lines: list[str] = []
                files: list[dict[str, Any]] = []
                for row in rows:
                    response_name = f"responses/{row['id']}.txt"
                    screenshot_name = f"screenshots/{row['id']}.png"
                    response = self.artifacts.resolve(tenant_id, str(row["relative_path"]))
                    screenshot = self.artifacts.resolve(tenant_id, str(row["screenshot_path"]))
                    archive.write(response, response_name)
                    archive.write(screenshot, screenshot_name)
                    shot_hash = hashlib.sha256(screenshot.read_bytes()).hexdigest()
                    result_lines.append(
                        json.dumps(
                            {
                                "result_id": row["id"],
                                "tenant_id": tenant_id,
                                "task_id": row["external_task_id"],
                                "execution_id": row["execution_id"],
                                "platform": row["platform"],
                                "prompt": row["prompt"],
                                "response_path": response_name,
                                "screenshot_path": screenshot_name,
                                "started_at": row["started_at"],
                                "completed_at": row["completed_at"] or row["saved_at"],
                                "completion_signals": json.loads(row["completion_signals_json"]),
                                "response_sha256": row["content_sha256"],
                                "final_status": "COMPLETED",
                            },
                            ensure_ascii=False,
                        )
                    )
                    files.extend(
                        (
                            {
                                "path": response_name,
                                "sha256": row["content_sha256"],
                                "size": response.stat().st_size,
                            },
                            {
                                "path": screenshot_name,
                                "sha256": shot_hash,
                                "size": screenshot.stat().st_size,
                            },
                        )
                    )
                    events = self.database.all(
                        """SELECT sequence,event_type,from_state,to_state,payload_json,created_at
                           FROM execution_events WHERE execution_id=? ORDER BY sequence""",
                        (row["execution_id"],),
                    )
                    for event in events:
                        event["execution_id"] = row["execution_id"]
                        event["payload"] = json.loads(event.pop("payload_json"))
                        event_lines.append(json.dumps(event, ensure_ascii=False))
                results_content = ("\n".join(result_lines) + "\n").encode()
                events_content = ("\n".join(event_lines) + "\n").encode()
                archive.writestr("results.jsonl", results_content)
                archive.writestr("events/execution_events.jsonl", events_content)
                files.extend(
                    (
                        {
                            "path": "results.jsonl",
                            "sha256": hashlib.sha256(results_content).hexdigest(),
                            "size": len(results_content),
                        },
                        {
                            "path": "events/execution_events.jsonl",
                            "sha256": hashlib.sha256(events_content).hexdigest(),
                            "size": len(events_content),
                        },
                    )
                )
                manifest = {
                    "schema_version": "1.0",
                    "package_type": "RESULT_PACKAGE",
                    "tenant_id": tenant_id,
                    "source_task_package_id": package["package_id"],
                    "export_id": export_id,
                    "created_at": utc_now(),
                    "files": files,
                }
                archive.writestr(
                    "manifest.json", json.dumps(manifest, ensure_ascii=False, indent=2)
                )
            os.replace(temporary, target)
        except Exception:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass
            raise
        digest = self.artifacts.record_existing(tenant_id, relative)
        with self.database.transaction() as connection:
            connection.execute(
                """INSERT INTO exports(id,tenant_id,package_type,relative_path,sha256,created_at)
                   VALUES (?,?,'RESULT_PACKAGE',?,?,?)""",
                (export_id, tenant_id, relative, digest, utc_now()),
            )
        return target

    def _package(self, package_id: str) -> dict[str, Any]:
        row = self.database.one("SELECT * FROM task_packages WHERE id=?", (package_id,))
        if not row:
            raise KeyError("Task package not found")
        return row
