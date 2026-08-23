from __future__ import annotations

import hashlib
import io
import json
import re
import sqlite3
import uuid
import zipfile
from pathlib import PurePosixPath
from typing import Any

from geo_operator.core.db import Database
from geo_operator.core.storage import ArtifactStore
from geo_operator.core.time import utc_now
from geo_operator.domain import ApprovalStage
from geo_operator.platforms import SUPPORTED_PLATFORM_IDS, canonical_platform

SUPPORTED_SCHEMA = "1.0"
SUPPORTED_PLATFORMS = set(SUPPORTED_PLATFORM_IDS)
PACKAGE_ID = re.compile(r"^[A-Za-z0-9._-]{1,128}$")
MAX_ARCHIVE_BYTES = 20 * 1024 * 1024
MAX_MEMBER_BYTES = 10 * 1024 * 1024
MAX_TOTAL_BYTES = 30 * 1024 * 1024


class DuplicateTaskPackageError(ValueError):
    pass


class TaskPackageService:
    def __init__(self, database: Database, artifacts: ArtifactStore) -> None:
        self.database, self.artifacts = database, artifacts

    def import_zip(self, tenant_id: str, content: bytes) -> dict[str, Any]:
        if not content or len(content) > MAX_ARCHIVE_BYTES:
            raise ValueError("Task package is empty or exceeds the archive size limit")
        package_hash = hashlib.sha256(content).hexdigest()
        self._assert_tenant(tenant_id)
        with zipfile.ZipFile(io.BytesIO(content)) as archive:
            self._validate_archive(archive)
            manifest_bytes = archive.read("manifest.json")
            tasks_bytes = archive.read("tasks.jsonl")
        manifest = self._parse_manifest(manifest_bytes, tenant_id)
        self._verify_tasks_hash(manifest, tasks_bytes)
        tasks = self._parse_tasks(tasks_bytes)
        package_id = manifest["package_id"]
        internal_id = uuid.uuid4().hex
        approval_id = uuid.uuid4().hex
        relative_path = f"tasks/{package_id}.zip"

        existing = self.database.one(
            """SELECT id FROM task_packages
               WHERE tenant_id=? AND (package_id=? OR package_sha256=?)""",
            (tenant_id, package_id, package_hash),
        )
        if existing:
            raise DuplicateTaskPackageError("Task package has already been imported")

        self.artifacts.atomic_write(tenant_id, relative_path, content)
        now = utc_now()
        try:
            with self.database.transaction() as connection:
                connection.execute(
                    """INSERT INTO task_packages(
                       id,tenant_id,package_id,schema_version,source_path,package_sha256,
                       status,approval_id,imported_at)
                       VALUES (?,?,?,?,?,?,'WAIT_HUMAN_APPROVAL',?,?)""",
                    (
                        internal_id,
                        tenant_id,
                        package_id,
                        SUPPORTED_SCHEMA,
                        relative_path,
                        package_hash,
                        approval_id,
                        now,
                    ),
                )
                for task in tasks:
                    connection.execute(
                        """INSERT INTO tasks(
                           id,tenant_id,task_package_id,external_task_id,prompt,platform,
                           account_id,sequence,metadata_json,idempotency_key,status,created_at)
                           VALUES (?,?,?,?,?,?,?,?,?,?,'PENDING',?)""",
                        (
                            uuid.uuid4().hex,
                            tenant_id,
                            internal_id,
                            task["task_id"],
                            task["prompt"],
                            task["platform"],
                            task["account_id"],
                            task["sequence"],
                            json.dumps(task["metadata"], ensure_ascii=False),
                            task["idempotency_key"],
                            now,
                        ),
                    )
                connection.execute(
                    """INSERT INTO approvals(
                       id,tenant_id,stage,resource_type,resource_id,status,requested_at)
                       VALUES (?,?,?,?,?,'PENDING',?)""",
                    (
                        approval_id,
                        tenant_id,
                        ApprovalStage.TASK_EXECUTION.value,
                        "task_package",
                        internal_id,
                        now,
                    ),
                )
        except sqlite3.IntegrityError as exc:
            raise DuplicateTaskPackageError(
                "Task package or idempotency key has already been imported"
            ) from exc
        return self.get(internal_id)

    def mark_decision(self, package_id: str, approved: bool) -> dict[str, Any]:
        with self.database.transaction() as connection:
            row = connection.execute(
                "SELECT * FROM task_packages WHERE id=?", (package_id,)
            ).fetchone()
            if not row:
                raise KeyError("Task package not found")
            row = dict(row)
            if row["status"] != "WAIT_HUMAN_APPROVAL":
                raise ValueError("Task package decision has already been applied")
            if approved and not self._saved_platform_selection(row):
                raise ValueError(
                    "Select and save detection platforms before task approval"
                )
            connection.execute(
                "UPDATE task_packages SET status=? WHERE id=?",
                ("APPROVED" if approved else "REJECTED", package_id),
            )
        return self.get(package_id)

    def get(self, package_id: str) -> dict[str, Any]:
        row = self.database.one("SELECT * FROM task_packages WHERE id=?", (package_id,))
        if not row:
            raise KeyError("Task package not found")
        tasks = self.database.all(
            "SELECT * FROM tasks WHERE task_package_id=? ORDER BY sequence", (package_id,)
        )
        row["tasks"] = tasks
        self._attach_platform_selection(row, tasks)
        return row

    def list(self, tenant_id: str | None = None) -> list[dict[str, Any]]:
        if tenant_id:
            rows = self.database.all(
                "SELECT * FROM task_packages WHERE tenant_id=? ORDER BY imported_at DESC",
                (tenant_id,),
            )
        else:
            rows = self.database.all("SELECT * FROM task_packages ORDER BY imported_at DESC")
        for row in rows:
            tasks = self.database.all(
                "SELECT platform,status FROM tasks WHERE task_package_id=? ORDER BY sequence",
                (row["id"],),
            )
            self._attach_platform_selection(row, tasks)
        return rows

    def set_platform_selection(self, package_id: str, platforms: list[str]) -> dict[str, Any]:
        package = self.database.one("SELECT * FROM task_packages WHERE id=?", (package_id,))
        if not package:
            raise KeyError("Task package not found")
        if package["status"] != "WAIT_HUMAN_APPROVAL":
            raise ValueError("Detection platforms can only be changed before task approval")

        tasks = self.database.all(
            "SELECT id,platform FROM tasks WHERE task_package_id=? ORDER BY sequence",
            (package_id,),
        )
        available = {str(task["platform"]) for task in tasks}
        selected: list[str] = []
        for platform in platforms:
            canonical = canonical_platform(platform)
            if canonical not in SUPPORTED_PLATFORMS:
                raise ValueError(f"Unsupported task platform: {canonical}")
            if canonical not in available:
                raise ValueError(f"Platform is not present in this task package: {canonical}")
            if canonical not in selected:
                selected.append(canonical)
        if not selected:
            raise ValueError("Select at least one detection platform")

        selected_set = set(selected)
        with self.database.transaction() as connection:
            connection.execute(
                "UPDATE task_packages SET platform_selection_json=? WHERE id=?",
                (json.dumps(selected, ensure_ascii=False), package_id),
            )
            for task in tasks:
                connection.execute(
                    "UPDATE tasks SET status=? WHERE id=?",
                    ("PENDING" if task["platform"] in selected_set else "SKIPPED", task["id"]),
                )
        return self.get(package_id)

    def execution_tasks(self, package_id: str) -> list[dict[str, Any]]:
        package = self.database.one("SELECT * FROM task_packages WHERE id=?", (package_id,))
        if not package:
            raise KeyError("Task package not found")
        selected = self._saved_platform_selection(package)
        if not selected:
            return []
        placeholders = ",".join("?" * len(selected))
        return self.database.all(
            f"""SELECT * FROM tasks WHERE task_package_id=?
               AND platform IN ({placeholders}) AND status!='SKIPPED'
               ORDER BY sequence""",
            (package_id, *selected),
        )

    @staticmethod
    def _saved_platform_selection(package: dict[str, Any]) -> list[str]:
        try:
            selected = json.loads(str(package.get("platform_selection_json") or "[]"))
        except (TypeError, ValueError):
            selected = []
        return [str(platform) for platform in selected if isinstance(platform, str)]

    @staticmethod
    def _attach_platform_selection(
        package: dict[str, Any], tasks: list[dict[str, Any]]
    ) -> None:
        platforms = list(dict.fromkeys(str(task["platform"]) for task in tasks))
        package["platforms"] = platforms
        package["selected_platforms"] = TaskPackageService._saved_platform_selection(package)

    def _assert_tenant(self, tenant_id: str) -> None:
        if not self.database.one(
            "SELECT id FROM tenants WHERE id=? AND status='ACTIVE'", (tenant_id,)
        ):
            raise KeyError("Tenant not found")

    @staticmethod
    def _validate_archive(archive: zipfile.ZipFile) -> None:
        names: set[str] = set()
        total = 0
        for info in archive.infolist():
            normalized = info.filename.replace("\\", "/")
            path = PurePosixPath(normalized)
            if path.is_absolute() or ".." in path.parts or normalized != info.filename:
                raise ValueError("Unsafe path in task package")
            if info.is_dir():
                continue
            if normalized in names:
                raise ValueError("Duplicate file path in task package")
            names.add(normalized)
            total += info.file_size
            if info.file_size > MAX_MEMBER_BYTES or total > MAX_TOTAL_BYTES:
                raise ValueError("Task package uncompressed size limit exceeded")
            if info.compress_size and info.file_size / info.compress_size > 200:
                raise ValueError("Suspicious ZIP compression ratio")
        if not {"manifest.json", "tasks.jsonl"}.issubset(names):
            raise ValueError("Task package requires manifest.json and tasks.jsonl")

    @staticmethod
    def _parse_manifest(content: bytes, tenant_id: str) -> dict[str, Any]:
        try:
            manifest = json.loads(content.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ValueError("Invalid manifest.json") from exc
        if manifest.get("schema_version") != SUPPORTED_SCHEMA:
            raise ValueError("Unsupported task package schema_version")
        if manifest.get("package_type") != "GEO_TASK_PACKAGE":
            raise ValueError("Invalid package_type")
        if manifest.get("tenant_id") != tenant_id:
            raise ValueError("Task package tenant_id does not match import tenant")
        package_id = manifest.get("package_id")
        if not isinstance(package_id, str) or not PACKAGE_ID.fullmatch(package_id):
            raise ValueError("Invalid package_id")
        return manifest

    @staticmethod
    def _verify_tasks_hash(manifest: dict[str, Any], tasks: bytes) -> None:
        files = manifest.get("files")
        if not isinstance(files, list):
            raise ValueError("Manifest files list is required")  # noqa: TRY004
        entry = next((item for item in files if item.get("path") == "tasks.jsonl"), None)
        if not entry or entry.get("sha256") != hashlib.sha256(tasks).hexdigest():
            raise ValueError("tasks.jsonl SHA-256 mismatch")

    @staticmethod
    def _parse_tasks(content: bytes) -> list[dict[str, Any]]:
        try:
            lines = content.decode("utf-8").splitlines()
        except UnicodeDecodeError as exc:
            raise ValueError("tasks.jsonl must be UTF-8") from exc
        tasks: list[dict[str, Any]] = []
        task_ids: set[str] = set()
        keys: set[str] = set()
        for line_number, line in enumerate(lines, 1):
            if not line.strip():
                continue
            try:
                task = json.loads(line)
            except json.JSONDecodeError as exc:
                raise ValueError(f"Invalid task JSON on line {line_number}") from exc
            required = {
                "task_id",
                "prompt",
                "platform",
                "account_id",
                "sequence",
                "metadata",
                "idempotency_key",
            }
            if not required.issubset(task):
                raise ValueError(f"Missing task fields on line {line_number}")
            if not isinstance(task["task_id"], str) or not PACKAGE_ID.fullmatch(task["task_id"]):
                raise ValueError(f"Invalid task_id on line {line_number}")
            if task["task_id"] in task_ids:
                raise ValueError("task_id must be unique within a package")
            task["platform"] = canonical_platform(task["platform"])
            if not isinstance(task["account_id"], str) or not PACKAGE_ID.fullmatch(
                task["account_id"]
            ):
                raise ValueError(f"Invalid account_id on line {line_number}")
            if not isinstance(task["prompt"], str) or not task["prompt"].strip():
                raise ValueError("Task prompt is required")
            if not isinstance(task["sequence"], int) or task["sequence"] < 1:
                raise ValueError("Task sequence must be a positive integer")
            if not isinstance(task["idempotency_key"], str) or not task["idempotency_key"]:
                raise ValueError("Task idempotency_key is required")
            if task["idempotency_key"] in keys:
                raise ValueError("idempotency_key must be unique within a package")
            if not isinstance(task["metadata"], dict):
                raise ValueError("Task metadata must be an object")  # noqa: TRY004
            task_ids.add(task["task_id"])
            keys.add(task["idempotency_key"])
            tasks.append(task)
        if not tasks:
            raise ValueError("Task package contains no tasks")
        sequences = [task["sequence"] for task in tasks]
        if len(sequences) != len(set(sequences)):
            raise ValueError("Task sequence values must be unique")
        return sorted(tasks, key=lambda item: item["sequence"])
