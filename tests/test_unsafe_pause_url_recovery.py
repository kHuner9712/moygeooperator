import json
import unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock

from geo_operator.browser.worker import BrowserWorker
from geo_operator.domain import ExecutionState


class UnsafePauseUrlRecoveryTestCase(unittest.IsolatedAsyncioTestCase):
    async def test_pending_query_recovers_from_history_when_only_pause_url_is_about_blank(self) -> None:
        database = Mock()
        database.one = Mock(
            side_effect=[
                None,
                {
                    "id": "effect-1",
                    "status": "INTENT",
                    "observation_json": "{}",
                },
            ]
        )
        database.all = Mock(
            return_value=[{"payload_json": json.dumps({"page_url": "about:blank"})}]
        )

        execution = {
            "id": "execution-1",
            "tenant_id": "tenant-1",
            "platform": "kimi",
            "account_id": "manual",
            "resume_state": ExecutionState.SEND_QUERY.value,
            "task_id": "task-1",
        }
        engine = Mock()
        engine.get = Mock(return_value=execution)
        engine.bind_recovery_url = Mock()

        worker = BrowserWorker(
            database=database,
            sessions=Mock(),
            engine=engine,
            leases=Mock(),
            results=Mock(),
        )
        worker._task = Mock(return_value={"prompt": "second Kimi question"})

        plugin = SimpleNamespace(
            name="kimi",
            home_url="https://www.kimi.com/",
            recover_pending_query=AsyncMock(
                return_value="https://www.kimi.com/chat/12345678-1234-1234-1234-123456789abc"
            ),
        )
        page = SimpleNamespace(url="about:blank")

        await worker._restore_page_from_pause("execution-1", plugin, page)

        plugin.recover_pending_query.assert_awaited_once_with(page, "second Kimi question")
        engine.bind_recovery_url.assert_called_once_with(
            "execution-1",
            "https://www.kimi.com/chat/12345678-1234-1234-1234-123456789abc",
        )


if __name__ == "__main__":
    unittest.main()
