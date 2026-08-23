import asyncio
import tempfile
import unittest
from pathlib import Path
from unittest.mock import AsyncMock

from geo_operator.browser import ExecutionStateMachine
from geo_operator.browser.lease import ExecutionLeaseManager
from geo_operator.browser.supervisor import WorkerSupervisor
from geo_operator.browser.worker import WorkerConfig
from geo_operator.core.db import Database
from geo_operator.core.storage import ArtifactStore
from geo_operator.results import ResultService
from geo_operator.tenants import TenantService


class SupervisorSessionCleanupTestCase(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.database = Database(root / "operator.sqlite3")
        self.database.initialize()
        self.artifacts = ArtifactStore(root / "data", self.database)
        self.tenants = TenantService(self.database, self.artifacts)

    async def asyncTearDown(self) -> None:
        self.temp.cleanup()

    async def test_heartbeat_closes_deleting_customer_sessions(self) -> None:
        active = self.tenants.create("Active customer")
        deleting = self.tenants.create("Deleting customer")
        self.tenants.begin_delete(str(deleting["id"]), str(deleting["name"]))

        sessions = AsyncMock()
        supervisor = WorkerSupervisor(
            self.database,
            sessions,
            ExecutionStateMachine(self.database),
            ExecutionLeaseManager(self.database),
            ResultService(self.database, self.artifacts),
            plugins=object(),
            config=WorkerConfig(headless=True),
        )
        supervisor.runtime.register(supervisor.worker_id, "BROWSER")

        heartbeat = asyncio.create_task(supervisor._heartbeat_runtime())
        try:
            for _ in range(50):
                if sessions.close_tenant.await_count:
                    break
                await asyncio.sleep(0.01)
        finally:
            heartbeat.cancel()
            await asyncio.gather(heartbeat, return_exceptions=True)

        sessions.close_tenant.assert_awaited_with(str(deleting["id"]))
        called_ids = [call.args[0] for call in sessions.close_tenant.await_args_list]
        self.assertNotIn(str(active["id"]), called_ids)


if __name__ == "__main__":
    unittest.main()
