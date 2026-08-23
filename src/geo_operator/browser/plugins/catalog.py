from __future__ import annotations

from geo_operator.browser.plugins.additional import (
    DeepSeekPlugin,
    GrokPlugin,
    KimiPlugin,
    PerplexityPlugin,
    QwenPlugin,
    YuanbaoPlugin,
)
from geo_operator.browser.plugins.doubao import DoubaoPlugin
from geo_operator.browser.plugins.gemini import GeminiPlugin
from geo_operator.browser.plugins.phase1 import ChatGPTPlugin, ObservedWebChatPlugin
from geo_operator.platforms import REAL_PLATFORM_IDS, canonical_platform

PLUGIN_FACTORIES: dict[str, type[ObservedWebChatPlugin]] = {
    "doubao": DoubaoPlugin,
    "chatgpt": ChatGPTPlugin,
    "deepseek": DeepSeekPlugin,
    "qwen": QwenPlugin,
    "gemini": GeminiPlugin,
    "yuanbao": YuanbaoPlugin,
    "kimi": KimiPlugin,
    "grok": GrokPlugin,
    "perplexity": PerplexityPlugin,
}

if set(PLUGIN_FACTORIES) != set(REAL_PLATFORM_IDS):
    raise RuntimeError("Live plugin catalog and platform policy are out of sync")


def live_plugin(platform: object) -> ObservedWebChatPlugin:
    canonical = canonical_platform(platform, allow_mock=False)
    return PLUGIN_FACTORIES[canonical]()


def live_plugins() -> list[ObservedWebChatPlugin]:
    return [factory() for factory in PLUGIN_FACTORIES.values()]
