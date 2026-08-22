from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class PlatformDefinition:
    platform: str
    label: str
    region: str
    phase: int
    home_url: str


PLATFORM_DEFINITIONS = (
    PlatformDefinition("doubao", "豆包", "CN", 1, "https://www.doubao.com/chat/"),
    PlatformDefinition("chatgpt", "ChatGPT", "GLOBAL", 1, "https://chatgpt.com/"),
    PlatformDefinition("deepseek", "DeepSeek", "CN", 2, "https://chat.deepseek.com/"),
    PlatformDefinition("qwen", "千问", "CN", 2, "https://www.qianwen.com/"),
    PlatformDefinition("gemini", "Gemini", "GLOBAL", 2, "https://gemini.google.com/app"),
    PlatformDefinition("yuanbao", "元宝", "CN", 3, "https://yuanbao.tencent.com/chat/"),
    PlatformDefinition("kimi", "Kimi", "CN", 3, "https://www.kimi.com/"),
    PlatformDefinition("grok", "Grok", "GLOBAL", 3, "https://grok.com/"),
    PlatformDefinition("perplexity", "Perplexity", "GLOBAL", 3, "https://www.perplexity.ai/"),
)

PLATFORM_BY_ID = {definition.platform: definition for definition in PLATFORM_DEFINITIONS}
REAL_PLATFORM_IDS = frozenset(PLATFORM_BY_ID)
SUPPORTED_PLATFORM_IDS = REAL_PLATFORM_IDS | {"mock"}
PROHIBITED_PLATFORM_IDS = frozenset(
    {"claude", "claude.ai", "anthropic", "anthropic-claude"}
)

PLATFORM_ALIASES = {
    "豆包": "doubao",
    "元宝": "yuanbao",
    "腾讯元宝": "yuanbao",
    "千问": "qwen",
    "通义千问": "qwen",
    "chat-gpt": "chatgpt",
    "deep-seek": "deepseek",
}


def canonical_platform(value: object, *, allow_mock: bool = True) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError("Platform is required")
    normalized = value.strip().lower()
    if normalized in PROHIBITED_PLATFORM_IDS or normalized.startswith(
        ("claude", "anthropic")
    ):
        raise ValueError("Claude is explicitly prohibited by GEO Operator V2 platform policy")
    platform = PLATFORM_ALIASES.get(normalized, normalized)
    allowed = SUPPORTED_PLATFORM_IDS if allow_mock else REAL_PLATFORM_IDS
    if platform not in allowed:
        raise ValueError(f"Unsupported platform: {value}")
    return platform


def platform_definition(value: object) -> PlatformDefinition:
    return PLATFORM_BY_ID[canonical_platform(value, allow_mock=False)]
