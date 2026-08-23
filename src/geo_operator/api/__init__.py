from __future__ import annotations

import re
from typing import Any

from fastapi import Request
from fastapi.responses import JSONResponse

from .app import create_app as _create_app

_RESUME_PATH = re.compile(r"^/api/executions/([^/]+)/(?:continue|resume-request)$")


def create_app(settings: Any = None):
    app = _create_app(settings)

    @app.middleware("http")
    async def release_control_session_before_resume(request: Request, call_next):
        """Release API-owned calibration Chrome before the independent Worker resumes.

        Login checks/calibration run in the control process, while real executions run in the
        independent Browser Worker. Both intentionally reuse the same persistent profile. On
        Windows the control process must close its context before the Worker can acquire that
        profile; otherwise the resume request is recorded but revalidation fails on the profile
        lock and the execution remains paused with stale pause evidence.
        """
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
