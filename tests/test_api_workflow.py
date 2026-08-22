import tempfile
import unittest
from pathlib import Path

from fastapi.testclient import TestClient

from geo_operator.api import create_app
from geo_operator.core.config import Settings
from tests.helpers import build_task_package, make_task


class ApiWorkflowTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.client = TestClient(create_app(Settings(root / "data", root / "db.sqlite3")))
        self.tenant = self.client.post("/api/tenants", json={"name": "KZQ"}).json()

    def tearDown(self) -> None:
        self.client.close()
        self.temp.cleanup()

    def test_profile_gate_task_import_approval_and_execution_creation(self) -> None:
        package = self.client.post(
            f"/api/tenants/{self.tenant['id']}/task-packages",
            content=build_task_package(self.tenant["id"], "kzq-api", [make_task(1), make_task(2)]),
            headers={"Content-Type": "application/zip"},
        )
        self.assertEqual(package.status_code, 201)
        package_data = package.json()
        blocked = self.client.post(
            f"/api/approvals/{package_data['approval_id']}/decision",
            json={"approved": True, "actor": "tester", "note": ""},
        )
        self.assertEqual(blocked.status_code, 409)

        profile = self.client.post(
            f"/api/tenants/{self.tenant['id']}/profile",
            json={"profile": {"name": "KZQ", "website": "https://example.com"}},
        )
        self.assertEqual(profile.status_code, 201)
        profile_data = profile.json()
        approved_profile = self.client.post(
            f"/api/approvals/{profile_data['approval_id']}/decision",
            json={"approved": True, "actor": "tester", "note": ""},
        )
        self.assertEqual(approved_profile.status_code, 200)

        approved_tasks = self.client.post(
            f"/api/approvals/{package_data['approval_id']}/decision",
            json={"approved": True, "actor": "tester", "note": ""},
        )
        self.assertEqual(approved_tasks.status_code, 200)
        executions = self.client.get("/api/executions").json()
        self.assertEqual(len(executions), 2)
        self.assertTrue(all(item["state"] == "CREATED" for item in executions))
        queued = self.client.post(f"/api/executions/{executions[0]['id']}/run")
        self.assertEqual(queued.json()["status"], "queued_for_independent_worker")
        still_created = self.client.get("/api/executions").json()
        self.assertTrue(all(item["state"] == "CREATED" for item in still_created))

    def test_local_health_declares_headed_python_312(self) -> None:
        health = self.client.get("/api/health").json()
        self.assertEqual(health["python"], "3.12")
        self.assertEqual(health["browser_mode"], "headed")
        self.assertEqual(self.client.get("/openapi.json").json()["info"]["version"], "0.3.0")
        platforms = {item["platform"]: item for item in self.client.get("/api/platforms").json()}
        self.assertTrue(platforms["chatgpt"]["complete"])
        self.assertTrue(platforms["doubao"]["complete"])
        self.assertTrue(platforms["deepseek"]["complete"])
        self.assertEqual(platforms["chatgpt"]["missing"], [])
        self.assertEqual(platforms["doubao"]["missing"], [])
        self.assertTrue(platforms["gemini"]["complete"])
        self.assertTrue(platforms["yuanbao"]["complete"])
        self.assertTrue(platforms["kimi"]["complete"])
        self.assertTrue(platforms["grok"]["complete"])
        self.assertTrue(platforms["perplexity"]["complete"])
        self.assertEqual(platforms["deepseek"]["missing"], [])
        self.assertEqual(platforms["gemini"]["missing"], [])
        self.assertEqual(platforms["yuanbao"]["missing"], [])
        self.assertEqual(platforms["kimi"]["missing"], [])
        self.assertEqual(platforms["grok"]["missing"], [])
        self.assertEqual(platforms["perplexity"]["missing"], [])
        self.assertEqual(
            set(platforms),
            {
                "mock",
                "doubao",
                "yuanbao",
                "qwen",
                "deepseek",
                "kimi",
                "grok",
                "gemini",
                "chatgpt",
                "perplexity",
            },
        )
        pending = set(platforms) - {
            "mock",
            "chatgpt",
            "doubao",
            "deepseek",
            "gemini",
            "yuanbao",
            "kimi",
            "grok",
            "perplexity",
        }
        self.assertTrue(
            all(
                platforms[platform]["support_status"]
                in {"CALIBRATION_REQUIRED", "INTEGRATION_PAUSED"}
                for platform in pending
            )
        )
        self.assertTrue(all(not platforms[platform]["dispatch_eligible"] for platform in pending))
        self.assertEqual(platforms["qwen"]["support_status"], "INTEGRATION_PAUSED")
        self.assertEqual(platforms["qwen"]["policy"], "PAUSED")
        self.assertTrue(platforms["qwen"]["integration_paused"])
        self.assertEqual(platforms["qwen"]["pause_reason"], "MANUAL_VERIFICATION_UNAVAILABLE")

    def test_execution_actions_are_filtered_by_state(self) -> None:
        html = self.client.get("/").text
        self.assertIn("function syncExecutionActions(rows)", html)
        self.assertIn("if(state==='CREATED')keep=[0,3]", html)
        self.assertIn("else if(state==='PAUSED')keep=[2,3,4]", html)
        self.assertIn("else if(state==='COMPLETED'||state==='WAIT_HUMAN_APPROVAL')keep=[3]", html)
        self.assertIn("syncExecutionActions(rows);", html)
        self.assertIn("function syncSessionInterventions(items)", html)
        self.assertIn("HUMAN_TAKEOVER_REQUIRED", html)
        self.assertIn("平台支持与校准", html)
        self.assertIn("Claude 明确禁止接入", html)
        self.assertIn('id="sessionControls"', html)
        self.assertIn("const paused=x.policy==='PAUSED'", html)
        self.assertIn('disabled title="平台接入已暂停"', html)
        self.assertIn("千问接入已暂停", html)

    def test_session_api_rejects_unsafe_identity_before_browser_launch(self) -> None:
        unsafe = self.client.post(
            "/api/sessions/open",
            json={
                "tenant_id": self.tenant["id"],
                "platform": "chatgpt",
                "account_id": "../../escape",
            },
        )
        self.assertEqual(unsafe.status_code, 422)
        prohibited = self.client.post(
            "/api/sessions/open",
            json={
                "tenant_id": self.tenant["id"],
                "platform": "Claude",
                "account_id": "manual",
            },
        )
        self.assertEqual(prohibited.status_code, 422)
        self.assertIn("explicitly prohibited", prohibited.json()["detail"])
        paused = self.client.post(
            "/api/sessions/open",
            json={
                "tenant_id": self.tenant["id"],
                "platform": "qwen",
                "account_id": "manual",
            },
        )
        self.assertEqual(paused.status_code, 422)
        self.assertIn("integration is paused", paused.json()["detail"])
        paused_snapshot = self.client.post(
            "/api/sessions/calibration-snapshot",
            json={
                "tenant_id": self.tenant["id"],
                "platform": "qwen",
                "account_id": "manual",
            },
        )
        self.assertEqual(paused_snapshot.status_code, 422)
        self.assertIn("integration is paused", paused_snapshot.json()["detail"])
        unsupported = self.client.post(
            "/api/sessions/calibration-snapshot",
            json={
                "tenant_id": self.tenant["id"],
                "platform": "unknown",
                "account_id": "manual",
            },
        )
        self.assertEqual(unsupported.status_code, 422)
        cross_origin = self.client.post(
            "/api/sessions/calibration-snapshot",
            json={
                "tenant_id": self.tenant["id"],
                "platform": "chatgpt",
                "account_id": "manual",
                "target_url": "https://example.com/credential-trap",
            },
        )
        self.assertEqual(cross_origin.status_code, 422)
        self.assertIn("same-origin HTTPS", cross_origin.json()["detail"])


if __name__ == "__main__":
    unittest.main()
