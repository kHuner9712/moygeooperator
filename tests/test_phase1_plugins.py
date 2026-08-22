import unittest

from playwright.async_api import TimeoutError as PlaywrightTimeoutError

from geo_operator.browser.plugins.base import SideEffectNotAttempted
from geo_operator.browser.plugins.phase1 import ChatGPTPlugin, DoubaoPlugin


class _TransientPrompt:
    def __init__(self, *, fail: bool = False) -> None:
        self.fail = fail
        self.filled = None

    async def fill(self, value: str, *, timeout: int) -> None:
        if self.fail:
            raise PlaywrightTimeoutError("detached during page transition")
        self.filled = (value, timeout)


class _SendControl:
    def __init__(self) -> None:
        self.clicked = False

    async def click(self) -> None:
        self.clicked = True


class _RetryPage:
    def __init__(self) -> None:
        self.waits = []

    async def wait_for_timeout(self, milliseconds: int) -> None:
        self.waits.append(milliseconds)


class _RetryDoubaoPlugin(DoubaoPlugin):
    def __init__(self) -> None:
        self.prompts = [_TransientPrompt(fail=True), _TransientPrompt()]
        self.send = _SendControl()

    async def _unique_visible(self, page, selectors, label):
        if label == "prompt input":
            return self.prompts.pop(0)
        return self.send


class _CountLocator:
    def __init__(self, count: int) -> None:
        self.value = count

    async def count(self) -> int:
        return self.value


class _ObservationDoubaoPlugin(DoubaoPlugin):
    async def _any_visible(self, page, selectors) -> bool:
        return False

    async def _one_visible(self, page, selectors):
        return object()

    def _combined(self, page, selectors):
        if selectors == self.selectors.responses:
            return _CountLocator(0)
        if selectors == self.selectors.user_queries:
            return _CountLocator(1)
        raise AssertionError(f"unexpected selectors: {selectors}")


class _BodyLocator:
    async def inner_text(self) -> str:
        return "\u8bf7\u9009\u62e9\u6240\u6709\u7b26\u5408\u4e0a\u6587\u63cf\u8ff0\u7684\u56fe\u7247\uff0c\u5e76\u62d6\u62fd\u5230\u8fd9\u91cc"


class _BodyPage:
    def locator(self, selector: str):
        if selector != "body":
            raise AssertionError(selector)
        return _BodyLocator()


class _CaptchaDetectionPlugin(DoubaoPlugin):
    async def _any_visible(self, page, selectors) -> bool:
        return False


class PhaseOnePluginContractTestCase(unittest.TestCase):
    def test_doubao_calibration_contract_is_complete(self) -> None:
        plugin = DoubaoPlugin()
        self.assertTrue(plugin.response_capture_calibration_complete)
        self.assertTrue(plugin.deletion_calibration_complete)
        self.assertTrue(plugin.calibration_complete)
        self.assertEqual(plugin.calibration_status()["missing"], [])
        self.assertIn(
            "[class*='break-btn-']",
            plugin.selectors.stop_controls,
        )
        self.assertTrue(plugin.selectors.final_response_descendants)
        self.assertTrue(plugin.selectors.query_failure_descendants)
        self.assertIn(
            "text-s-color-alert",
            plugin.selectors.query_failure_descendants[0],
        )

    def test_doubao_normalizes_only_cjk_ascii_boundary_spacing(self) -> None:
        plugin = DoubaoPlugin()
        rendered = "\u8bf7\u4ece 1 \u5230 80 \u4e2d\u9009\u62e9 GEO Operator"
        prompt = "\u8bf7\u4ece1\u523080\u4e2d\u9009\u62e9 GEO Operator"
        self.assertEqual(plugin.normalize_query_text(rendered), plugin.normalize_query_text(prompt))
        self.assertIn("GEO Operator", plugin.normalize_query_text(rendered))

    def test_conversation_url_validation_is_platform_specific(self) -> None:
        chatgpt = ChatGPTPlugin()
        doubao = DoubaoPlugin()
        self.assertTrue(chatgpt.is_conversation_url("https://chatgpt.com/c/abc-123"))
        self.assertFalse(chatgpt.is_conversation_url("https://chatgpt.com/"))
        self.assertTrue(doubao.is_conversation_url("https://www.doubao.com/chat/38438488355395842"))
        self.assertFalse(doubao.is_conversation_url("https://www.doubao.com/chat/"))
        self.assertFalse(doubao.is_conversation_url("https://www.doubao.com/chat/not-numeric"))
        self.assertFalse(doubao.is_conversation_url("https://example.com/chat/38438488355395842"))

    def test_home_url_validation_rejects_credentials_and_foreign_origins(self) -> None:
        plugin = DoubaoPlugin()
        self.assertTrue(plugin.is_home_url("https://www.doubao.com/chat/"))
        self.assertFalse(plugin.is_home_url("https://www.doubao.com/chat/123"))
        self.assertFalse(plugin.is_home_url("https://user@example.com/chat/"))


class PhaseOnePluginAsyncTestCase(unittest.IsolatedAsyncioTestCase):
    async def test_send_query_reselects_prompt_after_transient_detach(self) -> None:
        plugin = _RetryDoubaoPlugin()
        page = _RetryPage()

        await plugin.send_query(page, "test prompt")

        self.assertEqual(page.waits, [250])
        self.assertEqual(plugin.prompts, [])
        self.assertTrue(plugin.send.clicked)

    async def test_send_query_classifies_pre_click_failure_as_not_attempted(self) -> None:
        plugin = _RetryDoubaoPlugin()
        plugin.prompts = [_TransientPrompt(fail=True) for _ in range(3)]
        page = _RetryPage()

        with self.assertRaises(SideEffectNotAttempted):
            await plugin.send_query(page, "test prompt")

        self.assertEqual(page.waits, [250, 250])
        self.assertFalse(plugin.send.clicked)

    async def test_missing_response_after_confirmed_query_remains_incomplete(self) -> None:
        observation = await _ObservationDoubaoPlugin().observe_response(object())

        self.assertEqual(observation.response_text, "")
        self.assertFalse(observation.response_text_stable)
        self.assertFalse(observation.final_response_element_present)
        self.assertFalse(observation.complete)

    async def test_doubao_drag_image_challenge_is_classified_as_captcha(self) -> None:
        reason = await _CaptchaDetectionPlugin().detect_human_intervention(_BodyPage())

        self.assertEqual(reason, "CAPTCHA")


if __name__ == "__main__":
    unittest.main()
