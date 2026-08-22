from __future__ import annotations

import base64
import json
import sqlite3
import zipfile
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, HTMLResponse
from pydantic import BaseModel, Field

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
from geo_operator.discovery import PublicDiscoveryService
from geo_operator.domain import PauseReason
from geo_operator.exports import ResultPackageService
from geo_operator.mock_platform import router as mock_router
from geo_operator.platforms import platform_definition
from geo_operator.profiles import ClientProfileService
from geo_operator.results import ResultService
from geo_operator.tasks import DuplicateTaskPackageError, TaskPackageService
from geo_operator.tenants import TenantService


class TenantCreate(BaseModel):
    name: str = Field(min_length=1, max_length=200)


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


class ResumeRequest(BaseModel):
    note: str = Field(default="", max_length=2000)


class SessionOpen(BaseModel):
    tenant_id: str
    platform: str
    account_id: str = "manual"


class CalibrationSnapshotRequest(SessionOpen):
    target_url: str | None = None
    inspect_conversation_menu: bool = False
    inspect_delete_confirmation: bool = False
    execution_id: str | None = None


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings.from_env()
    database = Database(settings.database_path)
    database.initialize()
    artifacts = ArtifactStore(settings.data_root)
    tenants = TenantService(database, artifacts)
    approvals = ApprovalService(database)
    discovery = PublicDiscoveryService(database, artifacts)
    profiles = ClientProfileService(database, artifacts)
    task_packages = TaskPackageService(database, artifacts)
    engine = ExecutionStateMachine(database)
    leases = ExecutionLeaseManager(database)
    sessions = BrowserSessionManager(artifacts, database, browser_channel=settings.browser_channel)
    manual_logins = ManualLoginLauncher(artifacts, database)
    results = ResultService(database, artifacts)
    result_packages = ResultPackageService(database, artifacts, approvals)

    app = FastAPI(title="GEO Operator V2", version="0.2.0")
    app.include_router(mock_router)
    app.state.services = {
        "database": database,
        "artifacts": artifacts,
        "tenants": tenants,
        "approvals": approvals,
        "discovery": discovery,
        "profiles": profiles,
        "task_packages": task_packages,
        "engine": engine,
        "leases": leases,
        "sessions": sessions,
        "manual_logins": manual_logins,
        "results": results,
        "result_packages": result_packages,
    }

    def require_tenant(tenant_id: str) -> None:
        if not database.one("SELECT id FROM tenants WHERE id=?", (tenant_id,)):
            raise ValueError("Tenant not found")

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
                    "policy": "ALLOWED",
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
    def health() -> dict[str, str]:
        return {
            "status": "ok",
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

    @app.post("/api/tenants/{tenant_id}/profile", status_code=201)
    def save_profile(tenant_id: str, body: ProfileCreate) -> dict[str, Any]:
        try:
            return profiles.save_draft(tenant_id, body.profile)
        except (KeyError, ValueError) as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc

    @app.post("/api/profiles/{profile_id}/export")
    def export_profile(profile_id: str) -> FileResponse:
        try:
            path = profiles.export(profile_id)
            return FileResponse(path, filename="CLIENT_PROFILE.zip")
        except (KeyError, ValueError) as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc

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
                    raise ValueError(
                        f"{execution['platform']} is CALIBRATION_REQUIRED; "
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
            target_url = body.target_url
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
            if target_url:
                await page.goto(target_url, wait_until="domcontentloaded")
                hydration = await plugin.wait_for_calibration_hydration(page)
            else:
                await plugin.open_platform(page)
                hydration = "HOME_PAGE"
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
            return {
                "platform": body.platform,
                "account_id": body.account_id,
                "logged_in": logged_in,
                "url": page.url,
                "origin": origin,
                "hydration": hydration,
                "menu_inspection": menu_inspection,
                "delete_confirmation_inspection": delete_confirmation_inspection,
                "recovery_bound": recovery_bound,
                "privacy": "STRUCTURE_ONLY_NO_TEXT_NO_STORAGE_NO_COOKIES",
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
