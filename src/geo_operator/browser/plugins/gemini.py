from __future__ import annotations

import re

from geo_operator.browser.plugins.additional import GeminiPlugin as _AdditionalGeminiPlugin
from geo_operator.browser.plugins.phase1 import PhaseOneSelectors, PluginPageAbnormal


class GeminiPlugin(_AdditionalGeminiPlugin):
    """Gemini adapter refreshed for the current web conversation DOM.

    Gemini still exposes semantic user-query/model-response elements, but the text leaf wrappers
    have changed over time. Keep the previous selectors as fallbacks while preferring current
    query/response leaves and current streaming signals. Query confirmation intentionally walks
    selector priorities instead of unioning nested containers, so the same turn cannot be counted
    twice when both a semantic wrapper and an inner text node are present.
    """

    observed_at = "2026-08-23"

    _query_candidates = (
        "user-query-content .query-content .query-text",
        "user-query .query-text",
        ".user-query-bubble-with-background",
        ".user-query",
        "user-query-content .query-content",
        "user-query-content",
        "user-query",
        '[data-message-author="user"]',
        '[data-message-author-role="user"]',
    )

    selectors = PhaseOneSelectors(
        login_indicators=_AdditionalGeminiPlugin.selectors.login_indicators,
        prompt_inputs=(
            "div.ql-editor[contenteditable='true'][role='textbox']",
            "rich-textarea [contenteditable='true']",
            "div.ql-editor[contenteditable='true']",
            "[aria-label='Enter a prompt here'][contenteditable='true']",
            "[contenteditable='true'][role='textbox']",
        ),
        send_controls=(
            "button[aria-label='Send message']",
            "button[aria-label*='Send' i]",
            "input-container .send-button button",
            "input-container button[aria-label='发送']",
        ),
        user_queries=(
            (
                "user-query-content .query-content .query-text, "
                "user-query .query-text, .user-query-bubble-with-background, .user-query, "
                "user-query-content .query-content"
            ),
        ),
        responses=(
            (
                "model-response message-content .markdown, "
                "model-response .model-response-text .markdown, "
                "model-response message-content, .model-response-text, .response-content, "
                "structured-content-container.model-response-text .markdown.markdown-main-panel"
            ),
        ),
        streaming_indicators=(
            "[aria-busy='true']",
            "pending-response",
            "button[aria-label*='Stop' i]",
            "input-container .send-button.stop button[aria-label='停止回答']",
        ),
        stop_controls=(
            "button[aria-label*='Stop' i]",
            "input-container .send-button.stop button[aria-label='停止回答']",
        ),
        error_indicators=_AdditionalGeminiPlugin.selectors.error_indicators,
        rate_limit_indicators=_AdditionalGeminiPlugin.selectors.rate_limit_indicators,
        security_indicators=_AdditionalGeminiPlugin.selectors.security_indicators,
        conversation_menu_controls=_AdditionalGeminiPlugin.selectors.conversation_menu_controls,
        delete_controls=_AdditionalGeminiPlugin.selectors.delete_controls,
        delete_confirm_controls=_AdditionalGeminiPlugin.selectors.delete_confirm_controls,
        final_response_descendants=_AdditionalGeminiPlugin.selectors.final_response_descendants,
        query_failure_descendants=_AdditionalGeminiPlugin.selectors.query_failure_descendants,
    )

    def normalize_query_text(self, value: str) -> str:
        normalized = super().normalize_query_text(value)
        return re.sub(
            r"^(?:You said|You asked|你说|你问)\s*[:：]?\s*",
            "",
            normalized,
            flags=re.IGNORECASE,
        )

    async def query_exists(self, page, prompt: str) -> bool:
        """Confirm one exact Gemini user turn without double-counting nested wrappers."""
        expected = self.normalize_query_text(prompt)
        matched_nodes: set[object] = set()
        matches = 0

        for selector in self._query_candidates:
            nodes = page.locator(selector)
            for index in range(await nodes.count()):
                node = nodes.nth(index)
                handle = await node.element_handle()
                if handle is None:
                    continue
                identity = await handle.evaluate("node => node")
                # Playwright JSHandle objects are not reliably hashable across implementations;
                # use the node's text/selector priority to avoid duplicate exact matches instead.
                actual = self.normalize_query_text(await node.inner_text())
                if actual != expected:
                    continue
                marker = (selector, index, actual)
                if marker in matched_nodes:
                    continue
                matched_nodes.add(marker)
                matches += 1
                # A more specific selector may match the same DOM turn as a later wrapper.
                # One exact hit is sufficient; do not walk broader wrappers and count it again.
                return True

        if matches > 1:
            raise PluginPageAbnormal("Multiple identical Gemini user query nodes found")
        return False
