from __future__ import annotations

import asyncio
import json
import socket
import tempfile
import threading
import time
import unittest
import uuid
import zipfile
from pathlib import Path

import uvicorn

from geo_operator.api import create_app
from geo_operator.browser import ExecutionStateMachine
from geo_operator.browser.lease import ExecutionLeaseManager
from geo_operator.browser.plugins.base import SideEffectNotAttempted
from geo_operator.browser.plugins.mock import MockAIPlugin
from geo_operator.browser.plugins.phase1 import PluginNotCalibrated
from geo_operator.browser.registry import PluginRegistry
from geo_operator.browser.supervisor import WorkerSupervisor
from geo_operator.browser.worker import BrowserWorker, WorkerConfig
from geo_operator.core.config import Settings
from geo_operator.domain import ExecutionState, PauseReason
from geo_operator.exports import ResultPackageService
from geo_operator.results import ResultService
from tests.helpers import build_task_package, make_task


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


class BrowserMockTestCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.loop = asyncio.new_event_loop()
        cls.temp = tempfile.TemporaryDirectory()
        root = Path(cls.temp.name)
        cls.port = free_port()
        cls.app = create_app(Settings(root / "data", root / "operator.sqlite3", port=cls.port))
        cls.server = uvicorn.Server(
            uvicorn.Config(cls.app, host="127.0.0.1", port=cls.port, log_level="error")
        )
        cls.thread = threading.Thread(target=cls.server.run, daemon=True)
        cls.thread.start()
        deadline = time.time() + 10
        while time.time() < deadline:
            try:
                with socket.create_connection(("127.0.0.1", cls.port), timeout=0.2):
                    break
            except OSError:
                time.sleep(0.05)
        else:
            raise RuntimeError("Mock server failed to start")
        services = cls.app.state.services
        cls.database = services["database"]
        cls.artifacts = services["artifacts"]
        cls.tenants = services["tenants"]
        cls.approvals = services["approvals"]
        cls.task_packages = services["task_packages"]
        cls.engine: ExecutionStateMachine = services["engine"]
        cls.sessions = services["sessions"]
        cls.results: ResultService = services["results"]
        cls.result_packages: ResultPackageService = services["result_packages"]
        cls.tenant = cls.tenants.create("KZQ Browser Test")

    @classmethod
    def tearDownClass(cls) -> None:
        cls.loop.run_until_complete(cls.sessions.close_all())
        cls.server.should_exit = True
        cls.thread.join(timeout=10)
        cls.temp.cleanup()
        cls.loop.close()

    def create_execution(self, mode: str) -> tuple[dict[str, object], dict[str, object]]:
        number = uuid.uuid4().hex[:10]
        task = make_task(1, mode)
        task["task_id"] = f"task-{number}"
        task["idempotency_key"] = f"key-{number}"
        task["account_id"] = f"account-{number}"
        package = self.task_packages.import_zip(
            self.tenant["id"],
            build_task_package(self.tenant["id"], f"package-{number}", [task]),
        )
        self.approvals.decide(package["approval_id"], True, "browser-test")
        package = self.task_packages.mark_decision(package["id"], True)
        stored_task = package["tasks"][0]
        execution = self.engine.create(
            self.tenant["id"],
            "mock",
            stored_task["account_id"],
            package["id"],
            stored_task["id"],
        )
        return package, execution

    def run_worker(
        self,
        execution_id: str,
        mode: str,
        *,
        crash_hook=None,
        timeout: float = 8,
    ) -> dict[str, object]:
        worker = BrowserWorker(
            self.database,
            self.sessions,
            self.engine,
            ExecutionLeaseManager(self.database, ttl_seconds=10),
            self.results,
            WorkerConfig(
                poll_interval=0.05,
                stable_window=0.25,
                response_timeout=timeout,
                headless=True,
            ),
            crash_hook=crash_hook,
        )
        plugin = MockAIPlugin(f"http://127.0.0.1:{self.port}", mode)
        return self.loop.run_until_complete(worker.run_execution(execution_id, plugin))

    def test_kzq_ten_question_acceptance(self) -> None:
        token = uuid.uuid4().hex[:10]
        tasks = []
        for number in range(1, 11):
            task = make_task(number, "normal")
            task["task_id"] = f"kzq-{token}-{number}"
            task["idempotency_key"] = f"kzq-{token}-key-{number}"
            task["account_id"] = f"kzq-shared-{token}"
            tasks.append(task)
        package = self.task_packages.import_zip(
            self.tenant["id"],
            build_task_package(self.tenant["id"], f"kzq-acceptance-{token}", tasks),
        )
        self.approvals.decide(package["approval_id"], True, "kzq-acceptance")
        package = self.task_packages.mark_decision(package["id"], True)
        execution_ids = []
        for task in package["tasks"]:
            execution = self.engine.create(
                self.tenant["id"],
                "mock",
                task["account_id"],
                package["id"],
                task["id"],
            )
            execution_ids.append(execution["id"])
            completed = self.run_worker(execution["id"], "normal", timeout=10)
            self.assertEqual(completed["state"], "COMPLETED")
        self.assertEqual(
            self.database.one(
                "SELECT COUNT(*) AS count FROM results WHERE execution_id IN "
                "(SELECT id FROM executions WHERE task_package_id=?)",
                (package["id"],),
            )["count"],
            10,
        )
        for execution_id in execution_ids:
            query_effects = self.database.one(
                """SELECT COUNT(*) AS count FROM side_effects
                   WHERE execution_id=? AND effect_type='QUERY_SEND'""",
                (execution_id,),
            )
            self.assertEqual(query_effects["count"], 1)
        approval = self.result_packages.request_approval(package["id"])
        self.approvals.decide(approval["id"], True, "kzq-acceptance")
        output = self.result_packages.export(package["id"])
        with zipfile.ZipFile(output) as archive:
            self.assertEqual(len(archive.read("results.jsonl").splitlines()), 10)

    def test_normal_flow_to_approved_result_zip(self) -> None:
        package, execution = self.create_execution("normal")
        completed = self.run_worker(execution["id"], "normal")
        self.assertEqual(completed["state"], "COMPLETED")
        checkpoints = self.database.all(
            "SELECT * FROM response_checkpoints WHERE execution_id=?",
            (execution["id"],),
        )
        self.assertGreater(len(checkpoints), 1)
        result = self.results.get_for_execution(execution["id"])
        self.assertTrue(
            self.artifacts.resolve(self.tenant["id"], result["relative_path"]).is_file()
        )
        approval = self.result_packages.request_approval(package["id"])
        with self.assertRaisesRegex(ValueError, "approval"):
            self.result_packages.export(package["id"])
        self.approvals.decide(approval["id"], True, "browser-test")
        output = self.result_packages.export(package["id"])
        with zipfile.ZipFile(output) as archive:
            names = set(archive.namelist())
            result_record = json.loads(archive.read("results.jsonl").splitlines()[0])
            manifest = json.loads(archive.read("manifest.json"))
        self.assertIn("started_at", result_record)
        self.assertIn("completed_at", result_record)
        self.assertNotIn("saved_at", result_record)
        manifest_paths = {item["path"] for item in manifest["files"]}
        self.assertIn("results.jsonl", manifest_paths)
        self.assertIn("events/execution_events.jsonl", manifest_paths)
        self.assertTrue(all("size" in item for item in manifest["files"]))
        self.assertIn("manifest.json", names)
        self.assertIn("results.jsonl", names)
        self.assertIn("events/execution_events.jsonl", names)
        self.assertFalse(any("session" in name.lower() for name in names))

    def test_send_crash_recovers_without_duplicate_send(self) -> None:
        _, execution = self.create_execution("normal")
        fired = False

        def crash(point: str, execution_id: str) -> None:
            nonlocal fired
            if point == "after_query_send" and not fired:
                fired = True
                raise RuntimeError("injected send crash")

        with self.assertRaisesRegex(RuntimeError, "injected"):
            self.run_worker(execution["id"], "normal", crash_hook=crash)
        intent = self.database.one(
            "SELECT * FROM side_effects WHERE execution_id=? AND effect_type='QUERY_SEND'",
            (execution["id"],),
        )
        self.assertEqual(intent["status"], "INTENT")
        completed = self.run_worker(execution["id"], "normal")
        self.assertEqual(completed["state"], "COMPLETED")
        effects = self.database.all(
            "SELECT * FROM side_effects WHERE execution_id=? AND effect_type='QUERY_SEND'",
            (execution["id"],),
        )
        self.assertEqual(len(effects), 1)
        self.assertEqual(effects[0]["status"], "CONFIRMED")

    def test_save_crash_recovers_without_losing_answer(self) -> None:
        _, execution = self.create_execution("normal")
        fired = False

        def crash(point: str, execution_id: str) -> None:
            nonlocal fired
            if point == "before_result_save" and not fired:
                fired = True
                raise RuntimeError("injected save crash")

        with self.assertRaisesRegex(RuntimeError, "injected"):
            self.run_worker(execution["id"], "normal", crash_hook=crash)
        self.assertFalse(self.results.has_saved_result(execution["id"]))
        completed = self.run_worker(execution["id"], "normal")
        self.assertEqual(completed["state"], "COMPLETED")
        self.assertTrue(self.results.has_saved_result(execution["id"]))

    def test_slow_pause_long_and_page_refresh_complete(self) -> None:
        for mode in ("slow", "pause", "long", "page_refresh"):
            with self.subTest(mode=mode):
                _, execution = self.create_execution(mode)
                completed = self.run_worker(execution["id"], mode, timeout=15)
                self.assertEqual(completed["state"], "COMPLETED")
                checkpoints = self.database.all(
                    "SELECT id FROM response_checkpoints WHERE execution_id=?",
                    (execution["id"],),
                )
                self.assertGreater(len(checkpoints), 1)

    def test_final_screenshot_failure_pauses_without_result_or_delete(self) -> None:
        _, execution = self.create_execution("normal")

        class ScreenshotFailurePlugin(MockAIPlugin):
            async def screenshot(self, page: object) -> bytes:
                raise RuntimeError("injected screenshot failure")

        worker = BrowserWorker(
            self.database,
            self.sessions,
            self.engine,
            ExecutionLeaseManager(self.database, ttl_seconds=10),
            self.results,
            WorkerConfig(
                poll_interval=0.05,
                stable_window=0.25,
                response_timeout=8,
                headless=True,
            ),
        )
        plugin = ScreenshotFailurePlugin(f"http://127.0.0.1:{self.port}", "normal")
        stopped = self.loop.run_until_complete(worker.run_execution(execution["id"], plugin))
        self.assertEqual(stopped["state"], "PAUSED")
        self.assertEqual(stopped["pause_reason"], "PAGE_ABNORMAL")
        self.assertFalse(self.results.has_saved_result(execution["id"]))
        checkpoints = self.database.all(
            "SELECT * FROM response_checkpoints WHERE execution_id=?",
            (execution["id"],),
        )
        self.assertGreater(len(checkpoints), 0)
        self.assertTrue(all(row["screenshot_path"] is None for row in checkpoints))
        delete_effect = self.database.one(
            """SELECT id FROM side_effects
               WHERE execution_id=? AND effect_type='CHAT_DELETE'""",
            (execution["id"],),
        )
        self.assertIsNone(delete_effect)

    def test_delete_intent_crash_fails_closed_on_recovery(self) -> None:
        _, execution = self.create_execution("normal")
        fired = False

        def crash(point: str, execution_id: str) -> None:
            nonlocal fired
            if point == "before_chat_delete" and not fired:
                fired = True
                raise RuntimeError("injected delete crash")

        with self.assertRaisesRegex(RuntimeError, "injected"):
            self.run_worker(execution["id"], "normal", crash_hook=crash)
        stopped = self.run_worker(execution["id"], "normal")
        self.assertEqual(stopped["state"], "PAUSED")
        self.assertEqual(stopped["pause_reason"], "COMPLETION_UNCERTAIN")
        task = self.database.one("SELECT * FROM tasks WHERE id=?", (execution["task_id"],))
        self.assertEqual(task["status"], "PENDING")

    def test_partial_live_calibration_sends_once_then_pauses_with_structure(self) -> None:
        _, execution = self.create_execution("normal")

        class PartialCalibrationPlugin(MockAIPlugin):
            async def query_exists(self, page: object, prompt: str) -> bool:
                raise PluginNotCalibrated("mock user_queries calibration missing")

            async def structural_snapshot(self, page: object) -> list[dict[str, object]]:
                return [{"tag": "div", "data_testid": "response", "text": None}]

        worker = BrowserWorker(
            self.database,
            self.sessions,
            self.engine,
            ExecutionLeaseManager(self.database, ttl_seconds=10),
            self.results,
            WorkerConfig(
                poll_interval=0.05,
                stable_window=0.25,
                response_timeout=8,
                headless=True,
            ),
        )
        plugin = PartialCalibrationPlugin(f"http://127.0.0.1:{self.port}", "normal")
        stopped = self.loop.run_until_complete(worker.run_execution(execution["id"], plugin))
        self.assertEqual(stopped["state"], "PAUSED")
        self.assertEqual(stopped["pause_reason"], "PAGE_ABNORMAL")
        effects = self.database.all(
            "SELECT * FROM side_effects WHERE execution_id=? AND effect_type='QUERY_SEND'",
            (execution["id"],),
        )
        self.assertEqual(len(effects), 1)
        self.assertEqual(effects[0]["status"], "INTENT")
        event = self.database.one(
            """SELECT payload_json FROM execution_events
               WHERE execution_id=? AND event_type='EXECUTION_PAUSED'
               ORDER BY sequence DESC LIMIT 1""",
            (execution["id"],),
        )
        self.assertIn("screenshot_path", event["payload_json"])
        self.assertIn("structure_path", event["payload_json"])
        self.assertIn("query_effect_status", event["payload_json"])

    def test_observation_failure_returns_paused_execution_without_type_confusion(self) -> None:
        _, execution = self.create_execution("normal")

        class ObservationFailurePlugin(MockAIPlugin):
            async def observe_response(self, page: object):
                raise PluginNotCalibrated("injected response observation failure")

        worker = BrowserWorker(
            self.database,
            self.sessions,
            self.engine,
            ExecutionLeaseManager(self.database, ttl_seconds=10),
            self.results,
            WorkerConfig(
                poll_interval=0.05,
                stable_window=0.25,
                response_timeout=2,
                observation_error_grace=0.1,
                headless=True,
            ),
        )
        plugin = ObservationFailurePlugin(f"http://127.0.0.1:{self.port}", "normal")
        stopped = self.loop.run_until_complete(worker.run_execution(execution["id"], plugin))
        self.assertEqual(stopped["state"], "PAUSED")
        self.assertEqual(stopped["pause_reason"], "PAGE_ABNORMAL")
        revalidation_events = self.database.one(
            """SELECT COUNT(*) AS count FROM execution_events
               WHERE execution_id=? AND event_type='RESUME_REVALIDATION_FAILED'""",
            (execution["id"],),
        )
        self.assertEqual(revalidation_events["count"], 0)

    def test_supervisor_never_starts_next_question_after_delete_failure(self) -> None:
        token = uuid.uuid4().hex[:10]
        first = make_task(1, "delete_fail")
        first["task_id"] = f"blocked-{token}-1"
        first["idempotency_key"] = f"blocked-{token}-key-1"
        first["account_id"] = f"blocked-{token}"
        second = make_task(2, "normal")
        second["task_id"] = f"blocked-{token}-2"
        second["idempotency_key"] = f"blocked-{token}-key-2"
        second["account_id"] = f"blocked-{token}"
        package = self.task_packages.import_zip(
            self.tenant["id"],
            build_task_package(self.tenant["id"], f"blocked-package-{token}", [first, second]),
        )
        self.approvals.decide(package["approval_id"], True, "browser-test")
        package = self.task_packages.mark_decision(package["id"], True)
        executions = []
        for task in package["tasks"]:
            executions.append(
                self.engine.create(
                    self.tenant["id"],
                    "mock",
                    task["account_id"],
                    package["id"],
                    task["id"],
                )
            )
        supervisor = WorkerSupervisor(
            self.database,
            self.sessions,
            self.engine,
            ExecutionLeaseManager(self.database, ttl_seconds=10),
            self.results,
            PluginRegistry(self.database, f"http://127.0.0.1:{self.port}"),
            WorkerConfig(
                poll_interval=0.05,
                stable_window=0.25,
                response_timeout=8,
                headless=True,
            ),
        )
        self.assertTrue(self.loop.run_until_complete(supervisor.run_once()))
        self.assertEqual(self.engine.get(executions[0]["id"])["state"], "PAUSED")
        self.assertFalse(self.loop.run_until_complete(supervisor.run_once()))
        self.assertEqual(self.engine.get(executions[1]["id"])["state"], "CREATED")
        second_effects = self.database.one(
            "SELECT COUNT(*) AS count FROM side_effects WHERE execution_id=?",
            (executions[1]["id"],),
        )
        self.assertEqual(second_effects["count"], 0)

    def test_captcha_pauses_same_platform_account_across_task_packages(self) -> None:
        token = uuid.uuid4().hex[:10]
        account_id = f"platform-gate-{token}"
        executions = []
        for index, mode in enumerate(("captcha", "normal"), start=1):
            task = make_task(1, mode)
            task["task_id"] = f"platform-gate-{token}-{index}"
            task["idempotency_key"] = f"platform-gate-{token}-key-{index}"
            task["account_id"] = account_id
            package = self.task_packages.import_zip(
                self.tenant["id"],
                build_task_package(
                    self.tenant["id"], f"platform-gate-package-{token}-{index}", [task]
                ),
            )
            self.approvals.decide(package["approval_id"], True, "browser-test")
            package = self.task_packages.mark_decision(package["id"], True)
            stored_task = package["tasks"][0]
            executions.append(
                self.engine.create(
                    self.tenant["id"],
                    "mock",
                    account_id,
                    package["id"],
                    stored_task["id"],
                )
            )

        class HomeAwareRegistry(PluginRegistry):
            def for_execution(self, execution):
                plugin = super().for_execution(execution)
                plugin.home_url = plugin.url
                return plugin

        supervisor = WorkerSupervisor(
            self.database,
            self.sessions,
            self.engine,
            ExecutionLeaseManager(self.database, ttl_seconds=10),
            self.results,
            HomeAwareRegistry(self.database, f"http://127.0.0.1:{self.port}"),
            WorkerConfig(
                poll_interval=0.05,
                stable_window=0.25,
                response_timeout=8,
                headless=True,
            ),
        )
        self.assertTrue(self.loop.run_until_complete(supervisor.run_once()))
        first = self.engine.get(executions[0]["id"])
        self.assertEqual(first["state"], "PAUSED")
        self.assertEqual(first["pause_reason"], "CAPTCHA")

        self.assertFalse(self.loop.run_until_complete(supervisor.run_once()))
        self.assertEqual(self.engine.get(executions[1]["id"])["state"], "CREATED")
        self.assertIsNone(
            self.database.one(
                "SELECT id FROM side_effects WHERE execution_id=?",
                (executions[1]["id"],),
            )
        )

        with self.database.transaction() as connection:
            task = connection.execute(
                "SELECT metadata_json FROM tasks WHERE id=?", (first["task_id"],)
            ).fetchone()
            metadata = json.loads(str(task["metadata_json"]))
            metadata["mock_mode"] = "normal"
            connection.execute(
                "UPDATE tasks SET metadata_json=? WHERE id=?",
                (json.dumps(metadata), first["task_id"]),
            )
        self.engine.request_resume(first["id"], "captcha completed by operator")
        self.assertTrue(self.loop.run_until_complete(supervisor.run_once()))
        self.assertEqual(self.engine.get(first["id"])["state"], "COMPLETED")

        self.assertTrue(self.loop.run_until_complete(supervisor.run_once()))
        self.assertEqual(self.engine.get(executions[1]["id"])["state"], "COMPLETED")

    def test_independent_worker_revalidates_human_takeover_before_resume(self) -> None:
        _, execution = self.create_execution("normal")
        fired = False

        def crash(point: str, execution_id: str) -> None:
            nonlocal fired
            if point == "after_query_send" and not fired:
                fired = True
                raise RuntimeError("pause for human takeover")

        with self.assertRaisesRegex(RuntimeError, "human takeover"):
            self.run_worker(execution["id"], "normal", crash_hook=crash)
        self.engine.pause(
            execution["id"], PauseReason.OPERATOR_REQUESTED, ExecutionState.SEND_QUERY
        )
        self.engine.request_resume(execution["id"], "operator reviewed page")
        supervisor = WorkerSupervisor(
            self.database,
            self.sessions,
            self.engine,
            ExecutionLeaseManager(self.database, ttl_seconds=10),
            self.results,
            PluginRegistry(self.database, f"http://127.0.0.1:{self.port}"),
            WorkerConfig(
                poll_interval=0.05,
                stable_window=0.25,
                response_timeout=8,
                headless=True,
            ),
        )
        self.assertTrue(self.loop.run_until_complete(supervisor.run_once()))
        self.assertEqual(self.engine.get(execution["id"])["state"], "COMPLETED")
        event = self.database.one(
            """SELECT event_type FROM execution_events
               WHERE execution_id=? AND event_type='RESUMED_AFTER_REVALIDATION'""",
            (execution["id"],),
        )
        self.assertIsNotNone(event)

    def test_pre_send_pause_recovers_from_platform_home_without_conversation_url(self) -> None:
        package, execution = self.create_execution("normal")
        execution_id = str(execution["id"])
        self.engine.transition(execution_id, ExecutionState.WAIT_LOGIN)
        self.engine.transition(execution_id, ExecutionState.READY)
        self.engine.wait_for_approval(
            execution_id, str(package["approval_id"]), ExecutionState.OPEN_PLATFORM
        )
        self.engine.resolve_approval(execution_id, True)
        self.engine.transition(execution_id, ExecutionState.SEND_QUERY)
        self.engine.pause(execution_id, PauseReason.PAGE_ABNORMAL)
        self.assertIsNone(
            self.database.one(
                """SELECT id FROM side_effects
                   WHERE execution_id=? AND effect_type='QUERY_SEND'""",
                (execution_id,),
            )
        )
        self.engine.request_resume(execution_id, "pre-send page reviewed")

        class PreSendResumePlugin(MockAIPlugin):
            def __init__(self, base_url: str) -> None:
                super().__init__(base_url, "normal")
                self.home_url = self.url

        worker = BrowserWorker(
            self.database,
            self.sessions,
            self.engine,
            ExecutionLeaseManager(self.database, ttl_seconds=10),
            self.results,
            WorkerConfig(
                poll_interval=0.05,
                stable_window=0.25,
                response_timeout=8,
                headless=True,
            ),
        )
        plugin = PreSendResumePlugin(f"http://127.0.0.1:{self.port}")
        completed = self.loop.run_until_complete(worker.resume_after_human(execution_id, plugin))

        self.assertEqual(completed["state"], "COMPLETED")
        effects = self.database.all(
            """SELECT * FROM side_effects
               WHERE execution_id=? AND effect_type='QUERY_SEND'""",
            (execution_id,),
        )
        self.assertEqual(len(effects), 1)
        self.assertEqual(effects[0]["status"], "CONFIRMED")

    def test_pre_click_failure_retries_same_intent_without_duplicate_send(self) -> None:
        _, execution = self.create_execution("normal")
        execution_id = str(execution["id"])

        class PreflightFailurePlugin(MockAIPlugin):
            def __init__(self, base_url: str) -> None:
                super().__init__(base_url, "normal")
                self.home_url = self.url
                self.fail_preflight = True

            async def send_query(self, page: object, prompt: str) -> None:
                if self.fail_preflight:
                    self.fail_preflight = False
                    raise SideEffectNotAttempted("injected pre-click failure")
                await super().send_query(page, prompt)

        worker = BrowserWorker(
            self.database,
            self.sessions,
            self.engine,
            ExecutionLeaseManager(self.database, ttl_seconds=10),
            self.results,
            WorkerConfig(
                poll_interval=0.05,
                stable_window=0.25,
                response_timeout=8,
                headless=True,
            ),
        )
        plugin = PreflightFailurePlugin(f"http://127.0.0.1:{self.port}")
        paused = self.loop.run_until_complete(worker.run_execution(execution_id, plugin))
        self.assertEqual(paused["state"], "PAUSED")
        effect = self.database.one(
            """SELECT * FROM side_effects
               WHERE execution_id=? AND effect_type='QUERY_SEND'""",
            (execution_id,),
        )
        self.assertEqual(effect["status"], "INTENT")
        self.assertIn('"action_attempted": false', effect["observation_json"])

        self.engine.request_resume(execution_id, "pre-click failure fixed")
        completed = self.loop.run_until_complete(worker.resume_after_human(execution_id, plugin))

        self.assertEqual(completed["state"], "COMPLETED")
        effects = self.database.all(
            """SELECT * FROM side_effects
               WHERE execution_id=? AND effect_type='QUERY_SEND'""",
            (execution_id,),
        )
        self.assertEqual(len(effects), 1)
        self.assertEqual(effects[0]["status"], "CONFIRMED")
        retry_event = self.database.one(
            """SELECT id FROM execution_events
               WHERE execution_id=? AND event_type='SIDE_EFFECT_RETRY_STARTED'""",
            (execution_id,),
        )
        self.assertIsNotNone(retry_event)

    def test_captcha_delivery_failure_retries_same_intent_after_human_resume(self) -> None:
        _, execution = self.create_execution("normal")
        execution_id = str(execution["id"])

        class DeliveryFailureCaptchaPlugin(MockAIPlugin):
            def __init__(self, base_url: str) -> None:
                super().__init__(base_url, "normal")
                self.home_url = self.url
                self.challenge = False
                self.send_count = 0

            async def send_query(self, page: object, prompt: str) -> None:
                self.send_count += 1
                await super().send_query(page, prompt)
                if self.send_count == 1:
                    self.challenge = True

            async def detect_human_intervention(self, page: object) -> str | None:
                if self.challenge:
                    return "CAPTCHA"
                return await super().detect_human_intervention(page)

            async def query_delivery_failed(self, page: object, prompt: str) -> bool:
                return self.challenge

        worker = BrowserWorker(
            self.database,
            self.sessions,
            self.engine,
            ExecutionLeaseManager(self.database, ttl_seconds=10),
            self.results,
            WorkerConfig(
                poll_interval=0.05,
                stable_window=0.25,
                response_timeout=8,
                headless=True,
            ),
        )
        plugin = DeliveryFailureCaptchaPlugin(f"http://127.0.0.1:{self.port}")
        paused = self.loop.run_until_complete(worker.run_execution(execution_id, plugin))
        self.assertEqual(paused["state"], "PAUSED")
        self.assertEqual(paused["pause_reason"], "CAPTCHA")
        effect = self.database.one(
            """SELECT * FROM side_effects
               WHERE execution_id=? AND effect_type='QUERY_SEND'""",
            (execution_id,),
        )
        self.assertEqual(effect["status"], "INTENT")
        self.assertIn('"delivery_failed": true', effect["observation_json"])

        plugin.challenge = False
        self.engine.request_resume(execution_id, "captcha completed by operator")
        completed = self.loop.run_until_complete(worker.resume_after_human(execution_id, plugin))

        self.assertEqual(completed["state"], "COMPLETED")
        self.assertEqual(plugin.send_count, 2)
        effects = self.database.all(
            """SELECT * FROM side_effects
               WHERE execution_id=? AND effect_type='QUERY_SEND'""",
            (execution_id,),
        )
        self.assertEqual(len(effects), 1)
        self.assertEqual(effects[0]["status"], "CONFIRMED")
        event_types = {
            row["event_type"]
            for row in self.database.all(
                "SELECT event_type FROM execution_events WHERE execution_id=?",
                (execution_id,),
            )
        }
        self.assertIn("SIDE_EFFECT_DELIVERY_FAILED", event_types)
        self.assertIn("SIDE_EFFECT_RETRY_STARTED", event_types)

    def test_failed_human_revalidation_stays_paused_with_evidence(self) -> None:
        _, execution = self.create_execution("captcha")
        stopped = self.run_worker(execution["id"], "captcha")
        self.assertEqual(stopped["state"], "PAUSED")
        self.engine.request_resume(execution["id"], "captcha claimed solved")
        supervisor = WorkerSupervisor(
            self.database,
            self.sessions,
            self.engine,
            ExecutionLeaseManager(self.database, ttl_seconds=10),
            self.results,
            PluginRegistry(self.database, f"http://127.0.0.1:{self.port}"),
            WorkerConfig(headless=True),
        )
        self.assertTrue(self.loop.run_until_complete(supervisor.run_once()))
        self.assertEqual(self.engine.get(execution["id"])["state"], "PAUSED")
        event = self.database.one(
            """SELECT payload_json FROM execution_events
               WHERE execution_id=? AND event_type='RESUME_REVALIDATION_FAILED'
               ORDER BY sequence DESC LIMIT 1""",
            (execution["id"],),
        )
        self.assertIsNotNone(event)
        self.assertIn("screenshot_path", event["payload_json"])
        self.assertFalse(self.loop.run_until_complete(supervisor.run_once()))

    def test_resume_authorization_is_consumed_after_execution_pauses_again(self) -> None:
        _, execution = self.create_execution("delete_fail")
        stopped = self.run_worker(execution["id"], "delete_fail")
        self.assertEqual(stopped["state"], "PAUSED")
        self.engine.request_resume(execution["id"], "operator reviewed delete failure")
        supervisor = WorkerSupervisor(
            self.database,
            self.sessions,
            self.engine,
            ExecutionLeaseManager(self.database, ttl_seconds=10),
            self.results,
            PluginRegistry(self.database, f"http://127.0.0.1:{self.port}"),
            WorkerConfig(headless=True),
        )
        self.assertTrue(self.loop.run_until_complete(supervisor.run_once()))
        self.assertEqual(self.engine.get(execution["id"])["state"], "PAUSED")
        self.assertFalse(self.loop.run_until_complete(supervisor.run_once()))

    def test_calibration_required_platform_pauses_before_browser_open(self) -> None:
        token = uuid.uuid4().hex[:10]
        task = make_task(1)
        task["task_id"] = f"pending-{token}"
        task["idempotency_key"] = f"pending-key-{token}"
        task["account_id"] = f"pending-account-{token}"
        task["platform"] = "qwen"
        package = self.task_packages.import_zip(
            self.tenant["id"],
            build_task_package(self.tenant["id"], f"pending-package-{token}", [task]),
        )
        self.approvals.decide(package["approval_id"], True, "calibration-gate-test")
        package = self.task_packages.mark_decision(package["id"], True)
        execution = self.engine.create(
            self.tenant["id"],
            "qwen",
            task["account_id"],
            package["id"],
            package["tasks"][0]["id"],
        )
        supervisor = WorkerSupervisor(
            self.database,
            self.sessions,
            self.engine,
            ExecutionLeaseManager(self.database, ttl_seconds=10),
            self.results,
            PluginRegistry(self.database, f"http://127.0.0.1:{self.port}"),
            WorkerConfig(headless=True),
        )

        self.assertTrue(self.loop.run_until_complete(supervisor.run_once()))
        paused = self.engine.get(execution["id"])
        self.assertEqual(paused["state"], "PAUSED")
        self.assertEqual(paused["pause_reason"], "PAGE_ABNORMAL")
        event = self.database.one(
            """SELECT payload_json FROM execution_events
               WHERE execution_id=? AND event_type='EXECUTION_PAUSED'
               ORDER BY sequence DESC LIMIT 1""",
            (execution["id"],),
        )
        self.assertIn("PLUGIN_CALIBRATION_REQUIRED", event["payload_json"])
        session = self.database.one(
            """SELECT id FROM browser_sessions
               WHERE tenant_id=? AND platform='deepseek' AND account_id=?""",
            (self.tenant["id"], task["account_id"]),
        )
        self.assertIsNone(session)

    def test_anomalies_and_delete_failure_pause(self) -> None:
        for mode, expected in (
            ("captcha", "CAPTCHA"),
            ("rate_limit", "RATE_LIMITED"),
            ("restricted", "ACCOUNT_RESTRICTED"),
            ("dom_change", "PAGE_ABNORMAL"),
            ("never", "COMPLETION_UNCERTAIN"),
            ("delete_fail", "COMPLETION_UNCERTAIN"),
        ):
            with self.subTest(mode=mode):
                _, execution = self.create_execution(mode)
                stopped = self.run_worker(
                    execution["id"], mode, timeout=0.8 if mode == "never" else 8
                )
                self.assertEqual(stopped["state"], "PAUSED")
                self.assertEqual(stopped["pause_reason"], expected)
                if mode == "delete_fail":
                    self.assertTrue(self.results.has_saved_result(execution["id"]))
                    task = self.database.one(
                        "SELECT * FROM tasks WHERE id=?", (execution["task_id"],)
                    )
                    self.assertEqual(task["status"], "PENDING")


if __name__ == "__main__":
    unittest.main()
