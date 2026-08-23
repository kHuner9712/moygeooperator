from __future__ import annotations

import asyncio
import time
from urllib.parse import urljoin, urlsplit

from playwright.async_api import TimeoutError as PlaywrightTimeoutError

from geo_operator.browser.plugins.additional import KimiPlugin as _AdditionalKimiPlugin
from geo_operator.browser.plugins.phase1 import PhaseOneSelectors


class KimiPlugin(_AdditionalKimiPlugin):
    """Kimi adapter refreshed for durable send and history recovery semantics.

    Kimi uses one composer action as both Send and Stop. Sending is considered delivered only after
    a rendered user turn containing the prompt exists; URL routing, composer clearing, or stop-state
    changes are not sufficient delivery evidence. Historical chat navigation also needs
    ``chat_enter_method=history`` so Kimi mounts the message list before query reconciliation.
    """

    observed_at = "2026-08-23"
    conversation_link_selectors = ("a[href*='/chat/']",)

    _user_turn_selector = (
        ".chat-content-list .chat-content-item-user, "
        ".chat-content-item.chat-content-item-user, "
        ".segment.segment-user, .segment-user"
    )

    selectors = PhaseOneSelectors(
        login_indicators=_AdditionalKimiPlugin.selectors.login_indicators,
        prompt_inputs=(
            "div.chat-input-editor[role='textbox'][contenteditable='true']",
            "div.chat-input-editor[contenteditable='true']",
            "div[role='textbox'][contenteditable='true']",
        ),
        send_controls=(
            "svg[name='Send']",
            "div.send-button-container:not(.disabled):not(.stop):not(.loading)",
            "div[role='button'][aria-label='Send']:not([aria-disabled='true'])",
            "button[aria-label='Send']:not([disabled])",
        ),
        user_queries=(_user_turn_selector,),
        responses=_AdditionalKimiPlugin.selectors.responses,
        streaming_indicators=(
            "div.send-button-container.stop",
            "div.send-button-container.disabled.stop",
            "div.send-button-container.loading",
            "svg[name='Stop']",
        ),
        stop_controls=(
            "div.send-button-container.stop",
            "div.send-button-container.disabled.stop",
            "div.send-button-container.loading",
            "svg[name='Stop']",
        ),
        error_indicators=_AdditionalKimiPlugin.selectors.error_indicators,
        rate_limit_indicators=_AdditionalKimiPlugin.selectors.rate_limit_indicators,
        security_indicators=_AdditionalKimiPlugin.selectors.security_indicators,
        conversation_menu_controls=_AdditionalKimiPlugin.selectors.conversation_menu_controls,
        delete_controls=_AdditionalKimiPlugin.selectors.delete_controls,
        delete_confirm_controls=_AdditionalKimiPlugin.selectors.delete_confirm_controls,
        final_response_descendants=_AdditionalKimiPlugin.selectors.final_response_descendants,
        query_failure_descendants=_AdditionalKimiPlugin.selectors.query_failure_descendants,
    )

    async def _query_match_count(self, page, prompt: str) -> int:
        expected = self.normalize_query_text(prompt)
        rows = page.locator(self._user_turn_selector)
        matches = 0
        for index in range(await rows.count()):
            actual = self.normalize_query_text(await rows.nth(index).inner_text())
            if actual == expected or expected in actual:
                matches += 1
        return matches

    async def query_exists(self, page, prompt: str) -> bool:
        return await self._query_match_count(page, prompt) > 0

    async def _wait_for_new_user_turn(
        self, page, prompt: str, before_matches: int, timeout: float = 5.0
    ) -> bool:
        started = time.monotonic()
        while time.monotonic() - started < timeout:
            if await self._query_match_count(page, prompt) > before_matches:
                return True
            await asyncio.sleep(0.2)
        return await self._query_match_count(page, prompt) > before_matches

    async def send_query(self, page, prompt: str) -> None:
        """Click Send and verify a new rendered Kimi user turn; retry one proven idle no-op."""
        before_matches = await self._query_match_count(page, prompt)
        await super().send_query(page, prompt)
        if await self._wait_for_new_user_turn(page, prompt, before_matches):
            return

        # A second click is safe only when the exact prompt is still in an idle composer. Do not
        # infer delivery from URL routing, composer clearing, or a transient Stop state.
        if await self._any_visible(page, self.selectors.stop_controls):
            return
        composer = await self._one_visible(page, self.selectors.prompt_inputs)
        if composer is None:
            return
        expected = self.normalize_query_text(prompt)
        actual = self.normalize_query_text(await composer.inner_text())
        if actual != expected:
            return

        send = await self._unique_visible(page, self.selectors.send_controls, "send control")
        await send.click()
        await self._wait_for_new_user_turn(page, prompt, before_matches)

    async def recover_pending_query(self, page, prompt: str) -> str | None:
        """Recover a Kimi prompt from hydrated recent chats using history-entry navigation."""
        if self.is_conversation_url(page.url):
            try:
                if await self.query_exists(page, prompt):
                    return page.url
            except Exception:
                pass

        await page.goto(self.home_url, wait_until="domcontentloaded")

        # Kimi history is rendered asynchronously. Give the sidebar time to mount instead of
        # treating an immediate empty query after DOMContentLoaded as proof that history is empty.
        links = page.locator("a[href*='/chat/']")
        deadline = time.monotonic() + 10.0
        while time.monotonic() < deadline and await links.count() == 0:
            intervention = await self.detect_human_intervention(page)
            if intervention:
                return None
            await asyncio.sleep(0.25)

        hrefs = await links.evaluate_all("nodes => nodes.map(node => node.getAttribute('href'))")
        candidates: list[str] = []
        for href in hrefs:
            if not isinstance(href, str):
                continue
            candidate = urljoin(self.home_url, href)
            if not self.is_conversation_url(candidate):
                continue
            normalized = urlsplit(candidate)._replace(query="", fragment="").geturl()
            if normalized not in candidates:
                candidates.append(normalized)

        for candidate in candidates[:30]:
            target = urlsplit(candidate)._replace(query="chat_enter_method=history", fragment="").geturl()
            await page.goto(target, wait_until="domcontentloaded")
            rows = page.locator(
                ".chat-content-list .chat-content-item, .message-list > *, .segment"
            )
            try:
                await rows.first.wait_for(state="attached", timeout=15_000)
            except PlaywrightTimeoutError:
                continue
            if await self.query_exists(page, prompt):
                return urlsplit(page.url)._replace(query="", fragment="").geturl()
        return None
