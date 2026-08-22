# Package Contracts

所有包使用 UTF-8、POSIX 风格相对路径和版本化 manifest。导入时拒绝绝对路径、父目录跳转、重复 ID、未知必填版本和校验值不匹配。

## 1. CLIENT_PROFILE.zip

```text
CLIENT_PROFILE.zip
├── manifest.json
├── profile/client_profile.json
├── website/pages.jsonl
├── website/text/{page_id}.txt
└── source/{original files}
```

manifest 最少包含：

- schema_version
- package_type = CLIENT_PROFILE
- tenant_id
- created_at
- profile_id
- files：path、sha256、size

结构化客户档案仅来自上传资料和官网资料。公网发现证据不得被自动合并进客户档案。

生成完成后必须等待 CLIENT_PROFILE_REVIEW 审批。

## 2. PUBLIC_DISCOVERY.zip

```text
PUBLIC_DISCOVERY.zip
├── manifest.json
├── evidence/index.jsonl
├── evidence/text/{evidence_id}.txt
└── evidence/screenshots/{evidence_id}.png
```

每条 evidence 索引必须包含：

- evidence_id
- tenant_id
- source_url
- captured_at
- source_type
- raw_text_path
- screenshot_path
- credibility_status = AI_PENDING
- content_sha256
- screenshot_sha256
- collection_status
- collection_error（可空）

证据包只保存采集事实，不包含总结、事实判断、可信度评分或档案修改。

## 3. GEO_TASK_PACKAGE.zip

```text
GEO_TASK_PACKAGE.zip
├── manifest.json
└── tasks.jsonl
```

任务字段：

- task_id
- prompt
- platform
- account_id
- sequence
- metadata
- idempotency_key

manifest 包含 schema_version、tenant_id、package_id、created_at 和文件校验值。

导入成功不代表可执行。必须等待 TASK_EXECUTION 审批。

## 4. RESULT_PACKAGE.zip

```text
RESULT_PACKAGE.zip
├── manifest.json
├── results.jsonl
├── responses/{result_id}.txt
├── screenshots/{result_id}.png
└── events/execution_events.jsonl
```

结果字段至少包含：

- result_id
- tenant_id
- task_id
- execution_id
- platform
- prompt
- response_path
- started_at
- completed_at
- completion_signals
- response_sha256
- final_status

生成导出前必须等待 RESULT_EXPORT 审批。导出包不得包含 Cookie、密码、Playwright profile 或其他 Session 数据。
