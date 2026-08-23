from __future__ import annotations

import json
import re
from typing import Any

from fastapi import Request
from fastapi.responses import FileResponse, JSONResponse

from .app import create_app as _create_app

_RESUME_PATH = re.compile(r"^/api/executions/([^/]+)/(?:continue|resume-request)$")
_EVIDENCE_PATH = re.compile(r"^/api/executions/([^/]+)/pause-evidence$")
_SCREENSHOT_PATH = re.compile(r"^/api/executions/([^/]+)/pause-screenshot$")


def create_app(settings: Any = None):
    app = _create_app(settings)

    def latest_pause_evidence(execution_id: str) -> dict[str, Any] | None:
        database = app.state.services["database"]
        row = database.one(
            """SELECT event_type,payload_json,created_at FROM execution_events
               WHERE execution_id=?
                 AND event_type IN ('EXECUTION_PAUSED','RESUME_REVALIDATION_FAILED')
               ORDER BY sequence DESC LIMIT 1""",
            (execution_id,),
        )
        if not row:
            return None
        try:
            payload = json.loads(str(row["payload_json"]))
        except (TypeError, ValueError):
            payload = {}
        payload["created_at"] = row["created_at"]
        payload["evidence_type"] = row["event_type"]
        return payload

    @app.middleware("http")
    async def resume_and_evidence_guard(request: Request, call_next):
        """Keep browser ownership and resume evidence consistent across API and Worker."""
        evidence_match = _EVIDENCE_PATH.fullmatch(request.url.path)
        if request.method == "GET" and evidence_match:
            evidence = latest_pause_evidence(evidence_match.group(1))
            if not evidence:
                return JSONResponse(status_code=404, content={"detail": "Pause evidence not found"})
            return JSONResponse(content=evidence)

        screenshot_match = _SCREENSHOT_PATH.fullmatch(request.url.path)
        if request.method == "GET" and screenshot_match:
            execution_id = screenshot_match.group(1)
            evidence = latest_pause_evidence(execution_id)
            relative = evidence.get("screenshot_path") if evidence else None
            if not relative:
                return JSONResponse(
                    status_code=404,
                    content={"detail": "Latest resume evidence has no screenshot"},
                )
            engine = app.state.services["engine"]
            artifacts = app.state.services["artifacts"]
            try:
                execution = engine.get(execution_id)
            except KeyError:
                return JSONResponse(status_code=404, content={"detail": "Execution not found"})
            return FileResponse(
                artifacts.resolve(str(execution["tenant_id"]), str(relative)),
                media_type="image/png",
            )

        match = _RESUME_PATH.fullmatch(request.url.path)
        if request.method == "POST" and match:
            engine = app.state.services["engine"]
            sessions = app.state.services["sessions"]
            manual_logins = app.state.services["manual_logins"]
            try:
                execution = engine.get(match.group(1))
            except KeyError:
                execution = None
            if execution and execution["state"] == "PAUSED" and execution["platform"] != "mock":
                try:
                    manual_logins.ensure_closed(
                        str(execution["tenant_id"]),
                        str(execution["platform"]),
                        str(execution["account_id"]),
                    )
                    await sessions.close(
                        str(execution["tenant_id"]),
                        str(execution["platform"]),
                        str(execution["account_id"]),
                    )
                except ValueError:
                    return JSONResponse(
                        status_code=409,
                        content={
                            "detail": "请先关闭正常 Chrome 登录窗口，再点击“我已处理，继续”。"
                        },
                    )
        return await call_next(request)

    return app


__all__ = ["create_app"]
