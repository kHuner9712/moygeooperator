from __future__ import annotations

import asyncio
import time

from geo_operator.browser.plugins.additional import KimiPlugin as _AdditionalKimiPlugin
from geo_operator.browser.plugins.phase1 import PhaseOneSelectors


class KimiPlugin(_AdditionalKimiPlugin):
    """Kimi adapter refreshed for the current composer state model.

    Kimi uses the same send-button container as both the idle send control and the in-flight stop
    control. Current pages mark the in-flight state with the ``stop`` class, so an actionable send
    selector must explicitly exclude both ``stop`` and the older ``loading`` state. Otherwise the
    worker can record a QUERY_SEND intent and click a stop control without ever delivering the
    prompt.

    Kimi can also occasionally accept a click at the DOM level without committing the prompt. After
    the first click this adapter waits boundedly for durable acceptance evidence. It retries exactly
    once only when the page still shows the exact original prompt in an idle composer, has not routed
    to a conversation URL, and has no stop/loading state. This keeps the normal idempotency guard
    intact while recovering the platform-specific dropped-click race before control returns to the
    worker.
    """

    observed_at = "2026-08-23"

    selectors = PhaseOneSelectors(
        login_indicators=_AdditionalKimiPlugin.selectors.login_indicators,
        prompt_inputs=(
            "div.chat-input-editor[role='textbox'][contenteditable='true']",
            "div.chat-input-editor[contenteditable='true']",
            "div[role='textbox'][contenteditable='true']",
        ),
        send_controls=(
            "div.send-button-container:not(.disabled):not(.stop):not(.loading)",
            "div[role='button'][aria-label='Send']:not([aria-disabled='true'])",
            "button[aria-label='Send']:not([disabled])",
        ),
        user_queries=_AdditionalKimiPlugin.selectors.user_queries,
        responses=_AdditionalKimiPlugin.selectors.responses,
        streaming_indicators=(
            "div.send-button-container.stop",
            "div.send-button-container.loading",
        ),
        stop_controls=(
            "div.send-button-container.stop",
            "div.send-button-container.loading",
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

    async def send_query(self, page, prompt: str) -> None:
        await super().send_query(page, prompt)

        expected = self.normalize_query_text(prompt)
        started = time.monotonic()
        while time.monotonic() - started < 5.0:
            if await self.query_exists(page, prompt):
                return
            if self.is_conversation_url(page.url):
                return
            if await self._any_visible(page, self.selectors.stop_controls):
                return
            composer = await self._one_visible(page, self.selectors.prompt_inputs)
            if composer is None:
                return
            actual = self.normalize_query_text(await composer.inner_text())
            if actual != expected:
                return
            await asyncio.sleep(0.25)

        if await self.query_exists(page, prompt):
            return
        if self.is_conversation_url(page.url):
            return
        if await self._any_visible(page, self.selectors.stop_controls):
            return
        composer = await self._one_visible(page, self.selectors.prompt_inputs)
        if composer is None:
            return
        actual = self.normalize_query_text(await composer.inner_text())
        if actual != expected:
            return

        send = await self._unique_visible(page, self.selectors.send_controls, "send control")
        await send.click()
