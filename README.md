# GEO Operator V2

GEO Operator V2 是本地运行的内部 GEO 服务执行工具。它负责多租户资料、原始公网证据、任务包、可见浏览器执行、结果保存和结果包导出；不负责 GEO 策略分析、内容生成、商业决策、CRM 或商业用户系统。

## 已实现范围

- Python 3.12、SQLite WAL、外键、租户文件隔离和原子文件写入
- 客户原始资料导入与机械抽取：TXT/Markdown/CSV/JSON、PDF、Word、Excel 和常见图片；保存原文件、提取文本、SHA-256、MIME、大小和元数据
- 官网安全抓取：只允许公网 HTTP(S)、同源队列、重定向复核、页面数/体积/超时上限，并持久化页面文本与失败原因
- 客户档案机械整理、`CLIENT_PROFILE_REVIEW` 人工审批和完整 `CLIENT_PROFILE.zip`（结构化档案、官网索引/文本、关联原文件）
- Public Discovery 自动 URL 采集与手工证据录入：URL、抓取时间、原始文本、离线安全截图、来源类型、`AI_PENDING` 可信度字段，以及 `PUBLIC_DISCOVERY.zip`
- SQLite `artifacts` 目录登记所有原子写入文件和导出包的路径、SHA-256、大小、MIME 与时间
- `GEO_TASK_PACKAGE.zip` 安全导入：schema、tenant、SHA-256、ZIP 路径、平台、任务 ID、账号 ID、序号和幂等键校验
- 持久化 Browser Execution 状态机、外部副作用 intent/confirmed 账本、回答 checkpoint、实时截图和结果原子提交
- 独立 Browser Worker、执行租约与运行心跳、过期租约回收、Session 单执行锁、persistent Chromium profile；控制台可区分 API 存活与 Worker 失联，并显式启用 Chromium sandbox
- 验证码、登录失效、安全验证、限流、账号受限、DOM 异常和完成不确定时 fail closed 暂停，禁止自动绕过
- 人工接管后由独立 Worker 重新验证；复核失败保留暂停状态和截图证据
- 验证类暂停按 tenant/platform/account 阻塞所有任务包，Session 显示 HUMAN_TAKEOVER_REQUIRED；仅人工 Continue + Worker 复核可解除
- 已校准的平台明确未投递标记会保留原 INTENT 和完整审计链，验证完成后才允许安全重试
- 同一任务包严格按序执行；前序未 `COMPLETED` 时后序任务不能被领取
- 回答保存和聊天删除均确认后才允许完成；结果导出前需要 `RESULT_EXPORT` 人工审批
- 面向非技术操作者的本机控制台：五步工作向导、中文状态和异常说明、待办审批、任务筛选与进度条、暂停/继续、问题截图、结果导出，以及折叠收纳的平台登录设置
- 真实平台校准证据持久化：仅保存可见 DOM 结构属性，不读取正文、Cookie 或浏览器存储；支持人工切换菜单/确认框后继续结构采样
- Mock AI 故障注入，以及 KZQ 10 问完整验收

九个平台保留在统一平台目录、任务校验和状态模型中：国内为豆包、元宝、千问、DeepSeek、Kimi，国外为 Grok、Gemini、ChatGPT、Perplexity。除千问外的八个平台均已完成真实登录、流式回答实时保存与校准会话删除验证并进入 `EXECUTION_READY`。Perplexity 实测保存 20 个长流式 checkpoint，观察到独立用户/助手容器、“停止响应（Esc）”控件、最终回答操作区和 UUID 会话 URL，并验证删除确认框、目标历史项 1→0 及登录首页健康。千问因自动发送持续触发 Baxia 跨域滑块、人工验证无法完成且平台随后返回“系统超时”，已按操作者决定标记为 `INTEGRATION_PAUSED`：Session 打开、结构校准和 Worker 调度全部关闭，禁止继续重试或自动绕过。Claude（包括 Claude/Anthropic 常见标识）是明确禁止的平台，不创建插件、不开放 Session，也不接受任务包。

## 安装

建议使用 uv，并固定 Python 3.12：

```powershell
uv python install 3.12
uv sync --python 3.12 --extra dev
uv run playwright install chromium
```

默认配置见 `.env.example`。控制台强制绑定 loopback 地址，不能暴露到公网。
生产 Worker 默认在每次真实发送前随机等待 0.8–2.0 秒；可用 \`GEO_OPERATOR_BROWSER_ACTION_DELAY_MIN\` 与 \`GEO_OPERATOR_BROWSER_ACTION_DELAY_MAX\` 调整。该等待只用于低频操作节奏，回答完成仍只依据平台 DOM 多信号与稳定窗口。


## 运行方式

生产式本地运行仍保持控制台与 Browser Worker 两个独立进程，但 Windows 启动器会统一管理它们。

正常使用时，只需双击项目根目录的 `START_GEO_OPERATOR.cmd`。启动器会：

- 检查并启动本地控制台；
- 检查并启动 Browser Worker；
- 避免重复启动两个进程；
- 等待控制台健康检查和 Browser Worker 持续心跳通过；
- 自动打开 <http://127.0.0.1:8765>。

运行日志分别保存在 `logs/launcher.log`、`logs/server.stdout.log`、`logs/server.stderr.log`、`logs/worker.stdout.log` 和 `logs/worker.stderr.log`。正常操作不再需要手工运行 Worker 命令。

仅在开发调试时，才分别运行：

```powershell
uv run geo-operator
uv run geo-operator-worker
```

控制台负责审批、暂停、继续和调度信号；Browser Worker 负责浏览器执行、租约和人工处理后的页面复核。

## 真实账号首次登录

首次登录时先只启动控制台：

1. 创建或选择客户租户。
2. 在九个平台面板中点击目标平台的“系统 Chrome 登录”。该窗口由本机 Google Chrome 直接启动，没有 Playwright 连接或自动化启动参数。
3. 手工登录并处理验证码/安全验证；登录成功后关闭这个系统 Chrome 窗口，使 persistent profile 完整落盘。
4. 点击“检测登录/结构”。系统会用同一 profile 启动系统 Chrome channel；快照只返回可见 DOM 的标签和属性，不读取页面文本、Cookie、本地存储或截图。
5. 点击“关闭校准 Chrome 并释放”。浏览器关闭，独立 Worker 才能取得该 profile。
6. 若使用一键启动器，Worker 已由启动器统一管理；不要让人工登录窗口、校准窗口与 Worker 同时占用同一 Session profile。

运行中若 Worker 因验证码、登录失效、安全验证或页面异常暂停，直接在 Worker 打开的可见浏览器中人工处理；随后在控制台点击 `Continue`。Worker 会先复核页面，安全后才从保存的 `resume_state` 继续。

## KZQ 任务包

创建租户后，从控制台或 `/api/tenants` 取得 `tenant_id`。生成不少于 10 问的验收包：

```powershell
uv run python scripts/create_kzq_test_package.py `
  --tenant-id <TENANT_ID> `
  --platform mock `
  --account-id manual `
  --package-id kzq-round-1 `
  --output KZQ_GEO_TASK_PACKAGE.zip
```

`--platform` 接受九个平台的规范 ID；当前除 `qwen` 外均为 `EXECUTION_READY`。千问为 `INTEGRATION_PAUSED`，即使任务包包含千问任务也禁止打开 Session 或进入 Worker 调度。导入后必须先批准客户档案，再批准 `TASK_EXECUTION`。所有任务完成后申请并批准 `RESULT_EXPORT`，才能导出 `RESULT_PACKAGE.zip`。

## 验证

```powershell
uv run ruff check src tests scripts
uv run pytest -q
```

浏览器测试覆盖慢回答、停顿、长回答、页面刷新、崩溃恢复、重复发送防护、保存失败恢复、删除失败阻断下一题、人工复核成功/失败、验证码、限流、账号限制、DOM 变化、永不完成和 KZQ 10 问结果包。

## 设计文档

- `docs/GEO_Operator_V2_Base_Specification.md`
- `docs/CODEX_DEVELOPMENT_INSTRUCTION.md`
- `docs/ARCHITECTURE_DESIGN.md`
- `docs/PACKAGE_CONTRACTS.md`
- `docs/BROWSER_EXECUTION_DESIGN.md`
- `docs/DEVELOPMENT_STATUS.md`

## 真实平台上线前校准

所有平台选择器只能来自已观察的真实页面和官方前端资源。平台状态分为 `EXECUTION_READY`、`CALIBRATION_REQUIRED` 与 `INTEGRATION_PAUSED`；暂停接入的平台禁止 Session 打开、校准和 Worker 调度，只有操作者明确恢复后才能重新进入校准流程。豆包虚拟列表不使用消息总数判定关联，而是校验末条助手回答在末条用户问题之后。任何无法唯一识别、信号冲突、登录失效或安全验证都会进入 `PAUSED`，禁止自动绕过。明确禁止 Claude：不得新增 Claude/Anthropic 插件、Session 入口、任务平台或兼容别名。
