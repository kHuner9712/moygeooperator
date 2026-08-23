import unittest

from geo_operator.browser.plugins.catalog import live_plugin
from geo_operator.browser.plugins.doubao import DoubaoPlugin
from geo_operator.browser.plugins.phase1 import DoubaoPlugin as PhaseOneDoubaoPlugin


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
        self.assertEqual(plugin.selectors.user_queries, PhaseOneDoubaoPlugin.selectors.user_queries)
        self.assertEqual(plugin.selectors.responses, PhaseOneDoubaoPlugin.selectors.responses)
        self.assertTrue(plugin.calibration_complete)


if __name__ == "__main__":
    unittest.main()
