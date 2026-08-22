from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass
from typing import Any
from urllib.parse import urljoin, urlsplit

from playwright.async_api import TimeoutError as PlaywrightTimeoutError

from geo_operator.browser.plugins.base import (
    PlatformObservation,
    RevalidationResult,
    SideEffectNotAttempted,
)


class PluginNotCalibrated(RuntimeError):
    pass


class PluginPageAbnormal(RuntimeError):
    pass


@dataclass(frozen=True, slots=True)
class PhaseOneSelectors:
    login_indicators: tuple[str, ...]
    prompt_inputs: tuple[str, ...]
    send_controls: tuple[str, ...]
    user_queries: tuple[str, ...] = ()
    responses: tuple[str, ...] = ()
    streaming_indicators: tuple[str, ...] = ()
    stop_controls: tuple[str, ...] = ()
    error_indicators: tuple[str, ...] = ()
    rate_limit_indicators: tuple[str, ...] = ()
    security_indicators: tuple[str, ...] = ()
    conversation_menu_controls: tuple[str, ...] = ()
    delete_controls: tuple[str, ...] = ()
    delete_confirm_controls: tuple[str, ...] = ()
    final_response_descendants: tuple[str, ...] = ()
    query_failure_descendants: tuple[str, ...] = ()


class ObservedWebChatPlugin:
    phase = 1
    name = ""
    home_url = ""
    selectors: PhaseOneSelectors
    observed_at = "2026-08-22"
    conversation_link_selectors = ("a[href*='/c/']",)
    conversation_path_prefixes = ("/c/",)
    deletion_action_verified = True

    @property
    def response_capture_calibration_complete(self) -> bool:
        required = (
            self.selectors.prompt_inputs,
            self.selectors.send_controls,
            self.selectors.user_queries,
            self.selectors.responses,
            self.selectors.streaming_indicators,
            self.selectors.stop_controls,
        )
        return all(required)

    @property
    def deletion_calibration_complete(self) -> bool:
        required = (
            self.selectors.conversation_menu_controls,
            self.selectors.delete_controls,
            self.selectors.delete_confirm_controls,
        )
        return all(required) and self.deletion_action_verified

    @property
    def calibration_complete(self) -> bool:
        return self.response_capture_calibration_complete and self.deletion_calibration_complete

    @property
    def response_locator(self) -> str:
        self._require_fields("responses")
        return self.selectors.responses[0]

    async def open_platform(self, page: Any) -> None:
        if not page.url.startswith(self.home_url):
            await page.goto(self.home_url, wait_until="domcontentloaded")

    async def detect_login(self, page: Any) -> bool:
        for selector in self.selectors.login_indicators:
            locator = page.locator(selector)
            if await locator.count() and await locator.first.is_visible():
                return False
        return await self._one_visible(page, self.selectors.prompt_inputs) is not None

    async def detect_human_intervention(self, page: Any) -> str | None:
        body = (await page.locator("body").inner_text()).lower()
        patterns = (
            (("captcha", "验证码"), "CAPTCHA"),
            (("security check", "安全验证", "验证身份"), "SECURITY_CHALLENGE"),
            (("too many requests", "rate limit", "请求过于频繁"), "RATE_LIMITED"),
            (("account restricted", "账号受限", "账户受限"), "ACCOUNT_RESTRICTED"),
            (
                (
                    "\u62d6\u62fd\u5230\u8fd9\u91cc",
                    "\u8bf7\u9009\u62e9\u6240\u6709\u7b26\u5408\u4e0a\u6587\u63cf\u8ff0\u7684\u56fe\u7247",
                ),
                "CAPTCHA",
            ),
        )
        for needles, reason in patterns:
            if any(needle in body for needle in needles):
                return reason
        if await self._any_visible(page, self.selectors.login_indicators):
            return "LOGIN_EXPIRED"
        return None

    async def send_query(self, page: Any, prompt: str) -> None:
        try:
            self._require_fields("prompt_inputs", "send_controls")
            for attempt in range(3):
                target = await self._unique_visible(
                    page, self.selectors.prompt_inputs, "prompt input"
                )
                try:
                    await target.fill(prompt, timeout=5_000)
                    break
                except PlaywrightTimeoutError:
                    if attempt == 2:
                        raise
                    await page.wait_for_timeout(250)
            send = await self._unique_visible(page, self.selectors.send_controls, "send control")
        except Exception as exc:
            raise SideEffectNotAttempted(
                "Query send control was not invoked because preflight did not complete"
            ) from exc
        await send.click()

    async def query_exists(self, page: Any, prompt: str) -> bool:
        self._require_fields("user_queries")
        nodes = self._combined(page, self.selectors.user_queries)
        expected = self.normalize_query_text(prompt)
        matches = 0
        for index in range(await nodes.count()):
            actual = self.normalize_query_text(await nodes.nth(index).inner_text())
            if actual == expected:
                matches += 1
        if matches > 1:
            raise PluginPageAbnormal("Multiple identical user query nodes found")
        return matches == 1

    async def query_delivery_failed(self, page: Any, prompt: str) -> bool:
        if not self.selectors.query_failure_descendants:
            return False
        nodes = self._combined(page, self.selectors.user_queries)
        expected = self.normalize_query_text(prompt)
        for index in range(await nodes.count()):
            node = nodes.nth(index)
            actual = self.normalize_query_text(await node.inner_text())
            if actual == expected and await self._any_visible_within(
                node, self.selectors.query_failure_descendants
            ):
                return True
        return False

    def normalize_query_text(self, value: str) -> str:
        return " ".join(unicodedata.normalize("NFKC", value).split())

    async def observe_response(self, page: Any) -> PlatformObservation:
        self._require_fields(
            "responses",
            "streaming_indicators",
            "stop_controls",
            "prompt_inputs",
            "send_controls",
        )
        streaming = await self._any_visible(page, self.selectors.streaming_indicators)
        stop = await self._any_visible(page, self.selectors.stop_controls)
        input_target = await self._one_visible(page, self.selectors.prompt_inputs)
        error = await self._any_visible(page, self.selectors.error_indicators)
        responses = self._combined(page, self.selectors.responses)
        queries = self._combined(page, self.selectors.user_queries)
        if await queries.count() < 1:
            raise PluginPageAbnormal("User query container not found")
        if await responses.count() < 1:
            return PlatformObservation(
                response_text="",
                streaming_indicator_absent=not streaming,
                stop_control_absent=not stop,
                input_ready=False,
                response_text_stable=False,
                final_response_element_present=False,
                platform_error_absent=not error,
            )
        response = responses.last
        latest_query = queries.last
        query_handle = await latest_query.element_handle()
        if query_handle is None:
            raise PluginPageAbnormal("Latest user query is detached")
        response_follows_query = await response.evaluate(
            """(node, query) => Boolean(
              query.compareDocumentPosition(node) & Node.DOCUMENT_POSITION_FOLLOWING
            )""",
            query_handle,
        )
        if not response_follows_query:
            return PlatformObservation(
                response_text="",
                streaming_indicator_absent=False,
                stop_control_absent=False,
                input_ready=False,
                response_text_stable=False,
                final_response_element_present=False,
                platform_error_absent=not error,
            )
        text = (await response.inner_text()).strip()
        final_present = bool(text and not streaming and not stop)
        if self.selectors.final_response_descendants:
            final_present = await self._any_visible_within(
                response, self.selectors.final_response_descendants
            )
        return PlatformObservation(
            response_text=text,
            streaming_indicator_absent=not streaming,
            stop_control_absent=not stop,
            input_ready=bool(input_target and await input_target.is_enabled() and not stop),
            response_text_stable=False,
            final_response_element_present=final_present,
            platform_error_absent=not error,
        )

    async def delete_chat(self, page: Any) -> None:
        self._require_fields(
            "conversation_menu_controls", "delete_controls", "delete_confirm_controls"
        )
        menu = await self._unique_visible(
            page, self.selectors.conversation_menu_controls, "conversation menu control"
        )
        await menu.click()
        await self._combined(page, self.selectors.delete_controls).first.wait_for(
            state="visible", timeout=5_000
        )
        delete = await self._unique_visible(page, self.selectors.delete_controls, "delete control")
        await delete.click()
        await self._combined(page, self.selectors.delete_confirm_controls).first.wait_for(
            state="visible", timeout=5_000
        )
        confirm = await self._unique_visible(
            page, self.selectors.delete_confirm_controls, "delete confirmation"
        )
        await confirm.click()

    async def verify_chat_deleted(self, page: Any) -> bool:
        self._require_fields("user_queries")
        return await self._combined(page, self.selectors.user_queries).count() == 0

    async def screenshot(self, page: Any) -> bytes:
        return await page.screenshot(full_page=True, animations="disabled", timeout=10_000)

    async def structural_snapshot(self, page: Any) -> list[dict[str, object]]:
        """Capture visible DOM structure for calibration without node text or browser storage."""
        return await page.eval_on_selector_all(
            "*",
            """nodes => nodes.filter(node => {
              const style = getComputedStyle(node);
              const rect = node.getBoundingClientRect();
              return style.visibility !== 'hidden' && style.display !== 'none'
                && rect.width > 0 && rect.height > 0
                && (node.id || node.className || node.hasAttribute('role')
                  || node.hasAttribute('data-testid')
                  || node.hasAttribute('data-e2e') || node.hasAttribute('data-state')
                  || node.hasAttribute('data-slot') || node.hasAttribute('title')
                  || node.hasAttribute('aria-haspopup')
                  || node.hasAttribute('aria-controls')
                  || node.hasAttribute('data-message-author-role')
                  || node.hasAttribute('data-turn') || node.hasAttribute('data-turn-id')
                  || node.hasAttribute('data-message-id')
                  || node.hasAttribute('contenteditable')
                  || ['A','BUTTON','TEXTAREA','INPUT','ARTICLE','MAIN','SECTION'].includes(node.tagName));
            }).slice(0, 2000).map(node => {
              const pick = name => {
                const value = node.getAttribute(name);
                return value === null ? null : value.slice(0, 500);
              };
              const testid = pick('data-testid');
              return {
                tag: node.tagName.toLowerCase(), id: pick('id'), class: pick('class'),
                role: pick('role'), data_testid: testid, data_e2e: pick('data-e2e'),
                data_state: pick('data-state'), data_slot: pick('data-slot'),
                message_author: pick('data-message-author-role'),
                turn: pick('data-turn'), turn_id: pick('data-turn-id'),
                message_id: pick('data-message-id'), href: pick('href'),
                aria_busy: pick('aria-busy'), aria_haspopup: pick('aria-haspopup'),
                aria_controls: pick('aria-controls'), title: pick('title'),
                contenteditable: pick('contenteditable'), disabled: node.hasAttribute('disabled'),
                aria_label: testid === 'accounts-profile-button'
                  ? '[REDACTED_ACCOUNT_LABEL]' : pick('aria-label'),
                parent_tag: node.parentElement?.tagName?.toLowerCase() ?? null,
                parent_id: node.parentElement?.getAttribute('id')?.slice(0, 500) ?? null,
                parent_class: node.parentElement?.getAttribute('class')?.slice(0, 500) ?? null,
                grandparent_class:
                  node.parentElement?.parentElement?.getAttribute('class')?.slice(0, 500) ?? null
              };
            })""",
        )

    async def wait_for_calibration_hydration(self, page: Any) -> str:
        """Wait boundedly for structural conversation signals; never infer from fixed sleeps."""
        try:
            signal = await page.wait_for_function(
                """() => {
                  const content = document.querySelector(
                    "article, [data-message-author-role], [data-testid^='conversation-turn-'], "
                    + "[class*='message-list-'] .v_list_row, .ds-message, user-query-content, model-response, "
                    + ".agent-chat__list__item--human"
                  );
                  if (content) return 'CONVERSATION_CONTENT';
                  const challenge = document.querySelector(
                    "[aria-label*='captcha' i], iframe[src*='challenge']"
                  );
                  return challenge ? 'INTERVENTION_SIGNAL' : null;
                }""",
                timeout=30_000,
            )
            return str(await signal.json_value())
        except Exception as exc:
            if type(exc).__name__ == "TimeoutError":
                return "TIMEOUT"
            raise

    async def wait_for_home_hydration(self, page: Any) -> str:
        """Wait boundedly for a hydrated signed-in home page or an intervention signal."""
        try:
            signal = await page.wait_for_function(
                """selectors => {
                  const visible = node => {
                    if (!node) return false;
                    const style = getComputedStyle(node);
                    const rect = node.getBoundingClientRect();
                    return style.visibility !== 'hidden' && style.display !== 'none'
                      && rect.width > 0 && rect.height > 0;
                  };
                  for (const selector of selectors.promptInputs) {
                    if ([...document.querySelectorAll(selector)].some(visible)) {
                      return 'COMPOSER_READY';
                    }
                  }
                  const challenge = document.querySelector(
                    "[aria-label*='captcha' i], iframe[src*='challenge'], iframe[src*='captcha']"
                  );
                  if (visible(challenge)) return 'INTERVENTION_SIGNAL';
                  return null;
                }""",
                arg={
                    "promptInputs": list(self.selectors.prompt_inputs),
                },
                timeout=30_000,
            )
            return str(await signal.json_value())
        except PlaywrightTimeoutError:
            if await self._any_visible(page, self.selectors.login_indicators):
                return "LOGIN_REQUIRED"
            return "TIMEOUT"

    async def recover_pending_query(self, page: Any, prompt: str) -> str | None:
        """Find an already-sent prompt in same-origin recent chats without reading other text."""
        await page.goto(self.home_url, wait_until="domcontentloaded")
        hrefs = await self._combined(page, self.conversation_link_selectors).evaluate_all(
            "nodes => nodes.map(node => node.getAttribute('href'))",
        )
        candidates: list[str] = []
        for href in hrefs:
            if not isinstance(href, str):
                continue
            candidate = urljoin(self.home_url, href)
            if not self.is_conversation_url(candidate):
                continue
            if candidate not in candidates:
                candidates.append(candidate)
        for candidate in candidates[:20]:
            await page.goto(candidate, wait_until="domcontentloaded")
            try:
                await self._combined(page, self.selectors.user_queries).first.wait_for(
                    state="attached", timeout=5_000
                )
            except PlaywrightTimeoutError:
                continue
            if await self.query_exists(page, prompt):
                return page.url
        return None

    async def conversation_in_recent_history(self, page: Any, conversation_url: str) -> bool:
        """Check same-origin URL membership only; never read conversation titles or text."""
        await page.goto(self.home_url, wait_until="domcontentloaded")
        if not await self.detect_login(page):
            return True
        hrefs = await self._combined(page, self.conversation_link_selectors).evaluate_all(
            "nodes => nodes.map(node => node.getAttribute('href'))",
        )
        urls: set[str] = set()
        for href in hrefs:
            if not isinstance(href, str):
                continue
            candidate = urljoin(self.home_url, href)
            if not self.is_conversation_url(candidate):
                continue
            target = urlsplit(candidate)
            urls.add(target._replace(query="", fragment="").geturl())
        if not urls:
            return True
        target = urlsplit(conversation_url)
        normalized = target._replace(query="", fragment="").geturl()
        return normalized in urls

    async def deletion_absence_confirmed(self, page: Any, conversation_url: str) -> bool:
        """Prove target absence only when the signed-in account history is otherwise healthy."""
        target = urlsplit(conversation_url)
        current = urlsplit(page.url)
        target_key = target._replace(query="", fragment="").geturl()
        current_key = current._replace(query="", fragment="").geturl()
        if current_key != target_key:
            return False
        if not await self.verify_chat_deleted(page):
            return False
        await page.goto(self.home_url, wait_until="domcontentloaded")
        if not await self.detect_login(page):
            return False
        hrefs = await self._combined(page, self.conversation_link_selectors).evaluate_all(
            "nodes => nodes.map(node => node.getAttribute('href'))",
        )
        for href in hrefs:
            if not isinstance(href, str):
                continue
            if self.is_conversation_url(urljoin(self.home_url, href)):
                return True
        return False

    def is_conversation_url(self, value: str) -> bool:
        target = urlsplit(value)
        home = urlsplit(self.home_url)
        if (
            target.scheme != "https"
            or target.netloc != home.netloc
            or target.username
            or target.password
            or "WEB:" in target.path
        ):
            return False
        return any(
            target.path.startswith(prefix) and target.path.rstrip("/") != prefix.rstrip("/")
            for prefix in self.conversation_path_prefixes
        )

    def is_home_url(self, value: str) -> bool:
        target = urlsplit(value)
        home = urlsplit(self.home_url)
        return (
            target.scheme == "https"
            and target.netloc == home.netloc
            and target.path.rstrip("/") == home.path.rstrip("/")
            and not target.username
            and not target.password
        )

    async def revalidate(self, page: Any, execution: dict[str, object]) -> RevalidationResult:
        reason = await self.detect_human_intervention(page)
        if reason:
            return RevalidationResult(False, None, reason)
        if not await self.detect_login(page):
            return RevalidationResult(False, None, "LOGIN_EXPIRED", "Prompt input not ready")
        if not self.response_capture_calibration_complete:
            return RevalidationResult(
                False, None, "PAGE_ABNORMAL", "Response calibration incomplete"
            )
        return RevalidationResult(True, str(execution.get("resume_state")), None)

    def calibration_status(self) -> dict[str, object]:
        return {
            "platform": self.name,
            "phase": self.phase,
            "observed_at": self.observed_at,
            "complete": self.calibration_complete,
            "support_status": (
                "EXECUTION_READY" if self.calibration_complete else "CALIBRATION_REQUIRED"
            ),
            "dispatch_eligible": self.calibration_complete,
            "response_capture_complete": self.response_capture_calibration_complete,
            "deletion_complete": self.deletion_calibration_complete,
            "missing": [
                name
                for name, selectors in (
                    ("send_controls", self.selectors.send_controls),
                    ("user_queries", self.selectors.user_queries),
                    ("responses", self.selectors.responses),
                    ("streaming_indicators", self.selectors.streaming_indicators),
                    ("stop_controls", self.selectors.stop_controls),
                    ("conversation_menu_controls", self.selectors.conversation_menu_controls),
                    ("delete_controls", self.selectors.delete_controls),
                    ("delete_confirm_controls", self.selectors.delete_confirm_controls),
                )
                if not selectors
            ]
            + (["delete_action_verification"] if not self.deletion_action_verified else []),
        }

    def _require_fields(self, *fields: str) -> None:
        missing = [field for field in fields if not getattr(self.selectors, field)]
        if missing:
            raise PluginNotCalibrated(
                f"{self.name} live calibration incomplete: {', '.join(missing)}"
            )

    @staticmethod
    def _combined(page: Any, selectors: tuple[str, ...]) -> Any:
        if not selectors:
            raise PluginNotCalibrated("Required selector set has not been calibrated")
        return page.locator(", ".join(selectors))

    async def _one_visible(self, page: Any, selectors: tuple[str, ...]) -> Any | None:
        for selector in selectors:
            locator = page.locator(selector)
            visible = [
                locator.nth(i)
                for i in range(await locator.count())
                if await locator.nth(i).is_visible()
            ]
            if len(visible) == 1:
                return visible[0]
            if len(visible) > 1:
                raise PluginPageAbnormal(f"Ambiguous selector: {selector}")
        return None

    async def _unique_visible(self, page: Any, selectors: tuple[str, ...], label: str) -> Any:
        target = await self._one_visible(page, selectors)
        if target is None:
            raise PluginPageAbnormal(f"{label} not found")
        return target

    async def _any_visible(self, page: Any, selectors: tuple[str, ...]) -> bool:
        for selector in selectors:
            locator = page.locator(selector)
            for index in range(await locator.count()):
                if await locator.nth(index).is_visible():
                    return True
        return False

    async def _any_visible_within(self, root: Any, selectors: tuple[str, ...]) -> bool:
        for selector in selectors:
            locator = root.locator(selector)
            for index in range(await locator.count()):
                if await locator.nth(index).is_visible():
                    return True
        return False


# Backward-compatible import for existing integrations; new code uses the generic name.
ObservedPhaseOnePlugin = ObservedWebChatPlugin


class ChatGPTPlugin(ObservedWebChatPlugin):
    name = "chatgpt"
    home_url = "https://chatgpt.com/"
    selectors = PhaseOneSelectors(
        login_indicators=(
            ".wm-app-loginButton",
            ".wm-sidebar-loginButton",
            "[data-testid='login-button']",
        ),
        prompt_inputs=(
            "textarea[aria-label*='ChatGPT']",
            "#prompt-textarea[contenteditable='true']",
            "[contenteditable='true'][aria-label*='ChatGPT']",
            "textarea#mobile-composer-prompt.wm-composer-textarea",
        ),
        send_controls=(
            "[data-testid='send-button']",
            "button#composer-submit-button",
            ".wm-composer-submitButton",
        ),
        user_queries=("[data-message-author-role='user']",),
        responses=("[data-message-author-role='assistant']",),
        streaming_indicators=("[data-testid='stop-button']",),
        stop_controls=("[data-testid='stop-button']",),
        conversation_menu_controls=("button[data-testid='conversation-options-button']",),
        delete_controls=("[data-testid='delete-chat-menu-item']",),
        delete_confirm_controls=("[data-testid='delete-conversation-confirm-button']",),
    )


class DoubaoPlugin(ObservedWebChatPlugin):
    name = "doubao"
    home_url = "https://www.doubao.com/chat/"
    conversation_link_selectors = ("a[id^='conversation_'][href*='/chat/']",)
    conversation_path_prefixes = ("/chat/",)
    deletion_action_verified = True
    selectors = PhaseOneSelectors(
        login_indicators=("button.login-btn-header-CTKsn1",),
        prompt_inputs=(
            "textarea",
            "div.tiptap.ProseMirror[role='textbox'][contenteditable='true']",
        ),
        send_controls=("button#flow-end-msg-send",),
        user_queries=(
            (
                "[class*='message-list-'] .v_list_row:has(.bg-g-send-msg-bubble-bg) "
                ".bg-g-send-msg-bubble-bg"
            ),
        ),
        responses=(
            "[class*='message-list-'] .v_list_row:not(:has(.bg-g-send-msg-bubble-bg)) .md-box-root",
        ),
        streaming_indicators=("[class*='break-btn-']",),
        stop_controls=("[class*='break-btn-']",),
        conversation_menu_controls=(
            (
                "a[id^='conversation_'] "
                "button[data-slot='dropdown-menu-trigger'][aria-haspopup='menu']"
            ),
        ),
        delete_controls=("[role='menuitem']",),
        delete_confirm_controls=(
            "[role='dialog'] [data-slot='dialog-footer'] button.bg-dbx-function-danger",
        ),
        final_response_descendants=(
            (
                "xpath=ancestor::*[contains(concat(' ', normalize-space(@class), ' '), "
                "' v_list_row ')][1]//*[contains(@class, 'message-action-bar-')]"
            ),
        ),
        query_failure_descendants=(
            (
                "xpath=ancestor::*[contains(concat(' ', normalize-space(@class), ' '), "
                "' v_list_row ')][1]//*[name()='svg' and "
                "contains(@class, 'text-s-color-alert')]"
            ),
        ),
    )

    def normalize_query_text(self, value: str) -> str:
        normalized = super().normalize_query_text(value)
        normalized = re.sub(r"(?<=[\u3400-\u9fff])\s+(?=[A-Za-z0-9])", "", normalized)
        return re.sub(r"(?<=[A-Za-z0-9])\s+(?=[\u3400-\u9fff])", "", normalized)

    def is_conversation_url(self, value: str) -> bool:
        if not super().is_conversation_url(value):
            return False
        suffix = urlsplit(value).path.removeprefix("/chat/").strip("/")
        return bool(suffix and suffix.isdigit())

    async def delete_chat(self, page: Any) -> None:
        self._require_fields(
            "conversation_menu_controls", "delete_controls", "delete_confirm_controls"
        )
        if not self.is_conversation_url(page.url):
            raise PluginPageAbnormal("Doubao delete requires a conversation URL")
        conversation_id = urlsplit(page.url).path.rstrip("/").rsplit("/", 1)[-1]
        self._deleting_conversation_id = conversation_id
        conversation = page.locator(f"a#conversation_{conversation_id}")
        try:
            await conversation.wait_for(state="visible", timeout=10_000)
        except PlaywrightTimeoutError as exc:
            raise PluginPageAbnormal("Doubao conversation item did not become visible") from exc
        if await conversation.count() != 1:
            raise PluginPageAbnormal("Doubao conversation item is not unique")
        await conversation.scroll_into_view_if_needed()
        await conversation.hover()
        menu = conversation.locator(
            "button[data-slot='dropdown-menu-trigger'][aria-haspopup='menu']"
        )
        if await menu.count() != 1 or not await menu.is_visible():
            raise PluginPageAbnormal("Doubao conversation menu is not uniquely visible")
        await menu.click()

        delete = page.get_by_role("menuitem", name="\u5220\u9664", exact=True)
        try:
            await delete.wait_for(state="visible", timeout=5_000)
        except PlaywrightTimeoutError as exc:
            raise PluginPageAbnormal("Doubao delete menu item did not become visible") from exc
        if await delete.count() != 1:
            raise PluginPageAbnormal("Doubao delete menu item is not unique")
        await delete.click()

        dialog = page.get_by_role("dialog")
        try:
            await dialog.wait_for(state="visible", timeout=5_000)
        except PlaywrightTimeoutError as exc:
            raise PluginPageAbnormal("Doubao delete dialog did not become visible") from exc
        confirm = dialog.get_by_role("button", name="\u5220\u9664", exact=True)
        if await confirm.count() != 1 or not await confirm.is_visible():
            raise PluginPageAbnormal("Doubao delete confirmation is not uniquely visible")
        await confirm.click()

    async def verify_chat_deleted(self, page: Any) -> bool:
        conversation_id = getattr(self, "_deleting_conversation_id", None)
        if not isinstance(conversation_id, str) or not conversation_id.isdigit():
            return False
        if not await super().verify_chat_deleted(page) or not await self.detect_login(page):
            return False
        return await page.locator(f"a#conversation_{conversation_id}").count() == 0
