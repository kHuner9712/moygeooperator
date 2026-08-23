from __future__ import annotations

from playwright.async_api import TimeoutError as PlaywrightTimeoutError

from geo_operator.browser.plugins.phase1 import (
    DoubaoPlugin as _PhaseOneDoubaoPlugin,
    PhaseOneSelectors,
)


class DoubaoPlugin(_PhaseOneDoubaoPlugin):
    """Doubao selectors refreshed against the current web UI.

    Prefer stable data-testid and Semi UI attributes while retaining the previously calibrated
    DOM selectors as fallbacks. Current Doubao conversations expose stable send/receive message
    test ids, so recovery hydration and idempotency checks must recognize those nodes too.

    Doubao can replace a restored tab while a saved conversation is hydrating. Worker state owns
    the BrowserContext, not a particular tab, so plugin operations recover onto the newest live
    page instead of treating one closed Page object as a closed browser session.
    """

    observed_at = "2026-08-23"
    selectors = PhaseOneSelectors(
        login_indicators=(
            "button[data-testid='to_login_button']",
            "input[data-testid='login_phone_number_input']",
            "button.login-btn-header-CTKsn1",
        ),
        prompt_inputs=(
            "textarea[data-testid='chat_input_input']",
            "[data-testid='chat_input_input'][contenteditable='true']",
            "textarea.semi-input-textarea.semi-input-textarea-autosize",
            "textarea.semi-input-textarea",
            "div.tiptap.ProseMirror[role='textbox'][contenteditable='true']",
        ),
        send_controls=(
            "button[data-testid='chat_input_send_button']",
            "button#flow-end-msg-send",
        ),
        user_queries=(
            "[data-testid='send_message']",
            *_PhaseOneDoubaoPlugin.selectors.user_queries,
        ),
        responses=(
            "[data-testid='receive_message']",
            *_PhaseOneDoubaoPlugin.selectors.responses,
        ),
        streaming_indicators=_PhaseOneDoubaoPlugin.selectors.streaming_indicators,
        stop_controls=_PhaseOneDoubaoPlugin.selectors.stop_controls,
        error_indicators=_PhaseOneDoubaoPlugin.selectors.error_indicators,
        rate_limit_indicators=_PhaseOneDoubaoPlugin.selectors.rate_limit_indicators,
        security_indicators=_PhaseOneDoubaoPlugin.selectors.security_indicators,
        conversation_menu_controls=_PhaseOneDoubaoPlugin.selectors.conversation_menu_controls,
        delete_controls=_PhaseOneDoubaoPlugin.selectors.delete_controls,
        delete_confirm_controls=_PhaseOneDoubaoPlugin.selectors.delete_confirm_controls,
        final_response_descendants=_PhaseOneDoubaoPlugin.selectors.final_response_descendants,
        query_failure_descendants=_PhaseOneDoubaoPlugin.selectors.query_failure_descendants,
    )

    @staticmethod
    def _closed_target_error(exc: Exception) -> bool:
        text = str(exc).lower()
        return any(
            marker in text
            for marker in (
                "target page, context or browser has been closed",
                "page has been closed",
                "target closed",
            )
        )

    async def _live_page(self, page):
        try:
            if not page.is_closed():
                return page
        except Exception:
            pass

        context = page.context
        for candidate in reversed(context.pages):
            try:
                if not candidate.is_closed():
                    return candidate
            except Exception:
                continue
        return await context.new_page()

    async def open_platform(self, page) -> None:
        await super().open_platform(await self._live_page(page))

    async def detect_login(self, page) -> bool:
        return await super().detect_login(await self._live_page(page))

    async def detect_human_intervention(self, page) -> str | None:
        return await super().detect_human_intervention(await self._live_page(page))

    async def send_query(self, page, prompt: str) -> None:
        await super().send_query(await self._live_page(page), prompt)

    async def query_exists(self, page, prompt: str) -> bool:
        return await super().query_exists(await self._live_page(page), prompt)

    async def query_delivery_failed(self, page, prompt: str) -> bool:
        return await super().query_delivery_failed(await self._live_page(page), prompt)

    async def observe_response(self, page):
        return await super().observe_response(await self._live_page(page))

    async def screenshot(self, page) -> bytes:
        return await super().screenshot(await self._live_page(page))

    async def structural_snapshot(self, page):
        return await super().structural_snapshot(await self._live_page(page))

    async def recover_pending_query(self, page, prompt: str) -> str | None:
        return await super().recover_pending_query(await self._live_page(page), prompt)

    async def conversation_in_recent_history(self, page, conversation_url: str) -> bool:
        return await super().conversation_in_recent_history(
            await self._live_page(page), conversation_url
        )

    async def deletion_absence_confirmed(self, page, conversation_url: str) -> bool:
        return await super().deletion_absence_confirmed(
            await self._live_page(page), conversation_url
        )

    async def wait_for_calibration_hydration(self, page):
        """Recognize current messages and survive a Doubao tab replacement during hydration."""
        target = await self._live_page(page)
        for attempt in range(2):
            try:
                signal = await target.wait_for_function(
                    """() => {
                      const visible = node => {
                        if (!node) return false;
                        const style = getComputedStyle(node);
                        const rect = node.getBoundingClientRect();
                        return style.visibility !== 'hidden' && style.display !== 'none'
                          && rect.width > 0 && rect.height > 0;
                      };
                      const selectors = [
                        "[data-testid='send_message']",
                        "[data-testid='receive_message']",
                        "[class*='message-list-'] .v_list_row"
                      ];
                      for (const selector of selectors) {
                        if ([...document.querySelectorAll(selector)].some(visible)) {
                          return 'CONVERSATION_CONTENT';
                        }
                      }
                      const challenge = document.querySelector(
                        "[aria-label*='captcha' i], iframe[src*='challenge'], iframe[src*='captcha']"
                      );
                      return visible(challenge) ? 'INTERVENTION_SIGNAL' : null;
                    }""",
                    timeout=30_000,
                )
                return str(await signal.json_value())
            except PlaywrightTimeoutError:
                return "TIMEOUT"
            except Exception as exc:
                if attempt == 0 and self._closed_target_error(exc):
                    target = await self._live_page(target)
                    continue
                raise
        return "TIMEOUT"
