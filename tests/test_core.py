import json
import tempfile
import unittest
import zipfile
from pathlib import Path

from geo_operator.approvals import ApprovalService
from geo_operator.browser import ExecutionStateMachine
from geo_operator.core.db import Database
from geo_operator.core.storage import ArtifactStore
from geo_operator.discovery import PublicDiscoveryService
from geo_operator.domain import ApprovalStage, ExecutionState, PauseReason
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


if __name__ == "__main__":
    unittest.main()
