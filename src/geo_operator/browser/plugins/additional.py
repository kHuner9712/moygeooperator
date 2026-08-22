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
        send_controls=("div.ds-button.ds-button--primary.ds-button--filled.ds-button--circle",),
        user_queries=("div.ds-message:not(:has(.ds-assistant-message-main-content))",),
        responses=(".ds-markdown.ds-assistant-message-main-content",),
        streaming_indicators=(".ds-loading",),
        stop_controls=("div.ds-button.ds-button--primary.ds-button--circle:has(.ds-loading)",),
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
            raise PluginPageAbnormal("DeepSeek conversation item did not become visible") from exc
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
        final_response_descendants=("#qk-markdown-react.qk-markdown-complete",),
    )

    def is_conversation_url(self, value: str) -> bool:
        if not super().is_conversation_url(value):
            return False
        conversation_id = urlsplit(value).path.removeprefix("/chat/").strip("/")
        return len(conversation_id) == 32 and all(
            character in "0123456789abcdef" for character in conversation_id.lower()
        )


class GeminiPlugin(ObservedWebChatPlugin):
    phase = 2
    name = "gemini"
    observed_at = "2026-08-23"
    deletion_action_verified = True
    home_url = "https://gemini.google.com/app"
    conversation_link_selectors = ("a[href^='/app/']",)
    conversation_path_prefixes = ("/app/",)
    selectors = PhaseOneSelectors(
        login_indicators=("a:has-text('Sign in')", "button:has-text('Sign in')"),
        prompt_inputs=(
            "div.ql-editor[contenteditable='true'][role='textbox']",
            "rich-textarea [contenteditable='true']",
            "div.ql-editor[contenteditable='true']",
        ),
        send_controls=(
            "input-container .send-button button",
            "input-container button[aria-label='发送']",
        ),
        user_queries=("user-query-content .query-text",),
        responses=(
            "structured-content-container.model-response-text .markdown.markdown-main-panel",
        ),
        streaming_indicators=(
            "pending-response",
            "input-container .send-button.stop button[aria-label='停止回答']",
        ),
        stop_controls=("input-container .send-button.stop button[aria-label='停止回答']",),
        conversation_menu_controls=("conversation-actions-icon button",),
        delete_controls=("[role='menuitem']:has-text('删除')",),
        delete_confirm_controls=("[role='dialog'] button:has-text('删除')",),
    )

    def is_conversation_url(self, value: str) -> bool:
        if not super().is_conversation_url(value):
            return False
        conversation_id = urlsplit(value).path.removeprefix("/app/").strip("/")
        return len(conversation_id) == 16 and all(
            character in "0123456789abcdef" for character in conversation_id.lower()
        )

    async def delete_chat(self, page: object) -> None:
        if not self.is_conversation_url(page.url):
            raise PluginPageAbnormal("Gemini delete requires a conversation URL")
        self._deleting_conversation_path = urlsplit(page.url).path
        await super().delete_chat(page)

    async def verify_chat_deleted(self, page: object) -> bool:
        path = getattr(self, "_deleting_conversation_path", None)
        if not isinstance(path, str) or not path.startswith("/app/"):
            return False
        if not await super().verify_chat_deleted(page):
            return False
        return await page.locator(f"a[href='{path}']").count() == 0


class YuanbaoPlugin(ObservedWebChatPlugin):
    phase = 3
    name = "yuanbao"
    observed_at = "2026-08-23"
    deletion_action_verified = True
    home_url = "https://yuanbao.tencent.com/chat/"
    conversation_link_selectors = (".yb-recent-conv-list__item",)
    conversation_path_prefixes = ("/chat/",)
    selectors = PhaseOneSelectors(
        login_indicators=("button:has-text('登录')",),
        prompt_inputs=(".agent-chat__input-box .ql-editor[contenteditable='true']",),
        send_controls=("a#yuanbao-send-btn[aria-label='发送']",),
        user_queries=(".agent-chat__bubble--human .hyc-component-text",),
        responses=(".agent-chat__list__item--ai .hyc-content-md",),
        streaming_indicators=(
            ".agent-chat__list__item--ai .hyc-content-md:not(.hyc-content-md-done)",
            (".agent-dialogue__content--common:not(.agent-dialogue__content--common-not-speaking)"),
        ),
        stop_controls=(
            ".agent-chat__input-box a[class*='style__send-btn']:not(#yuanbao-send-btn)",
        ),
        conversation_menu_controls=(
            ".yb-recent-conv-list__item.active .yb-recent-conv-list__dropdown-trigger",
        ),
        delete_controls=(".yb-dropdown__item:has(.icon-yb-ic_delete_20)",),
        delete_confirm_controls=(
            (
                ".t-dialog__ctx.t-dialog__modal .t-dialog__footer "
                "button.t-button--theme-danger:has-text('确认删除')"
            ),
        ),
    )

    @staticmethod
    def _valid_path_token(value: str) -> bool:
        return 6 <= len(value) <= 64 and all(
            character.isalnum() or character in "-_" for character in value
        )

    def is_conversation_url(self, value: str) -> bool:
        target = urlsplit(value)
        home = urlsplit(self.home_url)
        parts = target.path.strip("/").split("/")
        return (
            target.scheme == "https"
            and target.netloc == home.netloc
            and not target.username
            and not target.password
            and len(parts) == 3
            and parts[0] == "chat"
            and self._valid_path_token(parts[1])
            and self._valid_path_token(parts[2])
        )

    def is_home_url(self, value: str) -> bool:
        target = urlsplit(value)
        home = urlsplit(self.home_url)
        parts = target.path.strip("/").split("/")
        return (
            target.scheme == "https"
            and target.netloc == home.netloc
            and not target.username
            and not target.password
            and 1 <= len(parts) <= 2
            and parts[0] == "chat"
            and (len(parts) == 1 or self._valid_path_token(parts[1]))
        )

    async def wait_for_calibration_hydration(self, page: object) -> str:
        if self.is_home_url(page.url):
            return await self.wait_for_home_hydration(page)
        return await super().wait_for_calibration_hydration(page)

    async def delete_chat(self, page: object) -> None:
        if not self.is_conversation_url(page.url):
            raise PluginPageAbnormal("Yuanbao delete requires a conversation URL")
        self._deleting_conversation_url = page.url
        items = page.locator(".yb-recent-conv-list__item")
        self._history_count_before_delete = await items.count()
        active = page.locator(".yb-recent-conv-list__item.active")
        try:
            await active.wait_for(state="visible", timeout=10_000)
        except PlaywrightTimeoutError as exc:
            raise PluginPageAbnormal(
                "Yuanbao active conversation item did not become visible"
            ) from exc
        if await active.count() != 1:
            raise PluginPageAbnormal("Yuanbao active conversation item is not unique")
        await active.hover()
        menu = active.locator(".yb-recent-conv-list__dropdown-trigger")
        if await menu.count() != 1 or not await menu.is_visible():
            raise PluginPageAbnormal("Yuanbao conversation menu is not uniquely visible")
        await menu.click()
        delete = page.locator(".yb-dropdown__item:has(.icon-yb-ic_delete_20)")
        try:
            await delete.wait_for(state="visible", timeout=5_000)
        except PlaywrightTimeoutError as exc:
            raise PluginPageAbnormal("Yuanbao delete item did not become visible") from exc
        if await delete.count() != 1:
            raise PluginPageAbnormal("Yuanbao delete item is not unique")
        await delete.click()
        confirm = page.locator(
            ".t-dialog__ctx.t-dialog__modal .t-dialog__footer "
            "button.t-button--theme-danger:has-text('确认删除')"
        )
        try:
            await confirm.wait_for(state="visible", timeout=5_000)
        except PlaywrightTimeoutError as exc:
            raise PluginPageAbnormal("Yuanbao delete confirmation did not appear") from exc
        if await confirm.count() != 1:
            raise PluginPageAbnormal("Yuanbao delete confirmation is not unique")
        await confirm.click()

    async def verify_chat_deleted(self, page: object) -> bool:
        if not await self.detect_login(page):
            return False
        target = getattr(self, "_deleting_conversation_url", None)
        if isinstance(target, str):
            current = urlsplit(page.url)._replace(query="", fragment="").geturl()
            expected = urlsplit(target)._replace(query="", fragment="").geturl()
            if current == expected:
                return False
            before = getattr(self, "_history_count_before_delete", None)
            if isinstance(before, int):
                current_count = await page.locator(".yb-recent-conv-list__item").count()
                if current_count < before:
                    return True
            return self.is_home_url(page.url) or self.is_conversation_url(page.url)
        return self.is_home_url(page.url) and not await self._any_visible(
            page, self.selectors.user_queries
        )


class KimiPlugin(ObservedWebChatPlugin):
    phase = 3
    name = "kimi"
    observed_at = "2026-08-23"
    deletion_action_verified = True
    home_url = "https://www.kimi.com/"
    conversation_link_selectors = (".next-sidebar-history-item__link[href^='/chat/']",)
    conversation_path_prefixes = ("/chat/",)
    selectors = PhaseOneSelectors(
        login_indicators=("button:has-text('登录')", "button:has-text('Log in')"),
        prompt_inputs=(".chat-input-editor[role='textbox'][contenteditable='true']",),
        send_controls=(".send-button-container:not(.disabled):not(.loading)",),
        user_queries=(".chat-content-item-user .user-content",),
        responses=(".chat-content-item-assistant .segment-content-box > .markdown-container",),
        streaming_indicators=(".send-button-container.loading",),
        stop_controls=(".send-button-container.loading",),
        conversation_menu_controls=(
            (
                ".next-sidebar-history-item.is-active "
                "button.next-sidebar-history-item__more[aria-label='更多']"
            ),
        ),
        delete_controls=("button.next-sidebar-history-item__menu-item.is-delete",),
        delete_confirm_controls=(
            ".modal-mask .modal-container .bottom button.km-button-danger:has-text('删除')",
        ),
        final_response_descendants=(
            (
                "xpath=ancestor::*[contains(concat(' ', normalize-space(@class), ' '), "
                "' segment-content ')][1]//*[contains(concat(' ', normalize-space(@class), "
                "' '), ' segment-assistant-actions ')]"
            ),
        ),
    )

    def is_conversation_url(self, value: str) -> bool:
        if not super().is_conversation_url(value):
            return False
        conversation_id = urlsplit(value).path.removeprefix("/chat/").strip("/")
        groups = conversation_id.split("-")
        return [len(group) for group in groups] == [8, 4, 4, 4, 12] and all(
            character in "0123456789abcdef" for group in groups for character in group.lower()
        )

    async def _expose_history_item(self, page: object, item: object, path: str) -> None:
        left = await item.evaluate("node => node.getBoundingClientRect().left")
        if left < 0:
            opener = page.locator(".sidebar-main-trigger__button[aria-label='展开导航']")
            if await opener.count() != 1 or not await opener.is_visible():
                raise PluginPageAbnormal("Kimi sidebar opener is not uniquely visible")
            await opener.click()
            try:
                await page.wait_for_function(
                    """path => {
                      const link = document.querySelector(`a[href^="${path}"]`);
                      return Boolean(link && link.closest('.next-sidebar-history-item')
                        .getBoundingClientRect().left >= 0);
                    }""",
                    arg=path,
                    timeout=10_000,
                )
            except PlaywrightTimeoutError as exc:
                raise PluginPageAbnormal("Kimi sidebar did not expand") from exc
        await item.scroll_into_view_if_needed(timeout=10_000)

    async def delete_chat(self, page: object) -> None:
        if not self.is_conversation_url(page.url):
            raise PluginPageAbnormal("Kimi delete requires a conversation URL")
        path = urlsplit(page.url).path
        self._deleting_conversation_path = path
        items = page.locator(".next-sidebar-history-item")
        self._history_count_before_delete = await items.count()
        item = page.locator(f".next-sidebar-history-item:has(a[href^='{path}'])")
        try:
            await item.wait_for(state="attached", timeout=10_000)
        except PlaywrightTimeoutError as exc:
            raise PluginPageAbnormal("Kimi conversation item did not hydrate") from exc
        if await item.count() != 1:
            raise PluginPageAbnormal("Kimi conversation item is not unique")
        await self._expose_history_item(page, item, path)
        await item.hover()
        menu = item.locator("button.next-sidebar-history-item__more[aria-label='更多']")
        if await menu.count() != 1 or not await menu.is_visible():
            raise PluginPageAbnormal("Kimi conversation menu is not uniquely visible")
        await menu.click()
        delete = page.locator("button.next-sidebar-history-item__menu-item.is-delete")
        try:
            await delete.wait_for(state="visible", timeout=5_000)
        except PlaywrightTimeoutError as exc:
            raise PluginPageAbnormal("Kimi delete item did not become visible") from exc
        if await delete.count() != 1:
            raise PluginPageAbnormal("Kimi delete item is not unique")
        await delete.click()
        confirm = page.locator(
            ".modal-mask .modal-container .bottom button.km-button-danger:has-text('删除')"
        )
        try:
            await confirm.wait_for(state="visible", timeout=5_000)
        except PlaywrightTimeoutError as exc:
            raise PluginPageAbnormal("Kimi delete confirmation did not appear") from exc
        if await confirm.count() != 1:
            raise PluginPageAbnormal("Kimi delete confirmation is not unique")
        await confirm.click()

    async def verify_chat_deleted(self, page: object) -> bool:
        if not await self.detect_login(page):
            return False
        path = getattr(self, "_deleting_conversation_path", None)
        if isinstance(path, str):
            if urlsplit(page.url).path == path:
                return False
            if await page.locator(f"a[href^='{path}']").count():
                return False
            before = getattr(self, "_history_count_before_delete", None)
            if isinstance(before, int):
                after = await page.locator(".next-sidebar-history-item").count()
                if after < before:
                    return True
            return self.is_home_url(page.url) or self.is_conversation_url(page.url)
        return self.is_home_url(page.url) and not await self._any_visible(
            page, self.selectors.user_queries
        )


class GrokPlugin(ObservedWebChatPlugin):
    phase = 3
    name = "grok"
    observed_at = "2026-08-23"
    deletion_action_verified = True
    delete_requires_confirmation = False
    home_url = "https://grok.com/"
    conversation_link_selectors = ("a[href^='/c/']",)
    conversation_path_prefixes = ("/c/",)
    selectors = PhaseOneSelectors(
        login_indicators=("button:has-text('Sign in')", "a:has-text('Sign in')"),
        prompt_inputs=(
            ".query-bar-editor[role='textbox'][contenteditable='true'][aria-label='Ask Grok anything']",
        ),
        send_controls=("button[data-testid='chat-submit'][aria-label='提交']",),
        user_queries=("[data-testid='user-message']",),
        responses=("[data-testid='assistant-message']",),
        streaming_indicators=("button[aria-label='\u505c\u6b62\u6a21\u578b\u54cd\u5e94']",),
        stop_controls=("button[aria-label='\u505c\u6b62\u6a21\u578b\u54cd\u5e94']",),
        conversation_menu_controls=(
            "button[aria-label='\u5907\u9009\u65b9\u6848'][aria-haspopup='menu']",
        ),
        delete_controls=("[role='menuitem']:has-text('\u5220\u9664')",),
        final_response_descendants=(
            (
                "xpath=ancestor::*[starts-with(@id,'response-')][1]"
                "//*[contains(@class,'action-buttons') and contains(@class,'last-response')]"
            ),
        ),
    )

    def is_conversation_url(self, value: str) -> bool:
        if not super().is_conversation_url(value):
            return False
        conversation_id = urlsplit(value).path.removeprefix("/c/").strip("/")
        groups = conversation_id.split("-")
        return [len(group) for group in groups] == [8, 4, 4, 4, 12] and all(
            character in "0123456789abcdef" for group in groups for character in group.lower()
        )

    async def delete_chat(self, page: object) -> None:
        if not self.is_conversation_url(page.url):
            raise PluginPageAbnormal("Grok delete requires a conversation URL")
        path = urlsplit(page.url).path
        self._deleting_conversation_path = path
        link = page.locator(f"a[href='{path}']")
        try:
            await link.wait_for(state="attached", timeout=10_000)
        except PlaywrightTimeoutError as exc:
            raise PluginPageAbnormal("Grok conversation item did not hydrate") from exc
        if await link.count() != 1:
            raise PluginPageAbnormal("Grok conversation item is not unique")
        item = link.locator("xpath=ancestor::li[contains(@class,'group/menu-item')][1]")
        if await item.count() != 1:
            raise PluginPageAbnormal("Grok conversation container is not unique")
        await item.scroll_into_view_if_needed(timeout=10_000)
        await item.hover()
        menu = item.locator("button[aria-label='\u5907\u9009\u65b9\u6848'][aria-haspopup='menu']")
        if await menu.count() != 1 or not await menu.is_visible():
            raise PluginPageAbnormal("Grok conversation menu is not uniquely visible")
        await menu.click()
        delete = page.get_by_role("menuitem", name="\u5220\u9664", exact=True)
        try:
            await delete.wait_for(state="visible", timeout=5_000)
        except PlaywrightTimeoutError as exc:
            raise PluginPageAbnormal("Grok delete item did not become visible") from exc
        if await delete.count() != 1:
            raise PluginPageAbnormal("Grok delete item is not unique")
        await delete.click()

    async def verify_chat_deleted(self, page: object) -> bool:
        path = getattr(self, "_deleting_conversation_path", None)
        if not isinstance(path, str) or not path.startswith("/c/"):
            return False
        if not await self.detect_login(page) or urlsplit(page.url).path == path:
            return False
        return await page.locator(f"a[href='{path}']").count() == 0

    async def deletion_absence_confirmed(self, page: object, conversation_url: str) -> bool:
        if not self.is_conversation_url(conversation_url):
            return False
        path = urlsplit(conversation_url).path
        if urlsplit(page.url).path != path:
            return False
        if await page.locator("[data-testid='user-message']").count():
            return False
        if await page.locator("[data-testid='assistant-message']").count():
            return False
        await page.goto(self.home_url, wait_until="domcontentloaded")
        if await self.wait_for_home_hydration(page) != "COMPOSER_READY":
            return False
        if not await self.detect_login(page):
            return False
        return await page.locator(f"a[href='{path}']").count() == 0


class PerplexityPlugin(ObservedWebChatPlugin):
    phase = 3
    name = "perplexity"
    observed_at = "2026-08-23"
    deletion_action_verified = True
    home_url = "https://www.perplexity.ai/"
    conversation_link_selectors = ("a[href^='/search/']",)
    conversation_path_prefixes = ("/search/",)
    selectors = PhaseOneSelectors(
        login_indicators=("button:has-text('Sign in')", "button:has-text('Log in')"),
        prompt_inputs=("div#ask-input[role='textbox'][contenteditable='true']",),
        send_controls=("button[aria-label='\u63d0\u4ea4']:not([disabled])",),
        user_queries=("span[class*='select-text']",),
        responses=("div[class~='prose']",),
        streaming_indicators=("button[aria-label='\u505c\u6b62\u54cd\u5e94\uff08Esc\uff09']",),
        stop_controls=("button[aria-label='\u505c\u6b62\u54cd\u5e94\uff08Esc\uff09']",),
        conversation_menu_controls=("button[aria-label='\u4f1a\u8bdd\u64cd\u4f5c']",),
        delete_controls=("[role='menuitem']:has-text('\u5220\u9664')",),
        delete_confirm_controls=(
            "[role='dialog'][data-state='open'] button:has-text('\u5220\u9664')",
        ),
        final_response_descendants=(
            (
                "xpath=ancestor::div[contains(concat(' ', normalize-space(@class), ' '), "
                "' gap-4 ')][1]//button[@aria-label='\u62f7\u8d1d']"
            ),
        ),
    )

    def is_conversation_url(self, value: str) -> bool:
        if not super().is_conversation_url(value):
            return False
        conversation_id = urlsplit(value).path.removeprefix("/search/").strip("/")
        groups = conversation_id.split("-")
        return [len(group) for group in groups] == [8, 4, 4, 4, 12] and all(
            character in "0123456789abcdef" for group in groups for character in group.lower()
        )

    async def delete_chat(self, page: object) -> None:
        if not self.is_conversation_url(page.url):
            raise PluginPageAbnormal("Perplexity delete requires a conversation URL")
        path = urlsplit(page.url).path
        self._deleting_conversation_path = path
        self._history_count_before_delete = await page.locator("a[href^='/search/']").count()
        link = page.locator(f"a[href='{path}']")
        try:
            await link.wait_for(state="attached", timeout=10_000)
        except PlaywrightTimeoutError as exc:
            raise PluginPageAbnormal("Perplexity conversation item did not hydrate") from exc
        if await link.count() != 1:
            raise PluginPageAbnormal("Perplexity conversation item is not unique")
        item = link.locator("xpath=..")
        await item.scroll_into_view_if_needed(timeout=10_000)
        await item.hover()
        menu = item.locator("button[aria-label='\u4f1a\u8bdd\u64cd\u4f5c']")
        if await menu.count() != 1 or not await menu.is_visible():
            raise PluginPageAbnormal("Perplexity conversation menu is not uniquely visible")
        await menu.click()
        delete = page.get_by_role("menuitem", name="\u5220\u9664", exact=True)
        try:
            await delete.wait_for(state="visible", timeout=5_000)
        except PlaywrightTimeoutError as exc:
            raise PluginPageAbnormal("Perplexity delete item did not become visible") from exc
        if await delete.count() != 1:
            raise PluginPageAbnormal("Perplexity delete item is not unique")
        await delete.click()
        dialog = page.locator("[role='dialog'][data-state='open']")
        try:
            await dialog.wait_for(state="visible", timeout=5_000)
        except PlaywrightTimeoutError as exc:
            raise PluginPageAbnormal("Perplexity delete confirmation did not appear") from exc
        if await dialog.count() != 1:
            raise PluginPageAbnormal("Perplexity delete dialog is not unique")
        confirm = dialog.get_by_role("button", name="\u5220\u9664", exact=True)
        if await confirm.count() != 1 or not await confirm.is_visible():
            raise PluginPageAbnormal("Perplexity delete confirmation is not unique")
        await confirm.click()

    async def verify_chat_deleted(self, page: object) -> bool:
        path = getattr(self, "_deleting_conversation_path", None)
        if not isinstance(path, str) or not path.startswith("/search/"):
            return False
        if not await self.detect_login(page) or urlsplit(page.url).path == path:
            return False
        if await page.locator(f"a[href='{path}']").count():
            return False
        before = getattr(self, "_history_count_before_delete", None)
        if isinstance(before, int):
            after = await page.locator("a[href^='/search/']").count()
            return after < before
        return self.is_home_url(page.url)

    async def deletion_absence_confirmed(self, page: object, conversation_url: str) -> bool:
        if not self.is_conversation_url(conversation_url):
            return False
        path = urlsplit(conversation_url).path
        if urlsplit(page.url).path != path:
            return False
        if await page.locator("span[class*='select-text'],div[class~='prose']").count():
            return False
        await page.goto(self.home_url, wait_until="domcontentloaded")
        if await self.wait_for_home_hydration(page) != "COMPOSER_READY":
            return False
        if not await self.detect_login(page):
            return False
        return await page.locator(f"a[href='{path}']").count() == 0
