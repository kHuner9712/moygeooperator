import asyncio
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from geo_operator.browser import ExecutionStateMachine
from geo_operator.browser.lease import ExecutionLeaseManager, LeaseUnavailable
from geo_operator.browser.session import BrowserSessionManager, ManualLoginLauncher
from geo_operator.browser.worker import BrowserWorker
from geo_operator.core.db import Database
from geo_operator.core.storage import ArtifactStore
from geo_operator.tenants import TenantService


class LeaseTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.database = Database(root / "db.sqlite3")
        self.database.initialize()
        self.artifacts = ArtifactStore(root / "data")
        self.tenant = TenantService(self.database, self.artifacts).create("KZQ")
        self.engine = ExecutionStateMachine(self.database)
        self.leases = ExecutionLeaseManager(self.database, ttl_seconds=30)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_execution_and_session_locks_are_exclusive(self) -> None:
        first = self.engine.create(self.tenant["id"], "chatgpt", "account-a")
        second = self.engine.create(self.tenant["id"], "chatgpt", "account-a")
        third = self.engine.create(self.tenant["id"], "chatgpt", "account-b")
        self.leases.acquire(first["id"], "worker-1")
        with self.assertRaises(LeaseUnavailable):
            self.leases.acquire(first["id"], "worker-2")
        with self.assertRaises(LeaseUnavailable):
            self.leases.acquire(second["id"], "worker-2")
        self.leases.acquire(third["id"], "worker-2")
        self.leases.heartbeat(first["id"], "worker-1")
        self.leases.release(first["id"], "worker-1")
        self.leases.acquire(second["id"], "worker-2")

    def test_expired_lease_is_recovered_and_audited(self) -> None:
        execution = self.engine.create(self.tenant["id"], "doubao", "account-a")
        self.leases.acquire(execution["id"], "dead-worker")
        with self.database.transaction() as connection:
            connection.execute("UPDATE execution_leases SET expires_at='2000-01-01T00:00:00+00:00'")
            connection.execute("UPDATE session_locks SET expires_at='2000-01-01T00:00:00+00:00'")
        recovered = self.leases.release_expired()
        self.assertEqual(recovered, [execution["id"]])
        event = self.database.one(
            """SELECT * FROM execution_events
               WHERE execution_id=? AND event_type='LEASE_EXPIRED'""",
            (execution["id"],),
        )
        self.assertIsNotNone(event)
        self.leases.acquire(execution["id"], "replacement-worker")

    def test_worker_renews_lease_during_long_browser_operation(self) -> None:
        leases = ExecutionLeaseManager(self.database, ttl_seconds=1)
        execution = self.engine.create(self.tenant["id"], "chatgpt", "account-a")
        worker = BrowserWorker(
            self.database,
            None,
            self.engine,
            leases,
            None,
            worker_id="long-operation-worker",
        )

        async def operation() -> dict[str, bool]:
            await asyncio.sleep(1.2)
            lease = self.database.one(
                "SELECT * FROM execution_leases WHERE execution_id=?", (execution["id"],)
            )
            self.assertNotEqual(lease["acquired_at"], lease["heartbeat_at"])
            return {"completed": True}

        result = asyncio.run(worker._run_with_lease(execution["id"], operation))
        self.assertEqual(result, {"completed": True})
        self.assertIsNone(self.database.one("SELECT * FROM execution_leases"))

    def test_session_identity_rejects_path_traversal(self) -> None:
        with self.assertRaisesRegex(ValueError, "account_id"):
            BrowserSessionManager.validate_identity("chatgpt", "../../escape")
        with self.assertRaisesRegex(ValueError, "platform"):
            BrowserSessionManager.validate_identity("../chatgpt", "manual")

    def test_managed_browser_explicitly_enables_chromium_sandbox(self) -> None:
        manager = BrowserSessionManager(self.artifacts, self.database, browser_channel="chrome")
        profile = self.artifacts.resolve(self.tenant["id"], "sessions/chatgpt/manual")
        headed = manager._launch_options(profile, headless=False)
        self.assertIs(headed["chromium_sandbox"], True)
        self.assertEqual(headed["channel"], "chrome")
        headless = manager._launch_options(profile, headless=True)
        self.assertIs(headless["chromium_sandbox"], True)
        self.assertNotIn("channel", headless)

    @patch("geo_operator.browser.session.system_chrome_path")
    @patch("geo_operator.browser.session.subprocess.Popen")
    def test_manual_login_uses_native_chrome_without_automation_flags(
        self, popen: object, chrome_path: object
    ) -> None:
        chrome_path.return_value = Path("C:/Program Files/Google/Chrome/Application/chrome.exe")
        process = popen.return_value
        process.poll.return_value = None
        launcher = ManualLoginLauncher(self.artifacts, self.database)
        launcher.open(self.tenant["id"], "chatgpt", "manual", "https://chatgpt.com/")
        command = popen.call_args.args[0]
        self.assertEqual(command[0], str(chrome_path.return_value))
        self.assertFalse(any("automation" in argument.lower() for argument in command))
        self.assertFalse(any("remote-debugging" in argument.lower() for argument in command))
        session = self.database.one(
            "SELECT * FROM browser_sessions WHERE tenant_id=? AND platform='chatgpt'",
            (self.tenant["id"],),
        )
        self.assertEqual(session["status"], "MANUAL_LOGIN_OPEN")
        with self.assertRaisesRegex(ValueError, "Close the manual system Chrome"):
            launcher.ensure_closed(self.tenant["id"], "chatgpt", "manual")
        process.poll.return_value = 0
        launcher.ensure_closed(self.tenant["id"], "chatgpt", "manual")


if __name__ == "__main__":
    unittest.main()
