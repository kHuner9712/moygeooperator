from __future__ import annotations

import unittest
from urllib.parse import urlsplit

from geo_operator.browser.plugins.catalog import live_plugin, live_plugins
from geo_operator.platforms import (
    PLATFORM_DEFINITIONS,
    PROHIBITED_PLATFORM_IDS,
    REAL_PLATFORM_IDS,
    canonical_platform,
)

EXPECTED_PLATFORMS = {
    "doubao",
    "yuanbao",
    "qwen",
    "deepseek",
    "kimi",
    "grok",
    "gemini",
    "chatgpt",
    "perplexity",
}


class PlatformPolicyTestCase(unittest.TestCase):
    def test_required_platform_catalog_is_complete_and_uses_https(self) -> None:
        self.assertEqual(set(REAL_PLATFORM_IDS), EXPECTED_PLATFORMS)
        self.assertEqual(
            {definition.platform for definition in PLATFORM_DEFINITIONS},
            EXPECTED_PLATFORMS,
        )
        for definition in PLATFORM_DEFINITIONS:
            parsed = urlsplit(definition.home_url)
            self.assertEqual(parsed.scheme, "https")
            self.assertTrue(parsed.netloc)

    def test_external_labels_are_canonicalized(self) -> None:
        self.assertEqual(canonical_platform("ChatGPT"), "chatgpt")
        self.assertEqual(canonical_platform("豆包"), "doubao")
        self.assertEqual(canonical_platform("腾讯元宝"), "yuanbao")
        self.assertEqual(canonical_platform("千问"), "qwen")

    def test_claude_and_vendor_aliases_are_explicitly_prohibited(self) -> None:
        self.assertIn("claude", PROHIBITED_PLATFORM_IDS)
        for platform in (
            "claude",
            "Claude",
            "claude.ai",
            "claude-3.7-sonnet",
            "anthropic",
            "anthropic/claude",
        ):
            with (
                self.subTest(platform=platform),
                self.assertRaisesRegex(ValueError, "explicitly prohibited"),
            ):
                canonical_platform(platform)

    def test_every_real_platform_has_a_fail_closed_plugin(self) -> None:
        plugins = {plugin.name: plugin for plugin in live_plugins()}
        self.assertEqual(set(plugins), EXPECTED_PLATFORMS)
        self.assertTrue(plugins["chatgpt"].calibration_complete)
        self.assertTrue(plugins["doubao"].calibration_complete)
        self.assertTrue(plugins["deepseek"].calibration_complete)
        for platform in EXPECTED_PLATFORMS - {"chatgpt", "doubao", "deepseek"}:
            with self.subTest(platform=platform):
                plugin = live_plugin(platform)
                status = plugin.calibration_status()
                self.assertFalse(plugin.calibration_complete)
                self.assertEqual(status["support_status"], "CALIBRATION_REQUIRED")
                self.assertFalse(status["dispatch_eligible"])
                self.assertIn("send_controls", status["missing"])
                self.assertFalse(plugin.deletion_action_verified)

    def test_claude_has_no_plugin_factory(self) -> None:
        with self.assertRaisesRegex(ValueError, "explicitly prohibited"):
            live_plugin("Claude")


if __name__ == "__main__":
    unittest.main()
