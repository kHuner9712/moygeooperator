from __future__ import annotations

import hashlib
import json
import os
import tempfile
import uuid
import zipfile
from pathlib import Path
from typing import Any

from geo_operator.core.db import Database
from geo_operator.core.storage import ArtifactStore
from geo_operator.core.time import utc_now
from geo_operator.domain import ApprovalStage


class ClientProfileService:
    def __init__(self, database: Database, artifacts: ArtifactStore) -> None:
        self.database, self.artifacts = database, artifacts

    def build_draft(self, tenant_id: str) -> dict[str, Any]:
        tenant = self.database.one("SELECT * FROM tenants WHERE id=?", (tenant_id,))
        if not tenant:
            raise KeyError("Tenant not found")
        assets = self.database.all(
            """SELECT id,original_name,media_type,content_sha256,size,extraction_status,
                      extracted_text_path,created_at
               FROM source_assets WHERE tenant_id=? ORDER BY created_at""", (tenant_id,)
        )
        pages = self.database.all(
            """SELECT id,source_url,final_url,title,content_sha256,text_path,captured_at
               FROM website_pages WHERE tenant_id=? AND status='COLLECTED'
               ORDER BY captured_at""", (tenant_id,)
        )
        if not assets and not pages:
            raise ValueError("Upload source files or crawl the official website first")
        profile = {
            "schema_version": "1.0",
            "tenant": {"id": tenant_id, "name": tenant["name"]},
            "materials": {"source_assets": assets, "official_website_pages": pages},
            "assembly_policy": "MECHANICAL_INDEX_ONLY_NO_GEO_ANALYSIS",
            "public_discovery_included": False,
            "assembled_at": utc_now(),
        }
        return self.save_draft(
            tenant_id, profile,
            [str(asset["id"]) for asset in assets],
            [str(page["id"]) for page in pages],
        )

    def save_draft(
        self,
        tenant_id: str,
        profile: dict[str, Any],
        source_asset_ids: list[str] | None = None,
        website_page_ids: list[str] | None = None,
    ) -> dict[str, Any]:
        if not self.database.one("SELECT id FROM tenants WHERE id=?", (tenant_id,)):
            raise KeyError("Tenant not found")
        if not profile:
            raise ValueError("Client profile cannot be empty")
        asset_ids = self._resource_ids(
            tenant_id, "source_assets", source_asset_ids, "Source asset", "created_at"
        )
        page_ids = self._resource_ids(
            tenant_id, "website_pages", website_page_ids, "Website page", "captured_at",
            status_filter="status='COLLECTED'",
        )
        profile_id, approval_id, now = uuid.uuid4().hex, uuid.uuid4().hex, utc_now()
        content = json.dumps(profile, ensure_ascii=False, indent=2).encode()
        self.artifacts.atomic_write(tenant_id, f"profile/{profile_id}.json", content)
        with self.database.transaction() as connection:
            connection.execute(
                """INSERT INTO client_profiles(
                   id,tenant_id,profile_json,status,approval_id,source_asset_ids_json,
                   website_page_ids_json,created_at,updated_at)
                   VALUES (?,?,?,'WAIT_HUMAN_APPROVAL',?,?,?,?,?)""",
                (
                    profile_id, tenant_id, content.decode(), approval_id,
                    json.dumps(asset_ids), json.dumps(page_ids), now, now,
                ),
            )
            connection.execute(
                """INSERT INTO approvals(
                   id,tenant_id,stage,resource_type,resource_id,status,requested_at)
                   VALUES (?,?,?,?,?,'PENDING',?)""",
                (
                    approval_id, tenant_id, ApprovalStage.CLIENT_PROFILE_REVIEW.value,
                    "client_profile", profile_id, now,
                ),
            )
        return self.get(profile_id)

    def mark_decision(self, profile_id: str, approved: bool) -> dict[str, Any]:
        with self.database.transaction() as connection:
            row = connection.execute(
                "SELECT * FROM client_profiles WHERE id=?", (profile_id,)
            ).fetchone()
            if not row:
                raise KeyError("Client profile not found")
            if row["status"] != "WAIT_HUMAN_APPROVAL":
                raise ValueError("Client profile decision has already been applied")
            connection.execute(
                "UPDATE client_profiles SET status=?,updated_at=? WHERE id=?",
                ("APPROVED" if approved else "REJECTED", utc_now(), profile_id),
            )
        return self.get(profile_id)

    def latest(self, tenant_id: str) -> dict[str, Any] | None:
        row = self.database.one(
            """SELECT * FROM client_profiles WHERE tenant_id=?
               ORDER BY created_at DESC LIMIT 1""", (tenant_id,)
        )
        return self._hydrate(row) if row else None

    def get(self, profile_id: str) -> dict[str, Any]:
        row = self.database.one("SELECT * FROM client_profiles WHERE id=?", (profile_id,))
        if not row:
            raise KeyError("Client profile not found")
        return self._hydrate(row)

    def has_approved(self, tenant_id: str) -> bool:
        return bool(self.database.one(
            """SELECT id FROM client_profiles WHERE tenant_id=? AND status='APPROVED'
               ORDER BY created_at DESC LIMIT 1""", (tenant_id,)
        ))

    def export(self, profile_id: str) -> Path:
        profile = self.get(profile_id)
        if profile["status"] != "APPROVED":
            raise ValueError("CLIENT_PROFILE_REVIEW approval is required")
        tenant_id = str(profile["tenant_id"])
        export_id = uuid.uuid4().hex
        relative = f"exports/CLIENT_PROFILE_{profile_id}.zip"
        target = self.artifacts.resolve(tenant_id, relative)
        target.parent.mkdir(parents=True, exist_ok=True)
        handle, temporary = tempfile.mkstemp(prefix=".client-profile.", dir=target.parent)
        os.close(handle)
        files: list[dict[str, object]] = []
        try:
            with zipfile.ZipFile(temporary, "w", zipfile.ZIP_DEFLATED) as archive:
                self._write_bytes(
                    archive, "profile/client_profile.json",
                    str(profile["profile_json"]).encode(), files,
                )
                pages_index: list[str] = []
                for page_id in profile["website_page_ids"]:
                    page = self.database.one(
                        "SELECT * FROM website_pages WHERE id=? AND tenant_id=?",
                        (page_id, tenant_id),
                    )
                    if not page or not page["text_path"]:
                        continue
                    archive_name = f"website/text/{page_id}.txt"
                    self._write_path(
                        archive, archive_name,
                        self.artifacts.resolve(tenant_id, str(page["text_path"])), files,
                    )
                    record = dict(page)
                    record["text_path"] = archive_name
                    pages_index.append(json.dumps(record, ensure_ascii=False))
                self._write_bytes(
                    archive, "website/pages.jsonl",
                    (("\n".join(pages_index) + "\n") if pages_index else "").encode(), files,
                )
                for asset_id in profile["source_asset_ids"]:
                    asset = self.database.one(
                        "SELECT * FROM source_assets WHERE id=? AND tenant_id=?",
                        (asset_id, tenant_id),
                    )
                    if not asset:
                        continue
                    archive_name = f"source/{asset_id}_{asset['original_name']}"
                    self._write_path(
                        archive, archive_name,
                        self.artifacts.resolve(tenant_id, str(asset["relative_path"])), files,
                    )
                manifest = {
                    "schema_version": "1.0", "package_type": "CLIENT_PROFILE",
                    "tenant_id": tenant_id, "profile_id": profile_id,
                    "export_id": export_id, "created_at": utc_now(), "files": files,
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
        package_hash = self.artifacts.record_existing(tenant_id, relative)
        with self.database.transaction() as connection:
            connection.execute(
                """INSERT INTO exports(id,tenant_id,package_type,relative_path,sha256,created_at)
                   VALUES (?,?,'CLIENT_PROFILE',?,?,?)""",
                (export_id, tenant_id, relative, package_hash, utc_now()),
            )
        return target

    def _resource_ids(
        self, tenant_id: str, table: str, requested: list[str] | None,
        label: str, order_column: str, status_filter: str | None = None,
    ) -> list[str]:
        where = "tenant_id=?" + (f" AND {status_filter}" if status_filter else "")
        rows = self.database.all(
            f"SELECT id FROM {table} WHERE {where} ORDER BY {order_column}", (tenant_id,)
        )
        ordered = [str(row["id"]) for row in rows]
        available = set(ordered)
        selected = list(dict.fromkeys(requested)) if requested is not None else ordered
        unknown = [item for item in selected if item not in available]
        if unknown:
            raise ValueError(f"{label} does not belong to tenant or is unavailable: {unknown[0]}")
        return selected

    @staticmethod
    def _hydrate(row: dict[str, Any]) -> dict[str, Any]:
        row["profile"] = json.loads(str(row["profile_json"]))
        row["source_asset_ids"] = json.loads(str(row.get("source_asset_ids_json") or "[]"))
        row["website_page_ids"] = json.loads(str(row.get("website_page_ids_json") or "[]"))
        return row

    @staticmethod
    def _write_bytes(
        archive: zipfile.ZipFile, name: str, content: bytes,
        files: list[dict[str, object]],
    ) -> None:
        archive.writestr(name, content)
        files.append({
            "path": name, "sha256": hashlib.sha256(content).hexdigest(), "size": len(content)
        })

    @classmethod
    def _write_path(
        cls, archive: zipfile.ZipFile, name: str, path: Path,
        files: list[dict[str, object]],
    ) -> None:
        cls._write_bytes(archive, name, path.read_bytes(), files)
