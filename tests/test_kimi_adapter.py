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
        self.assertIn(
            "div.chat-input-editor[contenteditable='true']",
            plugin.selectors.prompt_inputs,
        )
        self.assertEqual(
            plugin.selectors.send_controls[0],
            "div.send-button-container:not(.disabled):not(.stop):not(.loading)",
        )
        self.assertNotIn(
            ".send-button-container:not(.disabled):not(.loading)",
            plugin.selectors.send_controls,
        )
        self.assertIn("div.send-button-container.stop", plugin.selectors.streaming_indicators)
        self.assertIn("div.send-button-container.stop", plugin.selectors.stop_controls)
        self.assertTrue(plugin.calibration_complete)


class KimiDroppedSendRecoveryTestCase(unittest.IsolatedAsyncioTestCase):
    async def test_exact_prompt_retained_in_idle_composer_retries_once(self) -> None:
        plugin = KimiPlugin()
        page = SimpleNamespace(url="https://www.kimi.com/")
        prompt = "Which suppliers should I contact?"
        composer = SimpleNamespace(inner_text=AsyncMock(return_value=prompt))
        retry_send = SimpleNamespace(click=AsyncMock())

        plugin.query_exists = AsyncMock(return_value=False)
        plugin._any_visible = AsyncMock(return_value=False)
        plugin._one_visible = AsyncMock(return_value=composer)
        plugin._unique_visible = AsyncMock(return_value=retry_send)

        with (
            patch(
                "geo_operator.browser.plugins.phase1.ObservedWebChatPlugin.send_query",
                new=AsyncMock(),
            ) as first_send,
            patch(
                "geo_operator.browser.plugins.kimi.time.monotonic",
                side_effect=[0.0, 6.0],
            ),
        ):
            await plugin.send_query(page, prompt)

        first_send.assert_awaited_once_with(page, prompt)
        retry_send.click.assert_awaited_once_with()

    async def test_routed_conversation_never_retries(self) -> None:
        plugin = KimiPlugin()
        page = SimpleNamespace(url="https://www.kimi.com/chat/12345678-1234-1234-1234-123456789abc")
        retry_send = SimpleNamespace(click=AsyncMock())

        plugin.query_exists = AsyncMock(return_value=False)
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
