from __future__ import annotations

import argparse
import hashlib
import json
import zipfile
from datetime import UTC, datetime
from pathlib import Path

DEFAULT_QUESTIONS = [
    "请介绍 KZQ 品牌及其主要业务。",
    "KZQ 的核心产品或服务是什么？",
    "哪些用户可能适合选择 KZQ？",
    "KZQ 与同类品牌相比有哪些公开可见的特点？",
    "用户通常如何评价 KZQ？",
    "KZQ 在哪些地区或市场开展业务？",
    "选择 KZQ 前应关注哪些信息？",
    "KZQ 有哪些公开可查的官方信息来源？",
    "目前有哪些与 KZQ 相关的常见问题？",
    "如果需要进一步了解 KZQ，应查询哪些可靠来源？",
]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tenant-id", required=True)
    parser.add_argument("--platform", choices=("mock", "chatgpt", "doubao"), default="mock")
    parser.add_argument("--account-id", default="manual")
    parser.add_argument("--package-id", default="kzq-round-1")
    parser.add_argument("--questions", type=Path)
    parser.add_argument("--output", type=Path, default=Path("KZQ_GEO_TASK_PACKAGE.zip"))
    args = parser.parse_args()

    questions = (
        [
            line.strip()
            for line in args.questions.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]
        if args.questions
        else DEFAULT_QUESTIONS
    )
    if len(questions) < 10:
        raise SystemExit("KZQ acceptance package requires at least 10 questions")
    tasks = [
        {
            "task_id": f"kzq-{index:03d}",
            "prompt": question,
            "platform": args.platform,
            "account_id": args.account_id,
            "sequence": index,
            "metadata": {"mock_mode": "normal"} if args.platform == "mock" else {},
            "idempotency_key": f"{args.package_id}-{args.platform}-{index:03d}",
        }
        for index, question in enumerate(questions, 1)
    ]
    tasks_bytes = (
        "\n".join(json.dumps(task, ensure_ascii=False) for task in tasks) + "\n"
    ).encode()
    manifest = {
        "schema_version": "1.0",
        "package_type": "GEO_TASK_PACKAGE",
        "tenant_id": args.tenant_id,
        "package_id": args.package_id,
        "created_at": datetime.now(UTC).isoformat(),
        "files": [{"path": "tasks.jsonl", "sha256": hashlib.sha256(tasks_bytes).hexdigest()}],
    }
    with zipfile.ZipFile(args.output, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("manifest.json", json.dumps(manifest, ensure_ascii=False, indent=2))
        archive.writestr("tasks.jsonl", tasks_bytes)
    print(args.output.resolve())


if __name__ == "__main__":
    main()
