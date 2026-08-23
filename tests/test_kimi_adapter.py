import unittest

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


if __name__ == "__main__":
    unittest.main()
