from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True, slots=True)
class Settings:
    data_root: Path
    database_path: Path
    host: str = "127.0.0.1"
    port: int = 8765
    browser_channel: str | None = "chrome"
    browser_action_delay_min: float = 0.8
    browser_action_delay_max: float = 2.0

    def __post_init__(self) -> None:
        if self.browser_action_delay_min < 0:
            raise ValueError("Browser action delay minimum cannot be negative")
        if self.browser_action_delay_max < self.browser_action_delay_min:
            raise ValueError("Browser action delay maximum must be at least the minimum")

    @classmethod
    def from_env(cls) -> Settings:
        data_root = Path(os.getenv("GEO_OPERATOR_DATA_ROOT", "./data")).resolve()
        database_path = Path(
            os.getenv("GEO_OPERATOR_DATABASE", str(data_root / "operator.sqlite3"))
        ).resolve()
        host = os.getenv("GEO_OPERATOR_HOST", "127.0.0.1")
        if host not in {"127.0.0.1", "localhost", "::1"}:
            raise ValueError("Local control may only bind to a loopback address")
        return cls(
            data_root=data_root,
            database_path=database_path,
            host=host,
            port=int(os.getenv("GEO_OPERATOR_PORT", "8765")),
            browser_channel=os.getenv("GEO_OPERATOR_BROWSER_CHANNEL", "chrome") or None,
            browser_action_delay_min=float(
                os.getenv("GEO_OPERATOR_BROWSER_ACTION_DELAY_MIN", "0.8")
            ),
            browser_action_delay_max=float(
                os.getenv("GEO_OPERATOR_BROWSER_ACTION_DELAY_MAX", "2.0")
            ),
        )
