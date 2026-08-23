from __future__ import annotations

from geo_operator.browser.plugins.phase1 import (
    DoubaoPlugin as _PhaseOneDoubaoPlugin,
    PhaseOneSelectors,
)


class DoubaoPlugin(_PhaseOneDoubaoPlugin):
    """Doubao selectors refreshed against the current web UI.

    Prefer stable data-testid and Semi UI attributes for login/composer detection. Keep the
    previously calibrated conversation, response, and deletion selectors unchanged so this
    patch only affects the login/resume boundary that currently blocks execution.
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
        user_queries=_PhaseOneDoubaoPlugin.selectors.user_queries,
        responses=_PhaseOneDoubaoPlugin.selectors.responses,
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
