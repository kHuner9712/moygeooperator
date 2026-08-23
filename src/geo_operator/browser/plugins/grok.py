from __future__ import annotations

from geo_operator.browser.plugins.additional import GrokPlugin as _AdditionalGrokPlugin


class GrokPlugin(_AdditionalGrokPlugin):
    """Grok adapter with explicit xAI edge/WAF block detection.

    xAI can return a site-level block page before the Grok application or login UI mounts. Treat
    that page as a security challenge instead of a normal logged-out state so the worker pauses and
    does not repeatedly retry the blocked request.
    """

    observed_at = "2026-08-24"

    _edge_block_markers = (
        "sorry, you have been blocked",
        "you have been blocked",
        "you are unable to access x.ai",
        "您已被屏蔽",
        "您无法访问x.ai",
        "您无法访问 x.ai",
    )

    async def detect_human_intervention(self, page):
        try:
            body = (await page.locator("body").inner_text()).lower()
        except Exception:
            body = ""
        if any(marker in body for marker in self._edge_block_markers):
            return "SECURITY_CHALLENGE"
        return await super().detect_human_intervention(page)
