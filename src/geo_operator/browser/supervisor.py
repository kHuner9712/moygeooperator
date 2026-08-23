from __future__ import annotations

import asyncio
import uuid

from geo_operator.browser.lease import ExecutionLeaseManager, LeaseUnavailable
from geo_operator.browser.registry import PluginRegistry
from geo_operator.browser.session import BrowserSessionManager
from geo_operator.browser.state_machine import ExecutionStateMachine
from geo_operator.browser.worker import BrowserWorker, WorkerConfig
from geo_operator.core.db import Database
from geo_operator.domain import PauseReason
from geo_operator.results import ResultService
from geo_operator.runtime import RuntimeWorkerRegistry


class WorkerSupervisor:
    def __init__(
        self,
        database: Database,
        sessions: BrowserSessionManager,
        engine: ExecutionStateMachine,
        leases: ExecutionLeaseManager,
        results: ResultService,
        plugins: PluginRegistry,
        config: WorkerConfig | None = None,
    ) -> None:
        self.database = database
        self.sessions = sessions
        self.engine = engine
        self.leases = leases
        self.results = results
        self.plugins = plugins
        self.config = config or WorkerConfig()
        self.worker_id = f"supervisor-{uuid.uuid4().hex}"
        self.runtime = RuntimeWorkerRegistry(database)
        self._runtime_status = "STARTING"

    async def run_once(self) -> bool:
        self.leases.release_expired()
        await self._close_inactive_tenant_sessions()
        execution = self.database.one(
            """SELECT e.* FROM executions e
               JOIN task_packages p ON p.id=e.task_package_id
               JOIN tenants tenant ON tenant.id=e.tenant_id AND tenant.status='ACTIVE'
               JOIN tasks current_task ON current_task.id=e.task_id
               LEFT JOIN execution_leases l ON l.execution_id=e.id
               WHERE p.status='APPROVED'
                 AND l.execution_id IS NULL
                 AND NOT EXISTS (
                   SELECT 1 FROM executions prior_execution
                   JOIN tasks prior_task ON prior_task.id=prior_execution.task_id
                   WHERE prior_execution.task_package_id=e.task_package_id
                     AND prior_task.sequence < current_task.sequence
                     AND prior_execution.state!='COMPLETED'
                 )
                 AND NOT EXISTS (
                   SELECT 1 FROM executions platform_gate
                   WHERE platform_gate.id!=e.id
                     AND platform_gate.tenant_id=e.tenant_id
                     AND platform_gate.platform=e.platform
                     AND platform_gate.account_id=e.account_id
                     AND platform_gate.state='PAUSED'
                     AND platform_gate.pause_reason IN (
                       'CAPTCHA',
                       'LOGIN_EXPIRED',
                       'SECURITY_CHALLENGE',
                       'RATE_LIMITED',
                       'ACCOUNT_RESTRICTED'
                     )
                 )
                 AND (
                   e.state NOT IN ('COMPLETED','FAILED','PAUSED','WAIT_HUMAN_APPROVAL')
                   OR (
                     e.state='PAUSED' AND (
                       SELECT event_type FROM execution_events
                       WHERE execution_id=e.id
                         AND event_type IN (
                           'HUMAN_TAKEOVER_COMPLETED',
                           'RESUMED_AFTER_REVALIDATION',
                           'EXECUTION_PAUSED',
                           'RESUME_REVALIDATION_FAILED'
                         )
                       ORDER BY sequence DESC LIMIT 1
                     )='HUMAN_TAKEOVER_COMPLETED'
                   )
                 )
               ORDER BY e.created_at LIMIT 1"""
        )
        if not execution:
            return False
        self._runtime_status = "BUSY"
        worker = BrowserWorker(
            self.database,
            self.sessions,
            self.engine,
            self.leases,
            self.results,
            self.config,
            worker_id=self.worker_id,
        )
        try:
            plugin = self.plugins.for_execution(execution)
            if not getattr(plugin, "calibration_complete", True):
                self.engine.pause(
                    str(execution["id"]),
                    PauseReason.PAGE_ABNORMAL,
                    details={
                        "calibration_block": "PLUGIN_CALIBRATION_REQUIRED",
                        "platform": execution["platform"],
                        "missing": plugin.calibration_status()["missing"],
                    },
                )
                return True
            if execution["state"] == "PAUSED":
                await worker.resume_after_human(str(execution["id"]), plugin)
            else:
                await worker.run_execution(str(execution["id"]), plugin)
        except LeaseUnavailable:
            return False
        except Exception as exc:  # noqa: BLE001 - browser failures must fail closed
            tenant = self.database.one(
                "SELECT status FROM tenants WHERE id=?", (execution["tenant_id"],)
            )
            if not tenant or tenant["status"] != "ACTIVE":
                return True
            current = self.engine.get(str(execution["id"]))
            if current["state"] == "PAUSED":
                if current["pause_reason"] != PauseReason.OPERATOR_REQUESTED.value:
                    self.engine.record_resume_revalidation_failure(
                        str(execution["id"]),
                        PauseReason.PAGE_ABNORMAL.value,
                        {"error": type(exc).__name__, "message": str(exc)},
                    )
            elif current["state"] not in {"FAILED", "COMPLETED"}:
                self.engine.pause(
                    str(execution["id"]),
                    PauseReason.PAGE_ABNORMAL,
                    details={"error": type(exc).__name__, "message": str(exc)},
                )
        return True

    async def _close_inactive_tenant_sessions(self) -> None:
        tenants = self.database.all("SELECT id FROM tenants WHERE status!='ACTIVE'")
        for tenant in tenants:
            await self.sessions.close_tenant(str(tenant["id"]))

    async def run_forever(self, idle_seconds: float = 1.0) -> None:
        self.runtime.register(
            self.worker_id,
            "BROWSER",
            {"idle_seconds": idle_seconds, "headless": self.config.headless},
        )
        self._runtime_status = "IDLE"
        heartbeat_task = asyncio.create_task(self._heartbeat_runtime())
        try:
            while True:
                if heartbeat_task.done():
                    heartbeat_task.result()
                self._runtime_status = "CHECKING"
                worked = await self.run_once()
                self._runtime_status = "IDLE"
                if not worked:
                    await asyncio.sleep(idle_seconds)
        finally:
            if not heartbeat_task.done():
                heartbeat_task.cancel()
            await asyncio.gather(heartbeat_task, return_exceptions=True)
            try:
                self.runtime.stop(self.worker_id)
            finally:
                await self.sessions.close_all()

    async def _heartbeat_runtime(self) -> None:
        while True:
            self.runtime.heartbeat(self.worker_id, self._runtime_status)
            await asyncio.sleep(2.0)
