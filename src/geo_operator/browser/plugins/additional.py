from __future__ import annotations

from urllib.parse import urlsplit

from playwright.async_api import TimeoutError as PlaywrightTimeoutError

from geo_operator.browser.plugins.phase1 import (
    ObservedWebChatPlugin,
    PhaseOneSelectors,
    PluginPageAbnormal,
)


class CalibrationPendingPlugin(ObservedWebChatPlugin):
    """Safe onboarding shell for a platform that still needs authenticated DOM calibration."""

    observed_at = None
    deletion_action_verified = False

    def calibration_status(self) -> dict[str, object]:
        status = super().calibration_status()
        status["support_status"] = "CALIBRATION_REQUIRED"
        status["dispatch_eligible"] = False
        return status


class DeepSeekPlugin(ObservedWebChatPlugin):
    phase = 2
    name = "deepseek"
    observed_at = "2026-08-23"
    deletion_action_verified = True
    home_url = "https://chat.deepseek.com/"
    conversation_link_selectors = ("a[href*='/a/chat/s/']",)
    conversation_path_prefixes = ("/a/chat/s/",)
    selectors = PhaseOneSelectors(
        login_indicators=("button:has-text('登录')", "button:has-text('Log in')"),
        prompt_inputs=("textarea#chat-input", "textarea", "[contenteditable='true']"),
        send_controls=(
            "div.ds-button.ds-button--primary.ds-button--filled.ds-button--circle",
        ),
        user_queries=(
            "div.ds-message:not(:has(.ds-assistant-message-main-content))",
        ),
        responses=(".ds-markdown.ds-assistant-message-main-content",),
        streaming_indicators=(".ds-loading",),
        stop_controls=(
            "div.ds-button.ds-button--primary.ds-button--circle:has(.ds-loading)",
        ),
        conversation_menu_controls=("a[href*='/a/chat/s/']",),
        delete_controls=(".ds-dropdown-menu-option--error",),
        delete_confirm_controls=(
            ".ds-modal-content[role='dialog'] .ds-button--error.ds-button--filled",
        ),
    )

    async def delete_chat(self, page: object) -> None:
        if not self.is_conversation_url(page.url):
            raise PluginPageAbnormal("DeepSeek delete requires a conversation URL")
        path = urlsplit(page.url).path
        self._deleting_conversation_path = path
        conversation = page.locator(f"a[href='{path}']")
        try:
            await conversation.first.wait_for(state="visible", timeout=10_000)
        except PlaywrightTimeoutError as exc:
            raise PluginPageAbnormal(
                "DeepSeek conversation item did not become visible"
            ) from exc
        if await conversation.count() != 1:
            raise PluginPageAbnormal("DeepSeek conversation item is not unique")
        await conversation.hover()
        menu_candidates = conversation.locator("xpath=..").locator("div[role='button']")
        visible_menus = [
            menu_candidates.nth(index)
            for index in range(await menu_candidates.count())
            if await menu_candidates.nth(index).is_visible()
        ]
        if len(visible_menus) != 1:
            raise PluginPageAbnormal("DeepSeek conversation menu is not uniquely visible")
        await visible_menus[0].click()
        delete = page.locator(".ds-dropdown-menu-option--error")
        try:
            await delete.wait_for(state="visible", timeout=5_000)
        except PlaywrightTimeoutError as exc:
            raise PluginPageAbnormal("DeepSeek delete item did not become visible") from exc
        if await delete.count() != 1:
            raise PluginPageAbnormal("DeepSeek delete item is not unique")
        await delete.click()
        confirm = page.locator(
            ".ds-modal-content[role='dialog'] .ds-button--error.ds-button--filled"
        )
        try:
            await confirm.wait_for(state="visible", timeout=5_000)
        except PlaywrightTimeoutError as exc:
            raise PluginPageAbnormal("DeepSeek delete confirmation did not appear") from exc
        if await confirm.count() != 1:
            raise PluginPageAbnormal("DeepSeek delete confirmation is not unique")
        await confirm.click()

    async def verify_chat_deleted(self, page: object) -> bool:
        path = getattr(self, "_deleting_conversation_path", None)
        if not isinstance(path, str) or not path.startswith("/a/chat/s/"):
            return False
        if not self.is_home_url(page.url) or not await self.detect_login(page):
            return False
        return await page.locator(f"a[href='{path}']").count() == 0


class QwenPlugin(CalibrationPendingPlugin):
    phase = 2
    name = "qwen"
    home_url = "https://www.qianwen.com/"
    observed_at = "2026-08-23"
    conversation_link_selectors = ("a[href*='/chat/']",)
    conversation_path_prefixes = ("/chat/",)
    selectors = PhaseOneSelectors(
        login_indicators=("button:has-text('Log in')", "button:has-text('登录')"),
        prompt_inputs=("textarea", "[contenteditable='true'][role='textbox']"),
        send_controls=("button[class*='size-8'][class*='bg-black-button']",),
        user_queries=(".message-card-wrap.question .question-text-card",),
        responses=(".chat-answers-card-wrap .answer-text.md-text-card",),
        streaming_indicators=(
            "#qk-markdown-react.qk-markdown:not(.qk-markdown-complete)",
            ".chat-answers-card-wrap [class*='loading-']",
        ),
        error_indicators=(
            ".answer-text.md-text-card:has-text('系统超时')",
            ".answer-text.md-text-card:has-text('请稍后重试')",
        ),
        final_response_descendants=(
            "#qk-markdown-react.qk-markdown-complete",
        ),
    )

    def is_conversation_url(self, value: str) -> bool:
        if not super().is_conversation_url(value):
            return False
        conversation_id = urlsplit(value).path.removeprefix("/chat/").strip("/")
        return len(conversation_id) == 32 and all(
            character in "0123456789abcdef" for character in conversation_id.lower()
        )


class GeminiPlugin(CalibrationPendingPlugin):
    phase = 2
    name = "gemini"
    home_url = "https://gemini.google.com/app"
    conversation_link_selectors = ("a[href^='/app/']",)
    conversation_path_prefixes = ("/app/",)
    selectors = PhaseOneSelectors(
        login_indicators=("a:has-text('Sign in')", "button:has-text('Sign in')"),
        prompt_inputs=(
            "rich-textarea [contenteditable='true']",
            "div.ql-editor[contenteditable='true']",
        ),
        send_controls=(),
    )


class YuanbaoPlugin(CalibrationPendingPlugin):
    phase = 3
    name = "yuanbao"
    home_url = "https://yuanbao.tencent.com/chat/"
    conversation_link_selectors = ("a[href*='/chat/']",)
    conversation_path_prefixes = ("/chat/",)
    selectors = PhaseOneSelectors(
        login_indicators=("button:has-text('登录')",),
        prompt_inputs=("textarea", "[contenteditable='true'][role='textbox']"),
        send_controls=(),
    )


class KimiPlugin(CalibrationPendingPlugin):
    phase = 3
    name = "kimi"
    home_url = "https://www.kimi.com/"
    conversation_link_selectors = ("a[href*='/chat/']",)
    conversation_path_prefixes = ("/chat/",)
    selectors = PhaseOneSelectors(
        login_indicators=("button:has-text('登录')", "button:has-text('Log in')"),
        prompt_inputs=("[contenteditable='true'][role='textbox']", "textarea"),
        send_controls=(),
    )


class GrokPlugin(CalibrationPendingPlugin):
    phase = 3
    name = "grok"
    home_url = "https://grok.com/"
    conversation_link_selectors = ("a[href*='/c/']",)
    conversation_path_prefixes = ("/c/",)
    selectors = PhaseOneSelectors(
        login_indicators=("button:has-text('Sign in')", "a:has-text('Sign in')"),
        prompt_inputs=("textarea", "[contenteditable='true'][role='textbox']"),
        send_controls=(),
    )


class PerplexityPlugin(CalibrationPendingPlugin):
    phase = 3
    name = "perplexity"
    home_url = "https://www.perplexity.ai/"
    conversation_link_selectors = ("a[href*='/search/']",)
    conversation_path_prefixes = ("/search/",)
    selectors = PhaseOneSelectors(
        login_indicators=("button:has-text('Sign in')", "button:has-text('Log in')"),
        prompt_inputs=("textarea", "[contenteditable='true'][role='textbox']"),
        send_controls=(),
    )
