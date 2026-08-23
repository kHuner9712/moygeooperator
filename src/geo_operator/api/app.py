from __future__ import annotations

import asyncio
import base64
import json
import sqlite3
import time
import uuid
import zipfile
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urlsplit

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, HTMLResponse
from pydantic import BaseModel, Field

from geo_operator import __version__
from geo_operator.approvals import ApprovalService
from geo_operator.browser import ExecutionStateMachine
from geo_operator.browser.lease import ExecutionLeaseManager
from geo_operator.browser.plugins.catalog import live_plugin, live_plugins
from geo_operator.browser.session import (
    BrowserSessionManager,
    ManualLoginLauncher,
    system_chrome_path,
)
from geo_operator.core.config import Settings
from geo_operator.core.db import Database
from geo_operator.core.storage import ArtifactStore
from geo_operator.core.time import utc_now
from geo_operator.discovery import PublicDiscoveryService
from geo_operator.domain import PauseReason
from geo_operator.exports import ResultPackageService
from geo_operator.mock_platform import router as mock_router
from geo_operator.platforms import platform_definition
from geo_operator.profiles import ClientProfileService
from geo_operator.results import ResultService
from geo_operator.runtime import RuntimeWorkerRegistry
from geo_operator.sources import SourceIngestionService
from geo_operator.tasks import DuplicateTaskPackageError, TaskPackageService
from geo_operator.tenants import TenantService
from geo_operator.websites import WebsiteCrawlerService


class TenantCreate(BaseModel):
    name: str = Field(min_length=1, max_length=200)


class TenantDeleteRequest(BaseModel):
    confirm_name: str = Field(min_length=1, max_length=200)


class EvidenceCreate(BaseModel):
    source_url: str
    raw_text: str = Field(min_length=1)
    screenshot_base64: str
    source_type: str = Field(min_length=1, max_length=100)


class ApprovalDecision(BaseModel):
    approved: bool
    actor: str = Field(min_length=1, max_length=100)
    note: str = Field(default="", max_length=2000)


class ProfileCreate(BaseModel):
    profile: dict[str, Any]
    source_asset_ids: list[str] | None = None
    website_page_ids: list[str] | None = None


class WebsiteCrawlRequest(BaseModel):
    start_url: str
    max_pages: int = Field(default=20, ge=1, le=50)


class DiscoveryURLRequest(BaseModel):
    source_url: str
    source_type: str = Field(min_length=1, max_length=100)


class ResumeRequest(BaseModel):
    note: str = Field(default="", max_length=2000)


class SessionOpen(BaseModel):
    tenant_id: str
    platform: str
    account_id: str = "manual"


class CalibrationSnapshotRequest(SessionOpen):
    target_url: str | None = None
    stage: str = Field(default="HOME_STRUCTURE", min_length=1, max_length=100)
    preserve_current_page: bool = False
    inspect_conversation_menu: bool = False
    inspect_delete_confirmation: bool = False
    execution_id: str | None = None


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings.from_env()
    database = Database(settings.database_path)
    database.initialize()
    artifacts = ArtifactStore(settings.data_root, database)
    tenants = TenantService(database, artifacts)
    approvals = ApprovalService(database)
    discovery = PublicDiscoveryService(database, artifacts)
    profiles = ClientProfileService(database, artifacts)
    sources = SourceIngestionService(database, artifacts)
    websites = WebsiteCrawlerService(database, artifacts)
    task_packages = TaskPackageService(database, artifacts)
    engine = ExecutionStateMachine(database)
    leases = ExecutionLeaseManager(database)
    sessions = BrowserSessionManager(artifacts, database, browser_channel=settings.browser_channel)
    manual_logins = ManualLoginLauncher(artifacts, database)
    results = ResultService(database, artifacts)
    result_packages = ResultPackageService(database, artifacts, approvals)
    runtime_workers = RuntimeWorkerRegistry(database)

    app = FastAPI(title="GEO Operator V2", version=__version__)
    app.include_router(mock_router)
    app.state.services = {
        "database": database,
        "artifacts": artifacts,
        "tenants": tenants,
        "approvals": approvals,
        "discovery": discovery,
        "profiles": profiles,
        "sources": sources,
        "websites": websites,
        "task_packages": task_packages,
        "engine": engine,
        "leases": leases,
        "sessions": sessions,
        "manual_logins": manual_logins,
        "results": results,
        "result_packages": result_packages,
        "runtime_workers": runtime_workers,
    }

    def require_tenant(tenant_id: str) -> None:
        tenant = database.one("SELECT id,status FROM tenants WHERE id=?", (tenant_id,))
        if not tenant:
            raise ValueError("Tenant not found")
        if tenant["status"] != "ACTIVE":
            raise ValueError("Customer is being deleted")

    @app.get("/", response_class=HTMLResponse)
    def dashboard() -> HTMLResponse:
        path = Path(__file__).with_name("static") / "index.html"
        return HTMLResponse(path.read_text(encoding="utf-8"))

    @app.get("/api/platforms")
    def platform_status() -> list[dict[str, object]]:
        statuses: list[dict[str, object]] = []
        for plugin in live_plugins():
            definition = platform_definition(plugin.name)
            status = plugin.calibration_status()
            status.update(
                {
                    "label": definition.label,
                    "region": definition.region,
                    "home_url": definition.home_url,
                    "policy": ("PAUSED" if status.get("integration_paused") else "ALLOWED"),
                }
            )
            statuses.append(status)
        statuses.append(
            {
                "platform": "mock",
                "label": "Mock",
                "region": "INTERNAL",
                "phase": 0,
                "complete": True,
                "support_status": "TEST_ONLY",
                "dispatch_eligible": True,
                "missing": [],
                "policy": "TEST_ONLY",
            }
        )
        return statuses

    @app.get("/api/health")
    def health() -> dict[str, Any]:
        worker = runtime_workers.latest("BROWSER")
        queue = (
            database.one(
                """SELECT
                 COALESCE(SUM(CASE WHEN state NOT IN
                   ('COMPLETED','FAILED','PAUSED','WAIT_HUMAN_APPROVAL') THEN 1 ELSE 0 END),0)
                   AS queued,
                 COALESCE(SUM(CASE WHEN state='WAIT_HUMAN_APPROVAL' THEN 1 ELSE 0 END),0)
                   AS waiting_approval,
                 COALESCE(SUM(CASE WHEN state='PAUSED' THEN 1 ELSE 0 END),0)
                   AS paused,
                 COALESCE(SUM(CASE WHEN state='FAILED' THEN 1 ELSE 0 END),0)
                   AS failed
               FROM executions"""
            )
            or {}
        )
        return {
            "status": "ok" if worker["available"] else "degraded",
            "control_service": "ok",
            "worker": worker,
            "queue": queue,
            "python": "3.12",
            "browser_mode": "headed",
            "browser_channel": settings.browser_channel or "playwright-chromium",
            "manual_login_browser": str(system_chrome_path()),
        }

    @app.get("/api/tenants")
    def list_tenants() -> list[dict[str, object]]:
        return tenants.list()

    @app.post("/api/tenants", status_code=201)
    def create_tenant(body: TenantCreate) -> dict[str, object]:
        return tenants.create(body.name)

    @app.delete("/api/tenants/{tenant_id}")
    async def delete_tenant(tenant_id: str, body: TenantDeleteRequest) -> dict[str, Any]:
        try:
            tenant = tenants.get(tenant_id)
            if body.confirm_name.strip() != tenant["name"]:
                raise ValueError("Customer name confirmation does not match")
            manual_logins.ensure_tenant_closed(tenant_id)
            tenants.begin_delete(tenant_id, body.confirm_name)
            await sessions.close_tenant(tenant_id)

            deadline = time.monotonic() + 35.0
            session_deadline = time.monotonic() + 5.0
            while tenants.has_active_leases(tenant_id) or (
                tenants.has_open_sessions(tenant_id) and time.monotonic() < session_deadline
            ):
                leases.release_expired()
                if time.monotonic() >= deadline:
                    raise ValueError(
                        "Browser Worker is still stopping this customer; retry deletion shortly"
                    )
                await asyncio.sleep(0.1)
            return tenants.purge(tenant_id)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc
        except OSError as exc:
            raise HTTPException(
                status_code=409,
                detail="Customer files are still in use; close its browser windows and retry",
            ) from exc
        except ValueError as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc

    @app.get("/api/approvals")
    def list_approvals() -> list[dict[str, object]]:
        return database.all("SELECT * FROM approvals ORDER BY requested_at DESC")

    @app.post("/api/approvals/{approval_id}/decision")
    def decide_approval(approval_id: str, body: ApprovalDecision) -> dict[str, object]:
        try:
            pending = approvals.get(approval_id)
            if pending["resource_type"] == "task_package" and body.approved:
                package_for_gate = task_packages.get(str(pending["resource_id"]))
                if not profiles.has_approved(str(package_for_gate["tenant_id"])):
                    raise ValueError(
                        "An approved client profile is required before TASK_EXECUTION approval"
                    )
            approval = approvals.decide(approval_id, body.approved, body.actor, body.note)
            if approval["resource_type"] == "client_profile":
                profiles.mark_decision(str(approval["resource_id"]), body.approved)
            elif approval["resource_type"] == "task_package":
                package = task_packages.mark_decision(str(approval["resource_id"]), body.approved)
                if body.approved:
                    for task in package["tasks"]:
                        existing = database.one(
                            "SELECT id FROM executions WHERE task_id=?", (task["id"],)
                        )
                        if not existing:
                            engine.create(
                                str(task["tenant_id"]),
                                str(task["platform"]),
                                str(task["account_id"]),
                                str(task["task_package_id"]),
                                str(task["id"]),
                            )
            elif approval["resource_type"] == "execution":
                engine.resolve_approval(str(approval["resource_id"]), body.approved)
            return approval
        except (KeyError, ValueError, sqlite3.IntegrityError) as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc

    @app.get("/api/tenants/{tenant_id}/profile")
    def get_profile(tenant_id: str) -> dict[str, Any]:
        profile = profiles.latest(tenant_id)
        if not profile:
            raise HTTPException(status_code=404, detail="Client profile not found")
        return profile

    @app.post("/api/tenants/{tenant_id}/profile/build", status_code=201)
    def build_profile(tenant_id: str) -> dict[str, Any]:
        try:
            return profiles.build_draft(tenant_id)
        except (KeyError, ValueError) as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc

    @app.post("/api/tenants/{tenant_id}/profile", status_code=201)
    def save_profile(tenant_id: str, body: ProfileCreate) -> dict[str, Any]:
        try:
            return profiles.save_draft(
                tenant_id, body.profile, body.source_asset_ids, body.website_page_ids
            )
        except (KeyError, ValueError) as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc

    @app.post("/api/profiles/{profile_id}/export")
    def export_profile(profile_id: str) -> FileResponse:
        try:
            path = profiles.export(profile_id)
            return FileResponse(path, filename="CLIENT_PROFILE.zip")
        except (KeyError, ValueError) as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc

    @app.post("/api/tenants/{tenant_id}/sources", status_code=201)
    async def upload_source(tenant_id: str, request: Request) -> dict[str, Any]:
        try:
            filename = unquote(request.headers.get("x-filename", ""))
            return sources.ingest(
                tenant_id, filename, await request.body(), request.headers.get("content-type")
            )
        except (KeyError, UnicodeError, ValueError) as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc

    @app.get("/api/tenants/{tenant_id}/sources")
    def list_sources(tenant_id: str) -> list[dict[str, Any]]:
        try:
            require_tenant(tenant_id)
            return sources.list(tenant_id)
        except ValueError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc

    @app.post("/api/tenants/{tenant_id}/website-crawls", status_code=201)
    async def crawl_website(tenant_id: str, body: WebsiteCrawlRequest) -> dict[str, Any]:
        try:
            return await websites.crawl(tenant_id, body.start_url, body.max_pages)
        except (KeyError, ValueError) as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc

    @app.get("/api/tenants/{tenant_id}/website-pages")
    def list_website_pages(tenant_id: str, crawl_id: str | None = None) -> list[dict[str, Any]]:
        try:
            require_tenant(tenant_id)
            return websites.list(tenant_id, crawl_id)
        except ValueError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc

    @app.post("/api/tenants/{tenant_id}/task-packages", status_code=201)
    async def import_task_package(tenant_id: str, request: Request) -> dict[str, Any]:
        try:
            return task_packages.import_zip(tenant_id, await request.body())
        except DuplicateTaskPackageError as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc
        except (KeyError, ValueError, zipfile.BadZipFile) as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc

    @app.get("/api/task-packages")
    def list_task_packages(tenant_id: str | None = None) -> list[dict[str, Any]]:
        return task_packages.list(tenant_id)

    @app.get("/api/task-packages/{package_id}")
    def get_task_package(package_id: str) -> dict[str, Any]:
        try:
            return task_packages.get(package_id)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc

    @app.get("/api/executions")
    def list_executions() -> list[dict[str, object]]:
        return database.all(
            """SELECT e.*,t.external_task_id,t.prompt,t.sequence
               FROM executions e LEFT JOIN tasks t ON t.id=e.task_id
               ORDER BY e.updated_at DESC"""
        )

    @app.post("/api/executions/{execution_id}/run")
    def run_execution(execution_id: str) -> dict[str, str]:
        try:
            execution = engine.get(execution_id)
            if execution["state"] in {"COMPLETED", "FAILED", "PAUSED"}:
                raise ValueError("Execution is not eligible for normal worker dispatch")
            if execution["platform"] != "mock":
                plugin = live_plugin(execution["platform"])
                if not plugin.calibration_complete:
                    support_status = plugin.calibration_status()["support_status"]
                    raise ValueError(
                        f"{execution['platform']} is {support_status}; "
                        "real task dispatch is disabled"
                    )
            return {"status": "queued_for_independent_worker", "execution_id": execution_id}
        except (KeyError, ValueError) as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc

    @app.post("/api/executions/{execution_id}/pause")
    def pause_execution(execution_id: str) -> dict[str, object]:
        try:
            return engine.pause(execution_id, PauseReason.OPERATOR_REQUESTED)
        except (KeyError, ValueError) as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc

    @app.post("/api/executions/{execution_id}/resume-request")
    def request_resume(execution_id: str, body: ResumeRequest) -> dict[str, object]:
        try:
            return engine.request_resume(execution_id, body.note)
        except (KeyError, ValueError) as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc

    @app.post("/api/executions/{execution_id}/continue")
    def continue_execution(execution_id: str, body: ResumeRequest) -> dict[str, object]:
        try:
            return engine.request_resume(execution_id, body.note)
        except (KeyError, ValueError) as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc

    @app.get("/api/executions/{execution_id}/pause-evidence")
    def pause_evidence(execution_id: str) -> dict[str, Any]:
        event = database.one(
            """SELECT payload_json,created_at FROM execution_events
               WHERE execution_id=? AND event_type='EXECUTION_PAUSED'
               ORDER BY sequence DESC LIMIT 1""",
            (execution_id,),
        )
        if not event:
            raise HTTPException(status_code=404, detail="Pause evidence not found")
        payload = json.loads(str(event["payload_json"]))
        payload["created_at"] = event["created_at"]
        return payload

    @app.get("/api/executions/{execution_id}/pause-screenshot")
    def pause_screenshot(execution_id: str) -> FileResponse:
        execution = engine.get(execution_id)
        event = pause_evidence(execution_id)
        relative = event.get("screenshot_path")
        if not relative:
            raise HTTPException(status_code=404, detail="Pause screenshot not available")
        return FileResponse(
            artifacts.resolve(str(execution["tenant_id"]), str(relative)),
            media_type="image/png",
        )

    @app.get("/api/executions/{execution_id}/checkpoints")
    def list_checkpoints(execution_id: str) -> list[dict[str, Any]]:
        return database.all(
            """SELECT * FROM response_checkpoints WHERE execution_id=?
               ORDER BY sequence DESC""",
            (execution_id,),
        )

    @app.post("/api/task-packages/{package_id}/result-export-approval")
    def request_result_export(package_id: str) -> dict[str, Any]:
        try:
            return result_packages.request_approval(package_id)
        except (KeyError, ValueError) as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc

    @app.post("/api/task-packages/{package_id}/result-export")
    def export_results(package_id: str) -> FileResponse:
        try:
            path = result_packages.export(package_id)
            return FileResponse(path, filename="RESULT_PACKAGE.zip")
        except (KeyError, ValueError) as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc

    @app.post("/api/sessions/open")
    async def open_session(body: SessionOpen) -> dict[str, str]:
        try:
            require_tenant(body.tenant_id)
            plugin = live_plugin(body.platform)
            if getattr(plugin, "integration_paused", False):
                raise ValueError(f"{plugin.name} integration is paused")
            manual_logins.open(body.tenant_id, body.platform, body.account_id, plugin.home_url)
            return {
                "status": "WAIT_MANUAL_LOGIN",
                "platform": body.platform,
                "browser": "system_google_chrome_unmanaged",
            }
        except ValueError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc
        except Exception as exc:
            raise HTTPException(
                status_code=409,
                detail=f"Session open failed closed: {type(exc).__name__}",
            ) from exc

    @app.post("/api/sessions/calibration-snapshot")
    async def session_calibration_snapshot(
        body: CalibrationSnapshotRequest,
    ) -> dict[str, Any]:
        """Return visible DOM structure only: no text, cookies, storage, or screenshots."""
        try:
            require_tenant(body.tenant_id)
            plugin = live_plugin(body.platform)
            if getattr(plugin, "integration_paused", False):
                raise ValueError(f"{plugin.name} integration is paused")
            target_url = body.target_url
            if target_url and body.preserve_current_page:
                raise ValueError("target_url and preserve_current_page cannot be combined")
            if target_url:
                target = urlsplit(target_url)
                home = urlsplit(plugin.home_url)
                if (
                    target.scheme != "https"
                    or target.netloc != home.netloc
                    or target.username
                    or target.password
                ):
                    raise ValueError("Calibration target_url must be same-origin HTTPS")
            manual_logins.ensure_closed(body.tenant_id, body.platform, body.account_id)
            context = await sessions.open(
                body.tenant_id, body.platform, body.account_id, headless=False
            )
            page = context.pages[-1] if context.pages else await context.new_page()
            if body.preserve_current_page:
                hydration = "PRESERVED_CURRENT_PAGE"
            elif target_url:
                await page.goto(target_url, wait_until="domcontentloaded")
                hydration = await plugin.wait_for_calibration_hydration(page)
            else:
                await plugin.open_platform(page)
                hydration = await plugin.wait_for_home_hydration(page)
            menu_inspection = "NOT_REQUESTED"
            delete_confirmation_inspection = "NOT_REQUESTED"
            if body.inspect_delete_confirmation and not body.inspect_conversation_menu:
                raise ValueError("Delete confirmation inspection requires menu inspection")
            if body.inspect_conversation_menu:
                if body.platform not in {"chatgpt", "doubao"} or not target_url:
                    raise ValueError(
                        "Conversation menu inspection requires a calibrated ChatGPT/Doubao target_url"
                    )
                if body.platform == "chatgpt":
                    menu_button = page.locator("button[data-testid='conversation-options-button']")
                    if await menu_button.count() != 1 or not await menu_button.is_visible():
                        raise ValueError("Conversation menu button is not uniquely visible")
                    await menu_button.click()
                else:
                    conversation_id = urlsplit(target_url).path.rstrip("/").rsplit("/", 1)[-1]
                    if not conversation_id.isdigit():
                        raise ValueError("Doubao conversation id must be numeric")
                    conversation_item = page.locator(f"a#conversation_{conversation_id}")
                    try:
                        await conversation_item.wait_for(state="visible", timeout=10_000)
                    except Exception as exc:
                        if type(exc).__name__ != "TimeoutError":
                            raise
                        raise ValueError("Doubao conversation item did not become visible") from exc
                    if await conversation_item.count() != 1:
                        raise ValueError("Doubao conversation item is not unique")
                    await conversation_item.scroll_into_view_if_needed()
                    if not await conversation_item.is_visible():
                        raise ValueError("Doubao conversation item is not visible")
                    await conversation_item.hover()
                    descendants = conversation_item.locator("button")
                    visible_buttons = []
                    for index in range(await descendants.count()):
                        candidate = descendants.nth(index)
                        if await candidate.is_visible():
                            visible_buttons.append(candidate)
                    if len(visible_buttons) != 1:
                        raise ValueError("Doubao conversation menu button is not uniquely visible")
                    await visible_buttons[0].click()
                try:
                    await page.locator("[role='menuitem']").first.wait_for(
                        state="visible", timeout=5_000
                    )
                    menu_inspection = "MENUITEM_VISIBLE"
                except Exception as exc:
                    if type(exc).__name__ != "TimeoutError":
                        raise
                    menu_inspection = "STRUCTURE_TIMEOUT"
                if body.inspect_delete_confirmation:
                    if body.platform == "chatgpt":
                        delete_control = page.locator("[data-testid='delete-chat-menu-item']")
                    else:
                        delete_control = page.get_by_role(
                            "menuitem", name="\u5220\u9664", exact=True
                        )
                    if await delete_control.count() != 1 or not await delete_control.is_visible():
                        raise ValueError("Delete menu item is not uniquely visible")
                    await delete_control.click()
                    try:
                        await page.locator("[role='dialog'],[role='alertdialog']").first.wait_for(
                            state="visible", timeout=5_000
                        )
                        delete_confirmation_inspection = "DIALOG_VISIBLE"
                    except Exception as exc:
                        if type(exc).__name__ != "TimeoutError":
                            raise
                        delete_confirmation_inspection = "STRUCTURE_TIMEOUT"
            logged_in = await plugin.detect_login(page)
            recovery_bound = False
            if body.execution_id:
                if not target_url or hydration != "CONVERSATION_CONTENT" or not logged_in:
                    raise ValueError(
                        "Recovery URL requires hydrated logged-in target "
                        f"(target={bool(target_url)}, hydration={hydration}, logged_in={logged_in})"
                    )
                final_url = urlsplit(page.url)
                if (
                    final_url.scheme != "https"
                    or final_url.netloc != home.netloc
                    or final_url.username
                    or final_url.password
                ):
                    raise ValueError("Recovery URL final page must remain same-origin HTTPS")
                execution = engine.get(body.execution_id)
                if (
                    str(execution["tenant_id"]) != body.tenant_id
                    or str(execution["platform"]) != body.platform
                    or str(execution["account_id"]) != body.account_id
                ):
                    raise ValueError("Recovery URL execution identity mismatch")
                engine.bind_recovery_url(body.execution_id, page.url)
                recovery_bound = True
            elements = await plugin.structural_snapshot(page)
            origin = await page.evaluate("location.origin")
            calibration_id = uuid.uuid4().hex
            relative = f"calibration/{body.platform}/{calibration_id}.json"
            privacy = "STRUCTURE_ONLY_NO_TEXT_NO_STORAGE_NO_COOKIES"
            snapshot = {
                "calibration_id": calibration_id,
                "platform": body.platform,
                "account_id": body.account_id,
                "stage": body.stage,
                "url": page.url,
                "origin": origin,
                "hydration": hydration,
                "elements": elements,
                "privacy": privacy,
                "captured_at": utc_now(),
            }
            artifacts.atomic_write(
                body.tenant_id,
                relative,
                json.dumps(snapshot, ensure_ascii=False, indent=2).encode(),
            )
            with database.transaction() as connection:
                connection.execute(
                    """INSERT INTO platform_calibrations(
                       id,tenant_id,platform,account_id,stage,page_url,origin,
                       relative_path,privacy,created_at)
                       VALUES (?,?,?,?,?,?,?,?,?,?)""",
                    (
                        calibration_id,
                        body.tenant_id,
                        body.platform,
                        body.account_id,
                        body.stage,
                        page.url,
                        origin,
                        relative,
                        privacy,
                        utc_now(),
                    ),
                )
            return {
                "calibration_id": calibration_id,
                "calibration_path": relative,
                "platform": body.platform,
                "account_id": body.account_id,
                "logged_in": logged_in,
                "url": page.url,
                "origin": origin,
                "hydration": hydration,
                "menu_inspection": menu_inspection,
                "delete_confirmation_inspection": delete_confirmation_inspection,
                "recovery_bound": recovery_bound,
                "privacy": privacy,
                "plugin": plugin.calibration_status(),
                "elements": elements,
            }
        except (KeyError, ValueError) as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc
        except Exception as exc:
            raise HTTPException(
                status_code=409,
                detail=f"Calibration snapshot failed closed: {type(exc).__name__}",
            ) from exc

    @app.get("/api/calibrations")
    def list_calibrations(
        tenant_id: str | None = None, platform: str | None = None
    ) -> list[dict[str, Any]]:
        clauses: list[str] = []
        params: list[str] = []
        if tenant_id:
            clauses.append("tenant_id=?")
            params.append(tenant_id)
        if platform:
            try:
                platform = live_plugin(platform).name
            except ValueError as exc:
                raise HTTPException(status_code=422, detail=str(exc)) from exc
            clauses.append("platform=?")
            params.append(platform)
        where = " WHERE " + " AND ".join(clauses) if clauses else ""
        return database.all(
            "SELECT * FROM platform_calibrations" + where + " ORDER BY created_at DESC",
            tuple(params),
        )

    @app.post("/api/sessions/close")
    async def close_session(body: SessionOpen) -> dict[str, str]:
        try:
            require_tenant(body.tenant_id)
            live_plugin(body.platform)
            BrowserSessionManager.validate_identity(body.platform, body.account_id)
            manual_logins.ensure_closed(body.tenant_id, body.platform, body.account_id)
            await sessions.close(body.tenant_id, body.platform, body.account_id)
            return {"status": "RELEASED_TO_WORKER", "platform": body.platform}
        except ValueError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc

    @app.get("/api/sessions")
    def list_sessions() -> list[dict[str, Any]]:
        return database.all(
            """SELECT s.*,
               (
                 SELECT e.pause_reason FROM executions e
                 WHERE e.tenant_id=s.tenant_id
                   AND e.platform=s.platform
                   AND e.account_id=s.account_id
                   AND e.state='PAUSED'
                   AND e.pause_reason IN (
                     'CAPTCHA','LOGIN_EXPIRED','SECURITY_CHALLENGE',
                     'RATE_LIMITED','ACCOUNT_RESTRICTED'
                   )
                 ORDER BY e.updated_at DESC LIMIT 1
               ) AS intervention_reason,
               (
                 SELECT e.id FROM executions e
                 WHERE e.tenant_id=s.tenant_id
                   AND e.platform=s.platform
                   AND e.account_id=s.account_id
                   AND e.state='PAUSED'
                   AND e.pause_reason IN (
                     'CAPTCHA','LOGIN_EXPIRED','SECURITY_CHALLENGE',
                     'RATE_LIMITED','ACCOUNT_RESTRICTED'
                   )
                 ORDER BY e.updated_at DESC LIMIT 1
               ) AS blocking_execution_id
               FROM browser_sessions s ORDER BY s.updated_at DESC"""
        )

    @app.post("/api/tenants/{tenant_id}/discovery", status_code=201)
    def collect_evidence(tenant_id: str, body: EvidenceCreate) -> dict[str, object]:
        try:
            screenshot = base64.b64decode(body.screenshot_base64, validate=True)
            return discovery.collect(
                tenant_id, body.source_url, body.raw_text, screenshot, body.source_type
            )
        except (ValueError, KeyError) as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc

    @app.post("/api/tenants/{tenant_id}/discovery/collect-url", status_code=201)
    async def collect_evidence_url(tenant_id: str, body: DiscoveryURLRequest) -> dict[str, object]:
        try:
            return await discovery.collect_url(tenant_id, body.source_url, body.source_type)
        except (KeyError, ValueError) as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc
        except Exception as exc:
            raise HTTPException(
                status_code=409,
                detail=f"Public discovery collection failed closed: {type(exc).__name__}",
            ) from exc

    @app.get("/api/tenants/{tenant_id}/discovery")
    def list_evidence(tenant_id: str) -> list[dict[str, object]]:
        return discovery.list(tenant_id)

    @app.post("/api/tenants/{tenant_id}/discovery/export")
    def export_discovery(tenant_id: str) -> FileResponse:
        try:
            path = discovery.export(tenant_id)
            return FileResponse(path, filename="PUBLIC_DISCOVERY.zip")
        except ValueError as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc

    return app
