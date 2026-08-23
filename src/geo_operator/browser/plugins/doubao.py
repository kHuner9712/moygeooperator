from __future__ import annotations

from geo_operator.browser.plugins.phase1 import (
    DoubaoPlugin as _PhaseOneDoubaoPlugin,
    PhaseOneSelectors,
)


class DoubaoPlugin(_PhaseOneDoubaoPlugin):
    """Doubao selectors refreshed against the current web UI.

    Prefer stable data-testid and Semi UI attributes for login/composer detection. Keep the
    previously calibrated selectors as fallbacks so older routed/chat states remain supported.
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
            (
                "[class*='message-list-'] .v_list_row:has(.bg-g-send-msg-bubble-bg) "
                ".bg-g-send-msg-bubble-bg"
            ),
        ),
        responses=(
            "[data-testid='receive_message']",
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
