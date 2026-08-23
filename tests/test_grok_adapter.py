import unittest

from geo_operator.browser.plugins.catalog import live_plugin
from geo_operator.browser.plugins.grok import GrokPlugin


class _BodyLocator:
    def __init__(self, text: str) -> None:
        self.text = text

    async def inner_text(self) -> str:
        return self.text


class _Page:
    def __init__(self, text: str) -> None:
        self.text = text

    def locator(self, selector: str):
        if selector != "body":
            raise AssertionError(f"unexpected selector: {selector}")
        return _BodyLocator(self.text)


class GrokAdapterTestCase(unittest.TestCase):
    def test_catalog_uses_edge_block_aware_grok_adapter(self) -> None:
        plugin = live_plugin("grok")
        self.assertIsInstance(plugin, GrokPlugin)
        self.assertEqual(plugin.observed_at, "2026-08-24")


class GrokEdgeBlockDetectionTestCase(unittest.IsolatedAsyncioTestCase):
    async def test_detects_english_xai_block_page(self) -> None:
        plugin = GrokPlugin()
        page = _Page("Sorry, you have been blocked. You are unable to access x.ai")
        self.assertEqual(await plugin.detect_human_intervention(page), "SECURITY_CHALLENGE")

    async def test_detects_chinese_xai_block_page(self) -> None:
        plugin = GrokPlugin()
        page = _Page("抱歉，您已被屏蔽。您无法访问 x.ai")
        self.assertEqual(await plugin.detect_human_intervention(page), "SECURITY_CHALLENGE")


if __name__ == "__main__":
    unittest.main()
