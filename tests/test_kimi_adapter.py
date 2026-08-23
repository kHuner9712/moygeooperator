import inspect
import unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

from geo_operator.browser.plugins.catalog import live_plugin
from geo_operator.browser.plugins.kimi import KimiPlugin


class KimiAdapterTestCase(unittest.TestCase):
    def test_catalog_uses_refreshed_kimi_adapter(self) -> None:
        plugin = live_plugin("kimi")

        self.assertIsInstance(plugin, KimiPlugin)
        self.assertEqual(plugin.observed_at, "2026-08-23")
        self.assertEqual(
            plugin.selectors.prompt_inputs[0],
            "div.chat-input-editor[role='textbox'][contenteditable='true']",
        )
        self.assertEqual(plugin.selectors.send_controls[0], "svg[name='Send']")
        self.assertIn("chat-content-item-user", plugin.selectors.user_queries[0])
        self.assertIn("segment-user", plugin.selectors.user_queries[0])
        self.assertIn("svg[name='Stop']", plugin.selectors.stop_controls)
        self.assertTrue(plugin.calibration_complete)

    def test_history_recovery_uses_kimi_history_entry_parameter(self) -> None:
        source = inspect.getsource(KimiPlugin.recover_pending_query)

        self.assertIn('query="chat_enter_method=history"', source)
        self.assertIn("timeout=15_000", source)
        self.assertIn("a[href*='/chat/']", source)


class KimiPlatformEntryTestCase(unittest.IsolatedAsyncioTestCase):
    async def test_open_platform_forces_fresh_new_chat_from_existing_conversation(self) -> None:
        plugin = KimiPlugin()
        page = SimpleNamespace(
            url="https://www.kimi.com/chat/12345678-1234-1234-1234-123456789abc",
            goto=AsyncMock(),
            reload=AsyncMock(),
        )
        plugin._any_visible = AsyncMock(return_value=False)
        plugin._one_visible = AsyncMock(return_value=object())

        await plugin.open_platform(page)

        page.goto.assert_awaited_once_with(
            "https://www.kimi.com/?chat_enter_method=new_chat",
            wait_until="domcontentloaded",
        )
        page.reload.assert_not_awaited()


class KimiDroppedSendRecoveryTestCase(unittest.IsolatedAsyncioTestCase):
    async def test_idle_exact_prompt_retries_once_without_new_user_turn(self) -> None:
        plugin = KimiPlugin()
        page = SimpleNamespace(url="https://www.kimi.com/")
        prompt = "Which suppliers should I contact?"
        composer = SimpleNamespace(inner_text=AsyncMock(return_value=prompt))
        retry_send = SimpleNamespace(click=AsyncMock())

        plugin._query_match_count = AsyncMock(return_value=0)
        plugin._wait_for_new_user_turn = AsyncMock(side_effect=[False, True])
        plugin._any_visible = AsyncMock(return_value=False)
        plugin._one_visible = AsyncMock(return_value=composer)
        plugin._unique_visible = AsyncMock(return_value=retry_send)

        with patch(
            "geo_operator.browser.plugins.phase1.ObservedWebChatPlugin.send_query",
            new=AsyncMock(),
        ) as first_send:
            await plugin.send_query(page, prompt)

        first_send.assert_awaited_once_with(page, prompt)
        retry_send.click.assert_awaited_once_with()
        self.assertEqual(plugin._wait_for_new_user_turn.await_count, 2)

    async def test_rendered_new_user_turn_prevents_retry(self) -> None:
        plugin = KimiPlugin()
        page = SimpleNamespace(url="https://www.kimi.com/")
        retry_send = SimpleNamespace(click=AsyncMock())

        plugin._query_match_count = AsyncMock(return_value=0)
        plugin._wait_for_new_user_turn = AsyncMock(return_value=True)
        plugin._unique_visible = AsyncMock(return_value=retry_send)

        with patch(
            "geo_operator.browser.plugins.phase1.ObservedWebChatPlugin.send_query",
            new=AsyncMock(),
        ) as first_send:
            await plugin.send_query(page, "prompt")

        first_send.assert_awaited_once_with(page, "prompt")
        retry_send.click.assert_not_awaited()


if __name__ == "__main__":
    unittest.main()
