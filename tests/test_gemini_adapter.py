import unittest

from geo_operator.browser.plugins.catalog import live_plugin
from geo_operator.browser.plugins.gemini import GeminiPlugin


class _TextNode:
    def __init__(self, text: str) -> None:
        self.text = text

    async def inner_text(self) -> str:
        return self.text


class _Locator:
    def __init__(self, nodes: list[_TextNode]) -> None:
        self.nodes = nodes

    async def count(self) -> int:
        return len(self.nodes)

    def nth(self, index: int) -> _TextNode:
        return self.nodes[index]


class _Page:
    def __init__(self, mapping: dict[str, list[_TextNode]]) -> None:
        self.mapping = mapping

    def locator(self, selector: str) -> _Locator:
        return _Locator(self.mapping.get(selector, []))


class GeminiAdapterTestCase(unittest.TestCase):
    def test_catalog_uses_refreshed_gemini_adapter(self) -> None:
        plugin = live_plugin("gemini")

        self.assertIsInstance(plugin, GeminiPlugin)
        self.assertEqual(plugin.observed_at, "2026-08-23")
        self.assertIn("model-response message-content", plugin.selectors.responses[0])
        self.assertIn("[aria-busy='true']", plugin.selectors.streaming_indicators)
        self.assertIn("button[aria-label*='Stop' i]", plugin.selectors.stop_controls)
        self.assertTrue(plugin.calibration_complete)

    def test_query_normalization_removes_gemini_speaker_heading(self) -> None:
        plugin = GeminiPlugin()

        self.assertEqual(plugin.normalize_query_text("You said: Hello world"), "Hello world")
        self.assertEqual(plugin.normalize_query_text("你说： 你好 世界"), "你好 世界")


class GeminiAdapterAsyncTestCase(unittest.IsolatedAsyncioTestCase):
    async def test_query_exists_accepts_current_query_text_with_speaker_heading(self) -> None:
        plugin = GeminiPlugin()
        selector = "user-query .query-text"
        page = _Page({selector: [_TextNode("You said: What is KZQ Decor?")]})

        exists = await plugin.query_exists(page, "What is KZQ Decor?")

        self.assertTrue(exists)


if __name__ == "__main__":
    unittest.main()
