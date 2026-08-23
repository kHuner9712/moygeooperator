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

    async def wait_for_calibration_hydration(self, page):
        """Recognize both current data-testid messages and the older virtual-list structure."""
        try:
            signal = await page.wait_for_function(
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
