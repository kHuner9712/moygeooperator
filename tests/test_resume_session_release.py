import tempfile
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, Mock

from fastapi.testclient import TestClient

from geo_operator.api import create_app
from geo_operator.core.config import Settings
from geo_operator.domain import PauseReason


class ResumeSessionReleaseTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.app = create_app(Settings(root / "data", root / "db.sqlite3"))
        self.client = TestClient(self.app)
        self.tenant = self.client.post("/api/tenants", json={"name": "KZQ"}).json()
        self.engine = self.app.state.services["engine"]
        self.sessions = self.app.state.services["sessions"]
        self.manual_logins = self.app.state.services["manual_logins"]

    def tearDown(self) -> None:
        self.client.close()
        self.temp.cleanup()

    def _paused_execution(self) -> dict[str, object]:
        execution = self.engine.create(
            self.tenant["id"],
            "chatgpt",
            "manual",
        )
        return self.engine.pause(execution["id"], PauseReason.LOGIN_EXPIRED)

    def test_continue_releases_control_process_session_before_resume_request(self) -> None:
        execution = self._paused_execution()
        self.manual_logins.ensure_closed = Mock()
        self.sessions.close = AsyncMock()

        response = self.client.post(
            f"/api/executions/{execution['id']}/continue",
            json={"note": "login completed"},
        )

        self.assertEqual(response.status_code, 200)
        self.manual_logins.ensure_closed.assert_called_once_with(
            self.tenant["id"], "chatgpt", "manual"
        )
        self.sessions.close.assert_awaited_once_with(self.tenant["id"], "chatgpt", "manual")
        latest = self.app.state.services["database"].one(
            """SELECT event_type FROM execution_events
               WHERE execution_id=? ORDER BY sequence DESC LIMIT 1""",
            (execution["id"],),
        )
        self.assertEqual(latest["event_type"], "HUMAN_TAKEOVER_COMPLETED")

    def test_continue_is_rejected_while_manual_login_chrome_is_still_open(self) -> None:
        execution = self._paused_execution()
        self.manual_logins.ensure_closed = Mock(side_effect=ValueError("manual Chrome open"))
        self.sessions.close = AsyncMock()

        response = self.client.post(
            f"/api/executions/{execution['id']}/continue",
            json={"note": "login completed"},
        )

        self.assertEqual(response.status_code, 409)
        self.assertIn("请先关闭正常 Chrome 登录窗口", response.json()["detail"])
        self.sessions.close.assert_not_awaited()
        latest = self.app.state.services["database"].one(
            """SELECT event_type FROM execution_events
               WHERE execution_id=? ORDER BY sequence DESC LIMIT 1""",
            (execution["id"],),
        )
        self.assertEqual(latest["event_type"], "EXECUTION_PAUSED")


if __name__ == "__main__":
    unittest.main()
