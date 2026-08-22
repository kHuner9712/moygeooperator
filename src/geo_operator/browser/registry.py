from __future__ import annotations

import json
from typing import Any

from geo_operator.browser.plugins.mock import MockAIPlugin
from geo_operator.browser.plugins.phase1 import ChatGPTPlugin, DoubaoPlugin
from geo_operator.core.db import Database


class PluginRegistry:
    def __init__(self, database: Database, control_base_url: str) -> None:
        self.database = database
        self.control_base_url = control_base_url

    def for_execution(self, execution: dict[str, Any]) -> Any:
        task = self.database.one("SELECT * FROM tasks WHERE id=?", (execution["task_id"],))
        if not task:
            raise ValueError("Execution task is missing")
        metadata = json.loads(str(task["metadata_json"]))
        platform = str(execution["platform"])
        if platform == "mock":
            return MockAIPlugin(self.control_base_url, str(metadata.get("mock_mode", "normal")))
        if platform == "chatgpt":
            return ChatGPTPlugin()
        if platform == "doubao":
            return DoubaoPlugin()
        raise ValueError(f"Platform plugin is not implemented: {platform}")
