from __future__ import annotations

import asyncio
import json
import random
import time
import uuid
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, replace
from typing import Any
from urllib.parse import urlsplit

from geo_operator.browser.lease import ExecutionLeaseManager
from geo_operator.browser.plugins.base import (
    PlatformObservation,
    SideEffectNotAttempted,
)
from geo_operator.browser.session import BrowserSessionManager
from geo_operator.browser.state_machine import ExecutionStateMachine
from geo_operator.core.db import Database
from geo_operator.domain import ExecutionState, PauseReason
from geo_operator.results import ResultService

CrashHook = Callable[[str, str], None]


@dataclass(frozen=True, slots=True)
class WorkerConfig:
    poll_interval: float = 0.15
    stable_window: float = 0.8
    response_timeout: float = 180.0
    observation_error_grace: float = 5.0
    delete_confirmation_timeout: float = 10.0
    headless: bool = False
    action_delay_min: float = 0.0
    action_delay_max: float = 0.0

    def __post_init__(self) -> None:
        if self.action_delay_min < 0:
            raise ValueError("Browser action delay minimum cannot be negative")
        if self.action_delay_max < self.action_delay_min:
            raise ValueError("Browser action delay maximum must be at least the minimum")


class BrowserWorker:
    def __init__(
        self,
        database: Database,
        sessions: BrowserSessionManager,
        engine: ExecutionStateMachine,
        leases: ExecutionLeaseManager,
        results: ResultService,
        config: WorkerConfig | None = None,
        worker_id: str | None = None,
        crash_hook: CrashHook | None = None,
    ) -> None:
        self.database = database
        self.sessions = sessions
        self.engine = engine
        self.leases = leases
        self.results = results
        self.config = config or WorkerConfig()
        self.worker_id = worker_id or f"worker-{uuid.uuid4().hex}"
        self.crash_hook = crash_hook

    async def run_execution(self, execution_id: str, plugin: Any) -> dict[str, Any]:
        return await self._run_with_lease(execution_id, lambda: self._drive(execution_id, plugin))

    async def resume_after_human(self, execution_id: str, plugin: Any) -> dict[str, Any]:
        """Revalidate a manually handled page under the same lease before resuming."""

        async def resume() -> dict[str, Any]:
            execution = self.engine.get(execution_id)
            if execution["state"] != ExecutionState.PAUSED.value:
                raise ValueError("Execution is not paused")
            context = await self.sessions.open(
                execution["tenant_id"],
                execution["platform"],
                execution["account_id"],
                headless=self.config.headless,
            )
            page = context.pages[0] if context.pages else await context.new_page()
            self._current_page = page
            self._current_plugin = plugin
            await self._restore_page_from_pause(execution_id, plugin, page)
            validation = await plugin.revalidate(page, execution)
            if not validation.safe:
                reason = validation.pause_reason or PauseReason.PAGE_ABNORMAL.value
                details: dict[str, Any] = {"page_url": page.url}
                try:
                    screenshot = await plugin.screenshot(page)
                    relative = (
                        f"results/screenshots/revalidation-{execution_id}-{uuid.uuid4().hex}.png"
                    )
                    self.results.artifacts.atomic_write(
                        str(execution["tenant_id"]), relative, screenshot
                    )
                    details["screenshot_path"] = relative
                except Exception as exc:  # noqa: BLE001 - evidence failure must stay paused
                    details["screenshot_error"] = type(exc).__name__
                return self.engine.record_resume_revalidation_failure(
                    execution_id, str(reason), details
                )
            self.engine.resume(execution_id, revalidated=True)
            return await self._drive(execution_id, plugin, restore_page=False)

        return await self._run_with_lease(execution_id, resume)

    async def _run_with_lease(
        self, execution_id: str, operation: Callable[[], Awaitable[dict[str, Any]]]
    ) -> dict[str, Any]:
        """Keep the execution and Session leases alive during long browser awaits."""
        self.leases.acquire(execution_id, self.worker_id)
        operation_task = asyncio.create_task(operation())
        heartbeat_task = asyncio.create_task(self._heartbeat_lease(execution_id))
        try:
            done, _ = await asyncio.wait(
                {operation_task, heartbeat_task}, return_when=asyncio.FIRST_COMPLETED
            )
            if heartbeat_task in done:
                error = heartbeat_task.exception()
                if error is None:
                    raise RuntimeError("Execution lease heartbeat stopped unexpectedly")
                raise error
            return await operation_task
        finally:
            for task in (operation_task, heartbeat_task):
                if not task.done():
                    task.cancel()
            await asyncio.gather(operation_task, heartbeat_task, return_exceptions=True)
            self.leases.release(execution_id, self.worker_id)

    async def _heartbeat_lease(self, execution_id: str) -> None:
        interval = max(0.1, self.leases.ttl_seconds / 3)
        while True:
            await asyncio.sleep(interval)
            self.leases.heartbeat(execution_id, self.worker_id)

    async def _drive(
        self, execution_id: str, plugin: Any, *, restore_page: bool = True
    ) -> dict[str, Any]:
        execution = self.engine.get(execution_id)
        context = await self.sessions.open(
            execution["tenant_id"],
            execution["platform"],
            execution["account_id"],
            headless=self.config.headless,
        )
        page = context.pages[0] if context.pages else await context.new_page()
        self._current_page = page
        self._current_plugin = plugin
        if restore_page:
            await self._restore_page_from_pause(execution_id, plugin, page)

        for _ in range(40):
            self.leases.heartbeat(execution_id, self.worker_id)
            execution = self.engine.get(execution_id)
            state = ExecutionState(execution["state"])
            if state in {ExecutionState.COMPLETED, ExecutionState.FAILED, ExecutionState.PAUSED}:
                return execution

            task = self._task(execution)
            str(task["prompt"])

            if state == ExecutionState.CREATED:
                self.engine.transition(execution_id, ExecutionState.WAIT_LOGIN)
                continue

            if state == ExecutionState.WAIT_LOGIN:
                await plugin.open_platform(page)
                reason = await plugin.detect_human_intervention(page)
                if reason and reason != PauseReason.LOGIN_EXPIRED.value:
                    return await self._pause(execution_id, reason, page.url)
                if not await plugin.detect_login(page):
                    return await self._pause(
                        execution_id, PauseReason.LOGIN_EXPIRED.value, page.url
                    )
                self.engine.transition(execution_id, ExecutionState.READY)
                continue

            if state == ExecutionState.READY:
                approval = self._approval(execution)
                self.engine.wait_for_approval(
                    execution_id, str(approval["id"]), ExecutionState.OPEN_PLATFORM
                )
                if approval["status"] == "APPROVED":
                    self.engine.resolve_approval(execution_id, True)
                    continue
                if approval["status"] == "REJECTED":
                    return self.engine.resolve_approval(execution_id, False)
                return self.engine.get(execution_id)

            if state == ExecutionState.WAIT_HUMAN_APPROVAL:
                approval = self._approval(execution)
                if approval["status"] == "PENDING":
                    return execution
                return self.engine.resolve_approval(execution_id, approval["status"] == "APPROVED")

            reason = await plugin.detect_human_intervention(page)
            if reason:
                return await self._pause(execution_id, reason, page.url)

            if state == ExecutionState.OPEN_PLATFORM:
                await plugin.open_platform(page)
                reason = await plugin.detect_human_intervention(page)
                if reason:
                    return await self._pause(execution_id, reason, page.url)
                self.engine.transition(execution_id, ExecutionState.SEND_QUERY)
                continue

            if state == ExecutionState.SEND_QUERY:
                result = await self._send_idempotently(execution, task, plugin, page)
                if result is not None:
                    return result
                self.engine.transition(execution_id, ExecutionState.WAIT_RESPONSE)
                continue

            if state == ExecutionState.WAIT_RESPONSE:
                observation = await self._wait_for_complete(execution, plugin, page)
                if observation is None:
                    return self.engine.get(execution_id)
                self.engine.transition(
                    execution_id,
                    ExecutionState.VERIFY_COMPLETE,
                    {"completion_signals": self._signals(observation)},
                )
                continue

            if state == ExecutionState.VERIFY_COMPLETE:
                observation = await self._wait_for_complete(execution, plugin, page)
                if observation is None:
                    return self.engine.get(execution_id)
                try:
                    screenshot = await plugin.screenshot(page)
                except Exception as exc:  # noqa: BLE001 - final screenshot is mandatory
                    return await self._pause(
                        execution_id,
                        PauseReason.PAGE_ABNORMAL.value,
                        page.url,
                        {"result_screenshot_error": type(exc).__name__},
                    )
                self._crash("before_result_save", execution_id)
                self.results.save_final(
                    execution_id,
                    observation.response_text,
                    self._signals(observation),
                    screenshot,
                    {"page_url": page.url, "response_locator": plugin.response_locator},
                )
                self._crash("after_result_save", execution_id)
                continue

            if state == ExecutionState.SAVE_RESULT:
                if not self.results.has_saved_result(execution_id):
                    return await self._pause(
                        execution_id, PauseReason.COMPLETION_UNCERTAIN.value, page.url
                    )
                self.engine.transition(execution_id, ExecutionState.DELETE_CHAT)
                continue

            if state == ExecutionState.DELETE_CHAT:
                deletion_ready = getattr(plugin, "deletion_calibration_complete", True)
                if not deletion_ready:
                    return await self._pause(
                        execution_id,
                        PauseReason.PAGE_ABNORMAL.value,
                        page.url,
                        {"calibration_stage": "DELETE_CHAT"},
                    )
                result = await self._delete_idempotently(execution, plugin, page)
                if result is not None:
                    return result
                self.engine.transition(execution_id, ExecutionState.VERIFY_DELETE)
                continue

            if state == ExecutionState.VERIFY_DELETE:
                if not await self._wait_for_delete_confirmation(plugin, page):
                    return await self._pause(
                        execution_id, PauseReason.COMPLETION_UNCERTAIN.value, page.url
                    )
                self.engine.transition(execution_id, ExecutionState.NEXT_TASK)
                continue

            if state == ExecutionState.NEXT_TASK:
                with self.database.transaction() as connection:
                    connection.execute(
                        "UPDATE tasks SET status='COMPLETED' WHERE id=?", (execution["task_id"],)
                    )
                self.engine.transition(execution_id, ExecutionState.COMPLETED)
                continue

        return await self._pause(execution_id, PauseReason.COMPLETION_UNCERTAIN.value, page.url)

    async def _pace_before_query(self, execution_id: str) -> None:
        if self.config.action_delay_max <= 0:
            return
        delay = random.uniform(self.config.action_delay_min, self.config.action_delay_max)
        if delay <= 0:
            return
        self.engine.record_operation_pacing(execution_id, delay)
        await asyncio.sleep(delay)

    async def _send_idempotently(
        self, execution: dict[str, Any], task: dict[str, Any], plugin: Any, page: Any
    ) -> dict[str, Any] | None:
        execution_id = str(execution["id"])
        key = str(task["idempotency_key"])
        effect = self.database.one(
            """SELECT * FROM side_effects WHERE execution_id=?
               AND effect_type='QUERY_SEND' AND idempotency_key=?""",
            (execution_id, key),
        )
        if effect:
            if effect["status"] == "CONFIRMED":
                return None
            try:
                observation = json.loads(str(effect["observation_json"]))
            except (TypeError, ValueError):
                observation = {}
            if (
                observation.get("action_attempted") is False
                or observation.get("delivery_failed") is True
            ):
                self.engine.mark_effect_retry_started(str(effect["id"]))
                return await self._perform_query_send(execution, task, effect, plugin, page)
            try:
                (
                    query_exists,
                    intervention,
                    delivery_failed,
                ) = await self._wait_for_query_confirmation(plugin, page, str(task["prompt"]))
            except Exception as exc:  # noqa: BLE001 - uncertain send must pause
                return await self._pause(
                    execution_id,
                    PauseReason.PAGE_ABNORMAL.value,
                    page.url,
                    {
                        "calibration_block": type(exc).__name__,
                        "message": str(exc),
                        "query_effect_status": "INTENT",
                    },
                )
            if delivery_failed:
                self.engine.mark_effect_delivery_failed(
                    str(effect["id"]), {"platform": str(execution["platform"])}
                )
                return await self._pause(
                    execution_id,
                    intervention or PauseReason.PAGE_ABNORMAL.value,
                    page.url,
                    {
                        "query_effect_status": "INTENT",
                        "action_attempted": True,
                        "delivery_failed": True,
                    },
                )
            if intervention:
                return await self._pause(execution_id, intervention, page.url)

            if query_exists:
                self.engine.confirm_effect(str(effect["id"]), {"query_exists": True})
                return None
            return await self._pause(execution_id, PauseReason.COMPLETION_UNCERTAIN.value, page.url)

        effect = self.engine.record_effect_intent(execution_id, "QUERY_SEND", key)
        return await self._perform_query_send(execution, task, effect, plugin, page)

    async def _perform_query_send(
        self,
        execution: dict[str, Any],
        task: dict[str, Any],
        effect: dict[str, Any],
        plugin: Any,
        page: Any,
    ) -> dict[str, Any] | None:
        execution_id = str(execution["id"])
        await self._pace_before_query(execution_id)
        try:
            await plugin.send_query(page, str(task["prompt"]))
        except SideEffectNotAttempted as exc:
            root = exc.__cause__ or exc
            self.engine.mark_effect_not_attempted(
                str(effect["id"]),
                {"error": type(root).__name__, "message": str(root)},
            )
            return await self._pause(
                execution_id,
                PauseReason.PAGE_ABNORMAL.value,
                page.url,
                {
                    "error": type(root).__name__,
                    "message": str(root),
                    "query_effect_status": "INTENT",
                    "action_attempted": False,
                },
            )

        await self._bind_current_conversation_url(execution_id, plugin, page)
        self._crash("after_query_send", execution_id)
        try:
            query_exists, intervention, delivery_failed = await self._wait_for_query_confirmation(
                plugin, page, str(task["prompt"])
            )
        except Exception as exc:  # noqa: BLE001 - sent query must not be repeated
            return await self._pause(
                execution_id,
                PauseReason.PAGE_ABNORMAL.value,
                page.url,
                {
                    "calibration_block": type(exc).__name__,
                    "message": str(exc),
                    "query_effect_status": "INTENT",
                },
            )
        if delivery_failed:
            self.engine.mark_effect_delivery_failed(
                str(effect["id"]), {"platform": str(execution["platform"])}
            )
            return await self._pause(
                execution_id,
                intervention or PauseReason.PAGE_ABNORMAL.value,
                page.url,
                {
                    "query_effect_status": "INTENT",
                    "action_attempted": True,
                    "delivery_failed": True,
                },
            )
        if intervention:
            return await self._pause(execution_id, intervention, page.url)
        if not query_exists:
            return await self._pause(execution_id, PauseReason.COMPLETION_UNCERTAIN.value, page.url)
        self.engine.confirm_effect(str(effect["id"]), {"query_exists": True})
        return None

    async def _bind_current_conversation_url(
        self, execution_id: str, plugin: Any, page: Any
    ) -> None:
        """Persist a routed conversation URL before query confirmation can be interrupted."""
        validator = getattr(plugin, "is_conversation_url", None)
        if not callable(validator):
            return
        started = time.monotonic()
        timeout = min(self.config.response_timeout, 5.0)
        while time.monotonic() - started < timeout:
            if validator(page.url):
                self.engine.bind_recovery_url(execution_id, page.url)
                return
            await asyncio.sleep(self.config.poll_interval)

    async def _wait_for_query_confirmation(
        self, plugin: Any, page: Any, prompt: str
    ) -> tuple[bool, str | None, bool]:
        """Confirm delivery, while preserving explicit platform rejection as retryable evidence."""
        started = time.monotonic()
        timeout = min(self.config.response_timeout, 15.0)
        last_error: Exception | None = None
        while time.monotonic() - started < timeout:
            reason = await plugin.detect_human_intervention(page)
            try:
                query_exists = await plugin.query_exists(page, prompt)
                delivery_check = getattr(plugin, "query_delivery_failed", None)
                delivery_failed = bool(
                    query_exists and callable(delivery_check) and await delivery_check(page, prompt)
                )
                if delivery_failed:
                    return False, str(reason) if reason else None, True
                if reason:
                    return False, str(reason), False
                if query_exists:
                    return True, None, False
                last_error = None
            except Exception as exc:  # noqa: BLE001 - retry transient routed DOM states
                last_error = exc
                if reason:
                    return False, str(reason), False
            await asyncio.sleep(self.config.poll_interval)
        if last_error is not None:
            raise last_error
        return False, None, False

    async def _wait_for_complete(
        self, execution: dict[str, Any], plugin: Any, page: Any
    ) -> PlatformObservation | None:
        started = time.monotonic()
        last_text = ""
        changed_at = started
        observation_error_started: float | None = None
        while time.monotonic() - started < self.config.response_timeout:
            self.leases.heartbeat(str(execution["id"]), self.worker_id)
            reason = await plugin.detect_human_intervention(page)
            if reason:
                await self._pause(str(execution["id"]), reason, page.url)
                return None
            try:
                observation = await plugin.observe_response(page)
            except Exception as exc:  # noqa: BLE001 - tolerate transient streaming DOM swaps
                now = time.monotonic()
                if observation_error_started is None:
                    observation_error_started = now
                if now - observation_error_started >= self.config.observation_error_grace:
                    await self._pause(
                        str(execution["id"]),
                        PauseReason.PAGE_ABNORMAL.value,
                        page.url,
                        {"observation_error": type(exc).__name__},
                    )
                    return None
                await asyncio.sleep(self.config.poll_interval)
                continue
            observation_error_started = None
            if observation.response_text != last_text:
                last_text = observation.response_text
                changed_at = time.monotonic()
                if last_text:
                    screenshot = None
                    try:
                        screenshot = await plugin.screenshot(page)
                    except Exception:  # noqa: BLE001 - text checkpoint remains authoritative
                        screenshot = None
                    self.results.checkpoint(
                        str(execution["id"]),
                        last_text,
                        page.url,
                        plugin.response_locator,
                        screenshot,
                    )
            stable = bool(last_text) and time.monotonic() - changed_at >= self.config.stable_window
            observation = replace(observation, response_text_stable=stable)
            if observation.complete:
                return observation
            await asyncio.sleep(self.config.poll_interval)
        await self._pause(str(execution["id"]), PauseReason.COMPLETION_UNCERTAIN.value, page.url)
        return None

    async def _wait_for_delete_confirmation(self, plugin: Any, page: Any) -> bool:
        """Wait boundedly for both DOM absence and a usable signed-in page."""
        started = time.monotonic()
        while time.monotonic() - started < self.config.delete_confirmation_timeout:
            if await plugin.verify_chat_deleted(page) and await plugin.detect_login(page):
                return True
            await asyncio.sleep(self.config.poll_interval)
        return False

    async def _delete_idempotently(
        self, execution: dict[str, Any], plugin: Any, page: Any
    ) -> dict[str, Any] | None:
        execution_id = str(execution["id"])
        result = self.results.get_for_execution(execution_id)
        key = str(result["id"])
        effect = self.database.one(
            """SELECT * FROM side_effects WHERE execution_id=?
               AND effect_type='CHAT_DELETE' AND idempotency_key=?""",
            (execution_id, key),
        )
        if effect:
            if effect["status"] == "CONFIRMED":
                return None
            if await self._wait_for_delete_confirmation(plugin, page):
                self.engine.confirm_effect(str(effect["id"]), {"chat_absent": True})
                return None
            return await self._pause(execution_id, PauseReason.COMPLETION_UNCERTAIN.value, page.url)
        effect = self.engine.record_effect_intent(execution_id, "CHAT_DELETE", key)
        self._crash("before_chat_delete", execution_id)
        await plugin.delete_chat(page)
        if not await self._wait_for_delete_confirmation(plugin, page):
            return await self._pause(execution_id, PauseReason.COMPLETION_UNCERTAIN.value, page.url)
        self.engine.confirm_effect(str(effect["id"]), {"chat_absent": True})
        return None

    async def _restore_page_from_pause(self, execution_id: str, plugin: Any, page: Any) -> None:
        pending_delete = self.database.one(
            """SELECT id FROM side_effects
               WHERE execution_id=? AND effect_type='CHAT_DELETE' AND status='INTENT'
               ORDER BY created_at DESC LIMIT 1""",
            (execution_id,),
        )
        pending_query = self.database.one(
            """SELECT * FROM side_effects
               WHERE execution_id=? AND effect_type='QUERY_SEND' AND status IN ('INTENT','CONFIRMED')
               ORDER BY created_at DESC LIMIT 1""",
            (execution_id,),
        )
        query_retryable = False
        if pending_query and pending_query["status"] == "INTENT":
            try:
                query_observation = json.loads(str(pending_query["observation_json"]))
            except (TypeError, ValueError):
                query_observation = {}
            query_retryable = (
                query_observation.get("action_attempted") is False
                or query_observation.get("delivery_failed") is True
            )
        home_url = getattr(plugin, "home_url", None)
        if not isinstance(home_url, str) or not home_url:
            return
        execution = self.engine.get(execution_id)
        pre_send_states = {
            ExecutionState.WAIT_LOGIN.value,
            ExecutionState.READY.value,
            ExecutionState.OPEN_PLATFORM.value,
            ExecutionState.SEND_QUERY.value,
        }
        if (
            (not pending_query or query_retryable)
            and not pending_delete
            and execution.get("resume_state") in pre_send_states
        ):
            await page.goto(home_url, wait_until="domcontentloaded")
            await plugin.open_platform(page)
            for _ in range(120):
                if await plugin.detect_human_intervention(page) or await plugin.detect_login(page):
                    return
                await asyncio.sleep(0.25)
            raise RuntimeError("Signed-in pre-send page did not become ready")

        rows = self.database.all(
            """SELECT payload_json FROM execution_events
               WHERE execution_id=?
                 AND event_type IN ('SESSION_RECOVERY_URL_BOUND','EXECUTION_PAUSED')
               ORDER BY sequence DESC""",
            (execution_id,),
        )
        if not rows:
            recover = getattr(plugin, "recover_pending_query", None)
            if pending_query and callable(recover):
                task = self._task(execution)
                recovered = await recover(page, str(task["prompt"]))
                if recovered:
                    self.engine.bind_recovery_url(execution_id, recovered)
                    return
                raise RuntimeError("Pending query was not found in recent conversations")
            return
        home = urlsplit(home_url)
        for row in rows:
            try:
                payload = json.loads(str(row["payload_json"]))
            except (TypeError, ValueError):
                continue
            candidate = payload.get("page_url")
            if not isinstance(candidate, str):
                continue
            target = urlsplit(candidate)
            if (
                target.scheme != "https"
                or target.netloc != home.netloc
                or target.username
                or target.password
            ):
                continue
            if page.url != candidate:
                await page.goto(candidate, wait_until="domcontentloaded")
            is_home_url = getattr(plugin, "is_home_url", None)
            if pending_delete and callable(is_home_url) and is_home_url(page.url):
                # A confirmed delete redirects to the platform's signed-in home page.
                # The DELETE_CHAT state independently verifies DOM absence before confirmation.
                return

            wait_for_hydration = getattr(plugin, "wait_for_calibration_hydration", None)
            if callable(wait_for_hydration):
                hydration = await wait_for_hydration(page)
                if hydration != "CONVERSATION_CONTENT":
                    if pending_delete and await self._wait_for_delete_confirmation(plugin, page):
                        return
                    absence_check = getattr(plugin, "deletion_absence_confirmed", None)
                    if (
                        pending_delete
                        and callable(absence_check)
                        and await absence_check(page, candidate)
                    ):
                        return
                    history_check = getattr(plugin, "conversation_in_recent_history", None)
                    if (
                        pending_delete
                        and callable(history_check)
                        and not await history_check(page, candidate)
                    ):
                        return
                    recover = getattr(plugin, "recover_pending_query", None)
                    if pending_query and callable(recover):
                        execution = self.engine.get(execution_id)
                        task = self._task(execution)
                        recovered = await recover(page, str(task["prompt"]))
                        if recovered:
                            self.engine.bind_recovery_url(execution_id, recovered)
                            return
                    raise RuntimeError(f"Saved {plugin.name} conversation did not hydrate")
            if pending_query:
                task = self._task(execution)
                try:
                    query_matches = await plugin.query_exists(page, str(task["prompt"]))
                except Exception:  # noqa: BLE001 - invalid candidate must use bounded recovery
                    query_matches = False
                if not query_matches:
                    recover = getattr(plugin, "recover_pending_query", None)
                    if callable(recover):
                        recovered = await recover(page, str(task["prompt"]))
                        if recovered:
                            self.engine.bind_recovery_url(execution_id, recovered)
                            return
                    raise RuntimeError(
                        f"Saved {plugin.name} conversation does not contain the pending query"
                    )
            return
        raise RuntimeError("No safe same-origin pause URL is available")

    def _approval(self, execution: dict[str, Any]) -> dict[str, Any]:
        row = self.database.one(
            """SELECT a.* FROM approvals a
               JOIN task_packages p ON p.approval_id=a.id
               WHERE p.id=?""",
            (execution["task_package_id"],),
        )
        if not row:
            raise RuntimeError("TASK_EXECUTION approval is missing")
        return row

    def _task(self, execution: dict[str, Any]) -> dict[str, Any]:
        row = self.database.one("SELECT * FROM tasks WHERE id=?", (execution["task_id"],))
        if not row:
            raise RuntimeError("Execution task is missing")
        row["metadata"] = json.loads(str(row["metadata_json"]))
        return row

    async def _pause(
        self,
        execution_id: str,
        reason: str,
        page_url: str,
        extra_details: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        try:
            pause_reason = PauseReason(reason)
        except ValueError:
            pause_reason = PauseReason.PAGE_ABNORMAL
        execution = self.engine.get(execution_id)
        details: dict[str, Any] = {"page_url": page_url, **(extra_details or {})}
        try:
            screenshot = await self._current_plugin.screenshot(self._current_page)
            relative = f"results/screenshots/pause-{execution_id}-{uuid.uuid4().hex}.png"
            self.results.artifacts.atomic_write(execution["tenant_id"], relative, screenshot)
            details["screenshot_path"] = relative
        except Exception as exc:  # noqa: BLE001 - pause must survive screenshot failure
            details["screenshot_error"] = type(exc).__name__
        snapshotter = getattr(self._current_plugin, "structural_snapshot", None)
        if callable(snapshotter):
            try:
                structure = await asyncio.wait_for(snapshotter(self._current_page), timeout=10)
                relative = f"results/calibration/pause-{execution_id}-{uuid.uuid4().hex}.json"
                self.results.artifacts.atomic_write(
                    execution["tenant_id"],
                    relative,
                    json.dumps(structure, ensure_ascii=False, indent=2).encode("utf-8"),
                )
                details["structure_path"] = relative
                details["structure_privacy"] = "NO_NODE_TEXT_NO_STORAGE_NO_COOKIES"
            except Exception as exc:  # noqa: BLE001 - pause remains authoritative
                details["structure_error"] = type(exc).__name__
        current = ExecutionState(execution["state"])
        return self.engine.pause(execution_id, pause_reason, current, details)

    @staticmethod
    def _signals(observation: PlatformObservation) -> dict[str, bool]:
        return {
            "streaming_indicator_absent": observation.streaming_indicator_absent,
            "stop_control_absent": observation.stop_control_absent,
            "input_ready": observation.input_ready,
            "response_text_stable": observation.response_text_stable,
            "final_response_element_present": observation.final_response_element_present,
            "platform_error_absent": observation.platform_error_absent,
        }

    def _crash(self, point: str, execution_id: str) -> None:
        if self.crash_hook:
            self.crash_hook(point, execution_id)
