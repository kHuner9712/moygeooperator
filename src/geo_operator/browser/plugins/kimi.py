from __future__ import annotations

from geo_operator.browser.plugins.additional import KimiPlugin as _AdditionalKimiPlugin
from geo_operator.browser.plugins.phase1 import PhaseOneSelectors


class KimiPlugin(_AdditionalKimiPlugin):
    """Kimi adapter refreshed for the current composer state model.

    Kimi uses the same send-button container as both the idle send control and the in-flight stop
    control. Current pages mark the in-flight state with the ``stop`` class, so an actionable send
    selector must explicitly exclude both ``stop`` and the older ``loading`` state. Otherwise the
    worker can record a QUERY_SEND intent and click a stop control without ever delivering the
    prompt.

    Kimi can also occasionally accept the click at the DOM level without committing the prompt.
    When the exact prompt remains in the composer, no matching user turn exists, and no stop/loading
    state is active after a bounded grace period, the page itself proves non-delivery. The worker may
    then perform one bounded automatic retry without weakening the normal idempotency guard.
    """

    observed_at = "2026-08-23"
    can_prove_query_non_delivery = True
    query_non_delivery_grace_seconds = 4.0
    automatic_retry_on_proven_non_delivery = True

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

    async def query_delivery_failed(self, page, prompt: str) -> bool:
        """Prove a dropped send only from durable composer state, never from history absence alone."""
        if await self.query_exists(page, prompt):
            return await super().query_delivery_failed(page, prompt)
        if await self._any_visible(page, self.selectors.stop_controls):
            return False
        composer = await self._one_visible(page, self.selectors.prompt_inputs)
        if composer is None:
            return False
        actual = self.normalize_query_text(await composer.inner_text())
        expected = self.normalize_query_text(prompt)
        if not actual or actual != expected:
            return False
        return await self._one_visible(page, self.selectors.send_controls) is not None
