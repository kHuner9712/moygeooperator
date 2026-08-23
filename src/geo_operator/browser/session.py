from __future__ import annotations

import ctypes
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
        pid_path = profile / "manual-login.pid"
        persisted_pid = self._read_pid(pid_path)
        if persisted_pid is not None and self._pid_is_running(persisted_pid):
            self._record(tenant_id, platform, account_id, "MANUAL_LOGIN_OPEN", profile_relative)
            return
        pid_path.unlink(missing_ok=True)
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
        self.artifacts.atomic_write(
            tenant_id, f"{profile_relative}/manual-login.pid", str(process.pid).encode()
        )
        self._record(tenant_id, platform, account_id, "MANUAL_LOGIN_OPEN", profile_relative)

    def ensure_closed(self, tenant_id: str, platform: str, account_id: str) -> None:
        BrowserSessionManager.validate_identity(platform, account_id)
        key = (tenant_id, platform, account_id)
        process = self._open.get(key)
        profile_relative = f"sessions/{platform}/{account_id}"
        pid_path = self.artifacts.resolve(tenant_id, f"{profile_relative}/manual-login.pid")
        persisted_pid = self._read_pid(pid_path)
        if (process and process.poll() is None) or (
            persisted_pid is not None and self._pid_is_running(persisted_pid)
        ):
            raise ValueError("Close the manual system Chrome window before calibration or release")
        self._open.pop(key, None)
        pid_path.unlink(missing_ok=True)
        self._record(
            tenant_id,
            platform,
            account_id,
            "MANUAL_LOGIN_CLOSED",
            f"sessions/{platform}/{account_id}",
        )

    def ensure_tenant_closed(self, tenant_id: str) -> None:
        for key, process in tuple(self._open.items()):
            if key[0] != tenant_id:
                continue
            if process.poll() is None:
                raise ValueError(
                    "Close all manual login Chrome windows for this customer before deletion"
                )
            self._open.pop(key, None)

        sessions_root = self.artifacts.tenant_root(tenant_id) / "sessions"
        if not sessions_root.exists():
            return
        for pid_path in sessions_root.rglob("manual-login.pid"):
            persisted_pid = self._read_pid(pid_path)
            if persisted_pid is not None and self._pid_is_running(persisted_pid):
                raise ValueError(
                    "Close all manual login Chrome windows for this customer before deletion"
                )
            pid_path.unlink(missing_ok=True)

    @staticmethod
    def _read_pid(path: Path) -> int | None:
        try:
            value = int(path.read_text(encoding="ascii").strip())
            return value if value > 0 else None
        except (FileNotFoundError, OSError, ValueError):
            return None

    @staticmethod
    def _pid_is_running(pid: int) -> bool:
        if os.name == "nt":
            process_query_limited_information = 0x1000
            still_active = 259
            handle = ctypes.windll.kernel32.OpenProcess(
                process_query_limited_information, False, pid
            )
            if not handle:
                return False
            try:
                exit_code = ctypes.c_ulong()
                return bool(
                    ctypes.windll.kernel32.GetExitCodeProcess(handle, ctypes.byref(exit_code))
                    and exit_code.value == still_active
                )
            finally:
                ctypes.windll.kernel32.CloseHandle(handle)
        try:
            os.kill(pid, 0)
        except (OSError, ProcessLookupError):
            return False
        return True

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
        managed = self._open.get(key)
        if managed:
            try:
                # The operator may close a headed Worker Chrome window manually. Playwright can
                # leave the BrowserContext object in our process dictionary until the next
                # protocol operation, so never trust dictionary membership as a liveness check.
                # cookies() is a side-effect-free protocol round-trip; its result is discarded.
                await managed.context.cookies()
                return managed.context
            except Exception as exc:
                if not self._is_closed_context_error(exc):
                    raise
                await self._discard_stale(key, managed)
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

    @staticmethod
    def _is_closed_context_error(exc: Exception) -> bool:
        text = str(exc).lower()
        return any(
            marker in text
            for marker in (
                "target page, context or browser has been closed",
                "browser has been closed",
                "context has been closed",
                "connection closed",
                "target closed",
            )
        )

    async def _discard_stale(
        self, key: tuple[str, str, str], managed: ManagedBrowser
    ) -> None:
        self._open.pop(key, None)
        try:
            await managed.context.close()
        except Exception:
            pass
        try:
            await managed.playwright.stop()
        except Exception:
            pass
        if self.database:
            tenant_id, platform, account_id = key
            with self.database.transaction() as connection:
                connection.execute(
                    """UPDATE browser_sessions SET status='CLOSED',updated_at=?
                       WHERE tenant_id=? AND platform=? AND account_id=?""",
                    (utc_now(), tenant_id, platform, account_id),
                )

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
                if not self._is_closed_context_error(exc):
                    raise
            try:
                await managed.playwright.stop()
            except Exception as exc:
                if "connection closed" not in str(exc).lower():
                    raise
        if self.database:
            with self.database.transaction() as connection:
                connection.execute(
                    """UPDATE browser_sessions SET status='CLOSED',updated_at=?
                       WHERE tenant_id=? AND platform=? AND account_id=?""",
                    (utc_now(), tenant_id, platform, account_id),
                )

    async def close_tenant(self, tenant_id: str) -> None:
        for current_tenant, platform, account_id in tuple(self._open):
            if current_tenant == tenant_id:
                await self.close(current_tenant, platform, account_id)

    async def close_all(self) -> None:
        for tenant_id, platform, account_id in tuple(self._open):
            await self.close(tenant_id, platform, account_id)
