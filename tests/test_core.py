import asyncio
import json
import tempfile
import unittest
import zipfile
from pathlib import Path

from geo_operator.approvals import ApprovalService
from geo_operator.browser import ExecutionStateMachine
from geo_operator.browser.worker import (
    BrowserWorker,
    ExecutionExternallyPaused,
    WorkerConfig,
)
from geo_operator.core.config import Settings
from geo_operator.core.db import Database
from geo_operator.core.storage import ArtifactStore
from geo_operator.discovery import PublicDiscoveryService
from geo_operator.domain import ApprovalStage, ExecutionState, PauseReason
from geo_operator.runtime import RuntimeWorkerRegistry
from geo_operator.tenants import TenantService


class CoreTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.database = Database(root / "operator.sqlite3")
        self.database.initialize()
        self.artifacts = ArtifactStore(root / "data")
        self.tenant = TenantService(self.database, self.artifacts).create("测试客户")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_tenant_path_cannot_escape(self) -> None:
        self.assertTrue((self.artifacts.tenant_root(self.tenant["id"]) / "sessions").is_dir())
        with self.assertRaises(ValueError):
            self.artifacts.resolve(self.tenant["id"], "../../escape")

    def test_public_discovery_package_is_raw_evidence(self) -> None:
        service = PublicDiscoveryService(self.database, self.artifacts)
        item = service.collect(
            self.tenant["id"],
            "https://example.com/source",
            "原始证据",
            b"preserved-screenshot-bytes",
            "SEARCH_RESULT",
        )
        self.assertEqual(item["credibility_status"], "AI_PENDING")
        with zipfile.ZipFile(service.export(self.tenant["id"])) as archive:
            manifest = json.loads(archive.read("manifest.json"))
            index = json.loads(archive.read("evidence/index.jsonl"))
        self.assertEqual(manifest["package_type"], "PUBLIC_DISCOVERY")
        self.assertEqual(index["source_url"], "https://example.com/source")
        self.assertEqual(index["credibility_status"], "AI_PENDING")

    def test_approval_decision_cannot_be_overwritten(self) -> None:
        service = ApprovalService(self.database)
        item = service.request(
            self.tenant["id"], ApprovalStage.CLIENT_PROFILE_REVIEW, "profile", "profile-1"
        )
        self.assertEqual(service.decide(item["id"], True, "operator")["status"], "APPROVED")
        with self.assertRaises(ValueError):
            service.decide(item["id"], False, "operator")

    def test_approval_pause_and_revalidated_resume(self) -> None:
        approvals = ApprovalService(self.database)
        engine = ExecutionStateMachine(self.database)
        run = engine.create(self.tenant["id"], "chatgpt", "manual")
        run = engine.transition(run["id"], ExecutionState.WAIT_LOGIN)
        run = engine.transition(run["id"], ExecutionState.READY)
        approval = approvals.request(
            self.tenant["id"], ApprovalStage.TASK_EXECUTION, "execution", run["id"]
        )
        run = engine.wait_for_approval(run["id"], approval["id"], ExecutionState.OPEN_PLATFORM)
        self.assertEqual(run["state"], "WAIT_HUMAN_APPROVAL")
        approvals.decide(approval["id"], True, "operator")
        run = engine.resolve_approval(run["id"], True)
        run = engine.pause(run["id"], PauseReason.CAPTCHA, ExecutionState.OPEN_PLATFORM)
        with self.assertRaises(ValueError):
            engine.resume(run["id"], False)
        engine.request_resume(run["id"], "captcha solved")
        self.assertEqual(engine.resume(run["id"], True)["state"], "OPEN_PLATFORM")

    def test_confirmed_delivery_failure_reconciliation_is_audited(self) -> None:
        approvals = ApprovalService(self.database)
        engine = ExecutionStateMachine(self.database)
        run = engine.create(self.tenant["id"], "doubao", "manual")
        engine.transition(run["id"], ExecutionState.WAIT_LOGIN)
        engine.transition(run["id"], ExecutionState.READY)
        approval = approvals.request(
            self.tenant["id"], ApprovalStage.TASK_EXECUTION, "execution", run["id"]
        )
        engine.wait_for_approval(run["id"], approval["id"], ExecutionState.OPEN_PLATFORM)
        approvals.decide(approval["id"], True, "operator")
        engine.resolve_approval(run["id"], True)
        engine.transition(run["id"], ExecutionState.SEND_QUERY)
        effect = engine.record_effect_intent(run["id"], "QUERY_SEND", "legacy-key")
        engine.confirm_effect(effect["id"], {"query_exists": True})
        engine.transition(run["id"], ExecutionState.WAIT_RESPONSE)
        engine.pause(run["id"], PauseReason.PAGE_ABNORMAL)

        reconciled = engine.reconcile_confirmed_query_delivery_failure(
            run["id"],
            effect["id"],
            PauseReason.CAPTCHA,
            {"evidence": "visible platform delivery failure indicator"},
        )

        self.assertEqual(reconciled["state"], "PAUSED")
        self.assertEqual(reconciled["resume_state"], "SEND_QUERY")
        self.assertEqual(reconciled["pause_reason"], "CAPTCHA")
        stored = self.database.one("SELECT * FROM side_effects WHERE id=?", (effect["id"],))
        self.assertEqual(stored["status"], "INTENT")
        observation = json.loads(stored["observation_json"])
        self.assertTrue(observation["delivery_failed"])
        event = self.database.one(
            """SELECT id FROM execution_events
               WHERE execution_id=? AND event_type='SIDE_EFFECT_CONFIRMATION_REVOKED'""",
            (run["id"],),
        )
        self.assertIsNotNone(event)

    def test_illegal_transition_rejected(self) -> None:
        engine = ExecutionStateMachine(self.database)
        run = engine.create(self.tenant["id"], "doubao", "manual")
        with self.assertRaises(ValueError):
            engine.transition(run["id"], ExecutionState.SEND_QUERY)

    def test_runtime_worker_heartbeat_detects_stale_and_superseded_workers(self) -> None:
        registry = RuntimeWorkerRegistry(self.database)
        registry.register("worker-1", "BROWSER", {"headless": False})
        self.assertTrue(registry.latest("BROWSER")["available"])

        registry.heartbeat("worker-1", "BUSY")
        with self.database.transaction() as connection:
            connection.execute(
                "UPDATE runtime_workers SET heartbeat_at=? WHERE worker_id=?",
                ("2000-01-01T00:00:00+00:00", "worker-1"),
            )
        stale = registry.latest("BROWSER")
        self.assertFalse(stale["available"])
        self.assertEqual(stale["status"], "STALE")

        registry.register("worker-2", "BROWSER")
        latest = registry.latest("BROWSER")
        self.assertTrue(latest["available"])
        self.assertEqual(latest["worker_id"], "worker-2")
        previous = self.database.one(
            "SELECT status FROM runtime_workers WHERE worker_id=?", ("worker-1",)
        )
        self.assertEqual(previous["status"], "SUPERSEDED")

    def test_operator_pause_during_pacing_prevents_query_send(self) -> None:
        class PausedEngine:
            def __init__(self) -> None:
                self.pacing_recorded = False
                self.not_attempted: dict[str, object] | None = None

            def record_operation_pacing(self, execution_id: str, delay: float) -> None:
                self.pacing_recorded = True

            def get(self, execution_id: str) -> dict[str, str]:
                return {"state": ExecutionState.PAUSED.value}

            def mark_effect_not_attempted(
                self, effect_id: str, details: dict[str, object]
            ) -> None:
                self.not_attempted = details

        class NeverSendPlugin:
            async def send_query(self, page: object, prompt: str) -> None:
                raise AssertionError("query must not be sent after operator pause")

        worker = object.__new__(BrowserWorker)
        worker.engine = PausedEngine()
        worker.config = WorkerConfig(
            poll_interval=0.01,
            action_delay_min=0.05,
            action_delay_max=0.05,
        )
        with self.assertRaises(ExecutionExternallyPaused):
            asyncio.run(
                worker._perform_query_send(
                    {"id": "execution-1"},
                    {"prompt": "must not send"},
                    {"id": "effect-1"},
                    NeverSendPlugin(),
                    None,
                )
            )
        self.assertTrue(worker.engine.pacing_recorded)
        self.assertEqual(
            worker.engine.not_attempted,
            {"reason": PauseReason.OPERATOR_REQUESTED.value},
        )

    def test_browser_action_delay_configuration_is_validated(self) -> None:
        with self.assertRaises(ValueError):
            WorkerConfig(action_delay_min=-0.1)
        with self.assertRaises(ValueError):
            WorkerConfig(action_delay_min=2.0, action_delay_max=1.0)
        with self.assertRaises(ValueError):
            Settings(
                Path("data"),
                Path("operator.sqlite3"),
                browser_action_delay_min=2.0,
                browser_action_delay_max=1.0,
            )


if __name__ == "__main__":
    unittest.main()
