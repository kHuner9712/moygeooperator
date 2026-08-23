from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

from geo_operator.browser.state_machine import ExecutionStateMachine
from geo_operator.core.config import Settings
from geo_operator.core.db import Database

TARGET_FAILURE = "Saved doubao conversation did not hydrate"


def _latest_event(database: Database, execution_id: str) -> dict[str, object] | None:
    return database.one(
        """SELECT event_type,payload_json,created_at
           FROM execution_events
           WHERE execution_id=?
           ORDER BY sequence DESC LIMIT 1""",
        (execution_id,),
    )


def _candidate_rows(database: Database) -> list[dict[str, object]]:
    return database.all(
        """SELECT e.id AS execution_id,e.updated_at,s.id AS effect_id,s.observation_json
           FROM executions e
           JOIN side_effects s ON s.execution_id=e.id
           WHERE e.platform='doubao'
             AND e.state='PAUSED'
             AND s.effect_type='QUERY_SEND'
             AND s.status='INTENT'
           ORDER BY e.updated_at DESC"""
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Explicitly mark one paused Doubao QUERY_SEND intent retryable after the operator "
            "deleted the saved conversation. This is intentionally narrow and refuses ambiguous cases."
        )
    )
    parser.add_argument(
        "--confirm-deleted-conversation",
        action="store_true",
        help="Confirm that the saved Doubao conversation was deleted manually and may be resent.",
    )
    args = parser.parse_args()
    if not args.confirm_deleted_conversation:
        parser.error("--confirm-deleted-conversation is required")

    settings = Settings.from_env()
    database = Database(settings.database_path)
    database.initialize()

    matches: list[dict[str, object]] = []
    inspected: list[tuple[str, str]] = []
    for row in _candidate_rows(database):
        execution_id = str(row["execution_id"])
        event = _latest_event(database, execution_id)
        if not event:
            inspected.append((execution_id, "no latest event"))
            continue
        payload_text = str(event.get("payload_json") or "")
        try:
            payload = json.loads(payload_text)
            payload_text = json.dumps(payload, ensure_ascii=False)
        except (TypeError, ValueError):
            pass
        inspected.append((execution_id, f"{event['event_type']}: {payload_text}"))
        if TARGET_FAILURE in payload_text:
            matches.append(row)

    if len(matches) != 1:
        print(
            "Refusing to modify the database: expected exactly one paused Doubao execution "
            f"with the latest failure '{TARGET_FAILURE}', found {len(matches)}."
        )
        if inspected:
            print("Paused Doubao QUERY_SEND intents inspected:")
            for execution_id, detail in inspected:
                print(f"  {execution_id}: {detail}")
        return 2

    row = matches[0]
    engine = ExecutionStateMachine(database)
    engine.mark_effect_not_attempted(
        str(row["effect_id"]),
        {
            "reason": "OPERATOR_DELETED_CONVERSATION",
            "operator_acknowledged": True,
        },
    )
    print(
        "Recovery marker applied successfully.\n"
        f"Execution: {row['execution_id']}\n"
        "The next resume will treat the pending query as safe to retry instead of restoring the "
        "deleted conversation."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
