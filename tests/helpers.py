import hashlib
import io
import json
import zipfile


def build_task_package(
    tenant_id: str,
    package_id: str,
    tasks: list[dict[str, object]],
    *,
    tasks_hash: str | None = None,
) -> bytes:
    tasks_bytes = (
        "\n".join(json.dumps(task, ensure_ascii=False) for task in tasks) + "\n"
    ).encode()
    manifest = {
        "schema_version": "1.0",
        "package_type": "GEO_TASK_PACKAGE",
        "tenant_id": tenant_id,
        "package_id": package_id,
        "created_at": "2026-08-21T00:00:00+00:00",
        "files": [
            {
                "path": "tasks.jsonl",
                "sha256": tasks_hash or hashlib.sha256(tasks_bytes).hexdigest(),
            }
        ],
    }
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("manifest.json", json.dumps(manifest))
        archive.writestr("tasks.jsonl", tasks_bytes)
    return output.getvalue()


def make_task(number: int, mode: str = "normal") -> dict[str, object]:
    return {
        "task_id": f"task-{number}",
        "prompt": f"KZQ monitoring question {number}",
        "platform": "mock",
        "account_id": "test",
        "sequence": number,
        "metadata": {"mock_mode": mode},
        "idempotency_key": f"kzq-{number}-{mode}",
    }
