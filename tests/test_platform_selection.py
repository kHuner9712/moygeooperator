import tempfile
import unittest
from pathlib import Path

from fastapi.testclient import TestClient

from geo_operator.api import create_app
from geo_operator.core.config import Settings
from tests.helpers import build_task_package, make_task


class PlatformSelectionTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.client = TestClient(create_app(Settings(root / "data", root / "operator.sqlite3")))
        self.tenant = self.client.post("/api/tenants", json={"name": "Platform Select"}).json()
        profile = self.client.post(
            f"/api/tenants/{self.tenant['id']}/profile",
            json={"profile": {"name": "Platform Select"}},
        ).json()
        approved = self.client.post(
            f"/api/approvals/{profile['approval_id']}/decision",
            json={"approved": True, "actor": "tester", "note": ""},
        )
        self.assertEqual(approved.status_code, 200)

    def tearDown(self) -> None:
        self.client.close()
        self.temp.cleanup()

    def _import_multi_platform_package(self, package_id: str) -> dict[str, object]:
        tasks = []
        for sequence, platform in enumerate(("chatgpt", "deepseek", "qwen"), 1):
            task = make_task(sequence)
            task["platform"] = platform
            task["task_id"] = f"{package_id}-{platform}"
            task["idempotency_key"] = f"{package_id}-{platform}-key"
            tasks.append(task)
        response = self.client.post(
            f"/api/tenants/{self.tenant['id']}/task-packages",
            content=build_task_package(self.tenant["id"], package_id, tasks),
            headers={"Content-Type": "application/zip"},
        )
        self.assertEqual(response.status_code, 201)
        return response.json()

    def test_selected_platforms_only_create_selected_executions(self) -> None:
        package = self._import_multi_platform_package("select-one")
        selected = self.client.put(
            f"/api/task-packages/{package['id']}/platform-selection",
            json={"platforms": ["chatgpt"]},
        )
        self.assertEqual(selected.status_code, 200)
        self.assertEqual(selected.json()["selected_platforms"], ["chatgpt"])
        statuses = {task["platform"]: task["status"] for task in selected.json()["tasks"]}
        self.assertEqual(statuses["chatgpt"], "PENDING")
        self.assertEqual(statuses["deepseek"], "SKIPPED")
        self.assertEqual(statuses["qwen"], "SKIPPED")

        approved = self.client.post(
            f"/api/approvals/{package['approval_id']}/decision",
            json={"approved": True, "actor": "tester", "note": ""},
        )
        self.assertEqual(approved.status_code, 200)
        executions = self.client.get("/api/executions").json()
        self.assertEqual(len(executions), 1)
        self.assertEqual(executions[0]["platform"], "chatgpt")

        locked = self.client.put(
            f"/api/task-packages/{package['id']}/platform-selection",
            json={"platforms": ["deepseek"]},
        )
        self.assertEqual(locked.status_code, 409)

    def test_paused_platform_cannot_be_selected(self) -> None:
        package = self._import_multi_platform_package("paused-platform")
        response = self.client.put(
            f"/api/task-packages/{package['id']}/platform-selection",
            json={"platforms": ["qwen"]},
        )
        self.assertEqual(response.status_code, 409)
        self.assertIn("INTEGRATION_PAUSED", response.json()["detail"])

    def test_skipped_tasks_do_not_block_result_export_approval(self) -> None:
        package = self._import_multi_platform_package("skip-export")
        selected = self.client.put(
            f"/api/task-packages/{package['id']}/platform-selection",
            json={"platforms": ["chatgpt"]},
        )
        self.assertEqual(selected.status_code, 200)
        selected_task = next(
            task for task in selected.json()["tasks"] if task["platform"] == "chatgpt"
        )
        database = self.client.app.state.services["database"]
        with database.transaction() as connection:
            connection.execute(
                "UPDATE tasks SET status='COMPLETED' WHERE id=?", (selected_task["id"],)
            )
        result_packages = self.client.app.state.services["result_packages"]
        approval = result_packages.request_approval(package["id"])
        self.assertEqual(approval["stage"], "RESULT_EXPORT")

    def test_dashboard_exposes_platform_selector(self) -> None:
        html = self.client.get("/").text
        self.assertIn("本轮检测平台", html)
        self.assertIn("保存检测平台", html)
        self.assertIn("package-platform-choice", html)
        self.assertIn("/platform-selection", html)
        self.assertIn("savePlatformSelection", html)
        self.assertIn("dataset.tenantDisabled", html)


if __name__ == "__main__":
    unittest.main()
