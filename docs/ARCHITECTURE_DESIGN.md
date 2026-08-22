# GEO Operator V2 Architecture Design

## 1. 目标与边界

GEO Operator V2 是本地运行的内部 GEO 交付执行工具。它负责多租户资料、任务、浏览器执行、结果留存和导出，不负责策略分析、内容生成、商业决策、CRM、收费或商业用户系统。

设计优先级：

1. 结果不丢失
2. 不重复发送问题
3. 可暂停、可人工接管、可恢复
4. 租户和平台 Session 隔离
5. 账号安全优先于执行速度
6. 平台插件可替换

## 2. 部署形态

采用模块化单体和独立 Browser Worker：

- Local Control：FastAPI 和轻量 HTML 界面，仅绑定 127.0.0.1。
- Application Core：用例编排、审批门和业务规则。
- SQLite：元数据、状态机快照、事件、审批和结果事实来源。
- Artifact Store：租户目录中的原始文件、截图、文本和 ZIP。
- Browser Worker：执行 Playwright 状态机，与控制界面进程隔离。
- Platform Plugins：平台特定页面识别和操作。

第一阶段不引入 Redis、Celery、消息队列或微服务。

## 3. 模块边界

### Tenant Manager

创建 tenant_id，解析和校验租户路径。所有数据库记录及文件路径必须携带 tenant_id。禁止接受可逃逸租户根目录的相对路径。

### Source Ingestion

保存用户原始资料，提取可机械获得的文本和元数据。不得生成策略结论。

### Client Profile Builder

整理上传资料和官网内容，生成结构化档案草稿。完成后创建 CLIENT_PROFILE_REVIEW 审批请求并进入 WAIT_HUMAN_APPROVAL。

### Public Discovery Evidence Collection

只采集公网原始证据。保存 URL、抓取时间、原始文本、截图、来源类型及 AI_PENDING 可信度状态。不得写入或修改客户档案，不得自动评分。

### Task Package Manager

验证版本化任务包、平台名、任务 ID 和幂等键。导入后创建 TASK_EXECUTION 审批请求。未经批准不得创建可运行执行。

### Approval Gate

审批阶段：

- CLIENT_PROFILE_REVIEW
- TASK_EXECUTION
- RESULT_EXPORT

统一等待状态为 WAIT_HUMAN_APPROVAL，同时持久化 approval_stage 和 resume_state。审批记录不可覆盖，只追加新决定。

### Browser Execution Engine

持久化状态机驱动所有平台操作。浏览器不是状态事实来源。每次外部副作用采用“记录意图、执行、观察确认”的方式，恢复时先对账再决定是否重试。

### Result Store

等待回答期间保存部分回答检查点；确认完成后原子保存最终结果和证据。结果持久化成功前禁止删除聊天或进入下一任务。

### Export Manager

生成 CLIENT_PROFILE.zip、PUBLIC_DISCOVERY.zip 和 RESULT_PACKAGE.zip。结果导出必须先通过 RESULT_EXPORT 审批。

### Local Control

提供客户状态、审批、执行进度、暂停、继续、人工接管提示和导出。它不是商业后台，默认不监听公网接口。

## 4. 数据所有权

SQLite 保存：

- tenants
- source_assets
- website_pages
- client_profiles
- discovery_evidence
- task_packages
- tasks
- approvals
- browser_sessions
- platform_calibrations
- executions
- execution_events
- response_checkpoints
- results
- artifacts
- exports

文件系统保存：

- 原始上传文件
- 抽取文本
- 网页原始文本
- 截图
- 浏览器持久化 Session
- 导出 ZIP

文件写入使用临时文件加同目录原子替换。数据库保存 SHA-256、大小、MIME 类型和相对路径。

## 5. 租户目录

```text
data/tenants/{tenant_id}/
├── source/
│   └── extracted/
├── website/
│   └── text/
├── profile/
├── discovery/
│   ├── text/
│   └── screenshots/
├── tasks/
├── calibration/
├── results/
│   ├── checkpoints/
│   └── screenshots/
├── exports/
└── sessions/
    └── {platform}/{account_id}/
```

## 6. 并发和锁

- 一个 browser_session 同时只有一个有效执行租约。
- 验证类暂停使用 tenant_id + platform + account_id 平台屏障，阻止同账号的其他任务包绕过人工接管。
- 屏障只能由人工 Continue 触发复核，不能由定时器、重试次数或其他任务自动解除。
- 租约包含 owner_id、acquired_at 和 heartbeat_at。
- Worker 崩溃后，过期租约可被恢复流程接管。
- 同一任务的 query_fingerprint 用于恢复对账，不允许无条件重复发送。
- SQLite 使用 WAL、外键和短事务。

## 7. 安全原则

- 首次登录由人工完成。
- 不保存明文账号密码。
- Session、Cookie 和浏览器数据不进入导出包或日志。
- 验证码、登录失效、安全验证、限流及页面异常必须暂停。
- 不实现验证码破解、自动安全验证、指纹伪造或绕过平台限制。
- 默认低频串行执行，可配置任务间隔和每日上限。

## 8. 平台阶段

- Phase 1：豆包、ChatGPT
- Phase 2：DeepSeek、千问、Gemini
- Phase 3：元宝、Kimi、Grok、Perplexity

平台策略使用统一允许清单。Claude/Anthropic 被明确禁止，任务导入、Session、插件解析和控制界面都必须拒绝，不能作为未知平台静默降级。

新增平台分两级：

- `CALIBRATION_REQUIRED`：仅开放官方入口人工登录、独立 persistent Session 和隐私安全的结构快照；Worker 调度门禁关闭。
- `EXECUTION_READY`：回答完成信号、实时保存、幂等恢复、删除及删除确认均经真实账号验证，才允许执行任务。

真实平台插件开发前，必须先通过模拟平台的状态机、崩溃恢复和保存测试。
