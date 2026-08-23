import unittest

from geo_operator.browser.plugins.catalog import live_plugin
from geo_operator.browser.plugins.doubao import DoubaoPlugin


class _HydrationSignal:
    async def json_value(self) -> str:
        return "CONVERSATION_CONTENT"


class _HydrationPage:
    def __init__(self) -> None:
        self.expression = ""
        self.timeout = None

    async def wait_for_function(self, expression, *, timeout):
        self.expression = expression
        self.timeout = timeout
        return _HydrationSignal()


class DoubaoAdapterTestCase(unittest.TestCase):
    def test_catalog_uses_refreshed_doubao_adapter(self) -> None:
        plugin = live_plugin("doubao")

        self.assertIsInstance(plugin, DoubaoPlugin)
        self.assertEqual(plugin.observed_at, "2026-08-23")
        self.assertEqual(plugin.selectors.prompt_inputs[0], "textarea[data-testid='chat_input_input']")
        self.assertNotIn("textarea", plugin.selectors.prompt_inputs)
        self.assertIn("button[data-testid='to_login_button']", plugin.selectors.login_indicators)
        self.assertIn(
            "button[data-testid='chat_input_send_button']", plugin.selectors.send_controls
        )
        self.assertEqual(plugin.selectors.user_queries[0], "[data-testid='send_message']")
        self.assertEqual(plugin.selectors.responses[0], "[data-testid='receive_message']")
        self.assertTrue(plugin.calibration_complete)


class DoubaoAdapterAsyncTestCase(unittest.IsolatedAsyncioTestCase):
    async def test_current_message_nodes_are_conversation_hydration_signals(self) -> None:
        plugin = DoubaoPlugin()
        page = _HydrationPage()

        result = await plugin.wait_for_calibration_hydration(page)

        self.assertEqual(result, "CONVERSATION_CONTENT")
        self.assertIn("[data-testid='send_message']", page.expression)
        self.assertIn("[data-testid='receive_message']", page.expression)
        self.assertIn("[class*='message-list-'] .v_list_row", page.expression)
        self.assertEqual(page.timeout, 30_000)


if __name__ == "__main__":
    unittest.main()
