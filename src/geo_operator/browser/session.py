from __future__ import annotations

import os
import re
import shutil
import subprocess
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from geo_operator.core.db import Database
from geo_operator.core.storage import ArtifactStore
from geo_operator.core.time import utc_now
from geo_operator.platforms import canonical_platform

SESSION_PART = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$")


@dataclass(slots=True)
class ManagedBrowser:
    playwright: Any
    context: Any


def system_chrome_path() -> Path:
    """Locate stable system Chrome; never substitute the Playwright test browser for login."""
    candidates: list[Path] = []
    for name in ("chrome", "google-chrome", "google-chrome-stable"):
        resolved = shutil.which(name)
        if resolved:
            candidates.append(Path(resolved))
    if os.name == "nt":
        for variable in ("ProgramFiles", "ProgramFiles(x86)", "LOCALAPPDATA"):
            root = os.environ.get(variable)
            if root:
                candidates.append(Path(root) / "Google" / "Chrome" / "Application" / "chrome.exe")
    for candidate in candidates:
        if candidate.is_file():
            return candidate.resolve()
    raise RuntimeError("System Google Chrome is required for manual login but was not found")


class ManualLoginLauncher:
    """Launch normal system Chrome with no Playwright connection or automation flags."""

    def __init__(self, artifacts: ArtifactStore, database: Database | None = None) -> None:
        self.artifacts = artifacts
        self.database = database
        self._open: dict[tuple[str, str, str], subprocess.Popen[bytes]] = {}

    def open(self, tenant_id: str, platform: str, account_id: str, url: str) -> None:
        BrowserSessionManager.validate_identity(platform, account_id)
        key = (tenant_id, platform, account_id)
        existing = self._open.get(key)
        if existing and existing.poll() is None:
            return
        profile_relative = f"sessions/{platform}/{account_id}"
        profile = self.artifacts.resolve(tenant_id, profile_relative)
        profile.mkdir(parents=True, exist_ok=True)
        creationflags = subprocess.CREATE_NEW_PROCESS_GROUP if os.name == "nt" else 0
        process = subprocess.Popen(
            [
                str(system_chrome_path()),
                f"--user-data-dir={profile}",
                "--profile-directory=Default",
                "--no-first-run",
                "--no-default-browser-check",
                "--disable-background-mode",
                "--new-window",
                url,
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            creationflags=creationflags,
        )
        self._open[key] = process
        self._record(tenant_id, platform, account_id, "MANUAL_LOGIN_OPEN", profile_relative)

    def ensure_closed(self, tenant_id: str, platform: str, account_id: str) -> None:
        BrowserSessionManager.validate_identity(platform, account_id)
        key = (tenant_id, platform, account_id)
        process = self._open.get(key)
        if process and process.poll() is None:
            raise ValueError("Close the manual system Chrome window before calibration or release")
        self._open.pop(key, None)
        self._record(
            tenant_id,
            platform,
            account_id,
            "MANUAL_LOGIN_CLOSED",
            f"sessions/{platform}/{account_id}",
        )

    def _record(
        self, tenant_id: str, platform: str, account_id: str, status: str, profile: str
    ) -> None:
        if not self.database:
            return
        with self.database.transaction() as connection:
            connection.execute(
                """INSERT INTO browser_sessions(
                   id,tenant_id,platform,account_id,status,profile_path,updated_at)
                   VALUES (?,?,?,?,?,?,?)
                   ON CONFLICT(tenant_id,platform,account_id)
                   DO UPDATE SET status=excluded.status,updated_at=excluded.updated_at""",
                (uuid.uuid4().hex, tenant_id, platform, account_id, status, profile, utc_now()),
            )


class BrowserSessionManager:
    """Persistent Worker sessions; headed production runs use installed system Chrome."""

    def __init__(
        self,
        artifacts: ArtifactStore,
        database: Database | None = None,
        browser_channel: str | None = None,
    ) -> None:
        self.artifacts = artifacts
        self.database = database
        self.browser_channel = browser_channel
        self._open: dict[tuple[str, str, str], ManagedBrowser] = {}

    async def open(
        self, tenant_id: str, platform: str, account_id: str, *, headless: bool = False
    ) -> Any:
        self.validate_identity(platform, account_id)
        key = (tenant_id, platform, account_id)
        if key in self._open:
            return self._open[key].context
        from playwright.async_api import async_playwright

        profile_relative = f"sessions/{platform}/{account_id}"
        profile = self.artifacts.resolve(tenant_id, profile_relative)
        profile.mkdir(parents=True, exist_ok=True)
        playwright = await async_playwright().start()
        launch_options = self._launch_options(profile, headless)
        try:
            context = await playwright.chromium.launch_persistent_context(**launch_options)
        except Exception:
            await playwright.stop()
            raise
        self._open[key] = ManagedBrowser(playwright, context)
        if self.database:
            with self.database.transaction() as connection:
                connection.execute(
                    """INSERT INTO browser_sessions(
                       id,tenant_id,platform,account_id,status,profile_path,updated_at)
                       VALUES (?,?,?,?,?,?,?)
                       ON CONFLICT(tenant_id,platform,account_id)
                       DO UPDATE SET status=excluded.status,updated_at=excluded.updated_at""",
                    (
                        uuid.uuid4().hex,
                        tenant_id,
                        platform,
                        account_id,
                        "OPEN",
                        profile_relative,
                        utc_now(),
                    ),
                )
        return context

    def _launch_options(self, profile: Path, headless: bool) -> dict[str, Any]:
        options: dict[str, Any] = {
            "user_data_dir": str(profile),
            "headless": headless,
            "chromium_sandbox": True,
        }
        if self.browser_channel and not headless:
            options["channel"] = self.browser_channel
        return options

    @staticmethod
    def validate_identity(platform: str, account_id: str) -> None:
        canonical = canonical_platform(platform)
        if platform != canonical or not SESSION_PART.fullmatch(platform):
            raise ValueError(f"Session platform must use canonical id: {canonical}")
        if not SESSION_PART.fullmatch(account_id):
            raise ValueError("Invalid session account_id")

    async def close(self, tenant_id: str, platform: str, account_id: str) -> None:
        managed = self._open.pop((tenant_id, platform, account_id), None)
        if managed:
            try:
                await managed.context.close()
            except Exception as exc:
                if "Connection closed" not in str(exc):
                    raise
            try:
                await managed.playwright.stop()
            except Exception as exc:
                if "Connection closed" not in str(exc):
                    raise
        if self.database:
            with self.database.transaction() as connection:
                connection.execute(
                    """UPDATE browser_sessions SET status='CLOSED',updated_at=?
                       WHERE tenant_id=? AND platform=? AND account_id=?""",
                    (utc_now(), tenant_id, platform, account_id),
                )

    async def close_all(self) -> None:
        for tenant_id, platform, account_id in tuple(self._open):
            await self.close(tenant_id, platform, account_id)