from __future__ import annotations

from geo_operator.browser.plugins.phase1 import ObservedWebChatPlugin, PhaseOneSelectors


class CalibrationPendingPlugin(ObservedWebChatPlugin):
    """Safe onboarding shell for a platform that still needs authenticated DOM calibration."""

    observed_at = None
    deletion_action_verified = False

    def calibration_status(self) -> dict[str, object]:
        status = super().calibration_status()
        status["support_status"] = "CALIBRATION_REQUIRED"
        status["dispatch_eligible"] = False
        return status


class DeepSeekPlugin(CalibrationPendingPlugin):
    phase = 2
    name = "deepseek"
    home_url = "https://chat.deepseek.com/"
    conversation_link_selectors = ("a[href*='/a/chat/s/']",)
    conversation_path_prefixes = ("/a/chat/s/",)
    selectors = PhaseOneSelectors(
        login_indicators=("button:has-text('登录')", "button:has-text('Log in')"),
        prompt_inputs=("textarea#chat-input", "textarea", "[contenteditable='true']"),
        send_controls=(),
    )


class QwenPlugin(CalibrationPendingPlugin):
    phase = 2
    name = "qwen"
    home_url = "https://chat.qwen.ai/"
    conversation_link_selectors = ("a[href*='/c/']",)
    conversation_path_prefixes = ("/c/",)
    selectors = PhaseOneSelectors(
        login_indicators=("button:has-text('Log in')", "button:has-text('登录')"),
        prompt_inputs=("textarea", "[contenteditable='true'][role='textbox']"),
        send_controls=(),
    )


class GeminiPlugin(CalibrationPendingPlugin):
    phase = 2
    name = "gemini"
    home_url = "https://gemini.google.com/app"
    conversation_link_selectors = ("a[href^='/app/']",)
    conversation_path_prefixes = ("/app/",)
    selectors = PhaseOneSelectors(
        login_indicators=("a:has-text('Sign in')", "button:has-text('Sign in')"),
        prompt_inputs=(
            "rich-textarea [contenteditable='true']",
            "div.ql-editor[contenteditable='true']",
        ),
        send_controls=(),
    )


class YuanbaoPlugin(CalibrationPendingPlugin):
    phase = 3
    name = "yuanbao"
    home_url = "https://yuanbao.tencent.com/chat/"
    conversation_link_selectors = ("a[href*='/chat/']",)
    conversation_path_prefixes = ("/chat/",)
    selectors = PhaseOneSelectors(
        login_indicators=("button:has-text('登录')",),
        prompt_inputs=("textarea", "[contenteditable='true'][role='textbox']"),
        send_controls=(),
    )


class KimiPlugin(CalibrationPendingPlugin):
    phase = 3
    name = "kimi"
    home_url = "https://www.kimi.com/"
    conversation_link_selectors = ("a[href*='/chat/']",)
    conversation_path_prefixes = ("/chat/",)
    selectors = PhaseOneSelectors(
        login_indicators=("button:has-text('登录')", "button:has-text('Log in')"),
        prompt_inputs=("[contenteditable='true'][role='textbox']", "textarea"),
        send_controls=(),
    )


class GrokPlugin(CalibrationPendingPlugin):
    phase = 3
    name = "grok"
    home_url = "https://grok.com/"
    conversation_link_selectors = ("a[href*='/c/']",)
    conversation_path_prefixes = ("/c/",)
    selectors = PhaseOneSelectors(
        login_indicators=("button:has-text('Sign in')", "a:has-text('Sign in')"),
        prompt_inputs=("textarea", "[contenteditable='true'][role='textbox']"),
        send_controls=(),
    )


class PerplexityPlugin(CalibrationPendingPlugin):
    phase = 3
    name = "perplexity"
    home_url = "https://www.perplexity.ai/"
    conversation_link_selectors = ("a[href*='/search/']",)
    conversation_path_prefixes = ("/search/",)
    selectors = PhaseOneSelectors(
        login_indicators=("button:has-text('Sign in')", "button:has-text('Log in')"),
        prompt_inputs=("textarea", "[contenteditable='true'][role='textbox']"),
        send_controls=(),
    )
