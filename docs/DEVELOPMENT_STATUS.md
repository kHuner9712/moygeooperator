# GEO Operator V2 开发状态

更新时间：2026-08-23

本文件记录可由代码、数据库、测试或真实页面证据验证的状态。没有经过真实账号页面验证的平台不得标为完成。

## 功能模块

| 模块 | 状态 | 验证边界 |
|---|---|---|
| 多租户与文件隔离 | 完成 | SQLite 外键、tenant 路径校验、原子写入 |
| Source Ingestion | 完成 | TXT/MD/CSV/JSON、PDF、DOCX、XLSX/XLSM、常见图片 |
| 官网抓取 | 完成 | 公网地址校验、同源、重定向复核、页数/体积/超时上限、失败留痕 |
| Client Profile Builder | 完成 | 只对上传资料与官网页面生成机械索引；不包含 Public Discovery；生成后等待人工审批 |
| Public Discovery | 完成 | 自动 URL 采集和手工录入；原文、截图、URL、时间、类型、AI_PENDING；独立 ZIP |
| 任务包导入 | 完成 | schema、tenant、hash、ZIP 路径、平台、ID、序号和幂等校验 |
| Human Approval Gate | 完成 | CLIENT_PROFILE_REVIEW、TASK_EXECUTION、RESULT_EXPORT；统一 WAIT_HUMAN_APPROVAL |
| Browser 状态机 | 完成 | 持久状态、合法迁移、事件日志、副作用账本 |
| 等待与完成判定 | 完成 | streaming/stop/input/final/error 多信号和稳定窗口 |
| 实时保存 | 完成 | checkpoint、截图、最终结果原子提交 |
| 断点恢复 | 完成 | 执行租约、心跳、resume_state、幂等发送、恢复 URL |
| Session 管理 | 完成 | tenant/platform/account 隔离、persistent profile、单执行锁、原生 Chrome 登录 |
| 人工接管 | 完成 | CAPTCHA、登录失效、安全验证、限流、账号限制、页面异常均暂停，禁止绕过 |
| 结果导出 | 完成 | RESULT_EXPORT 审批、started_at/completed_at、回答/截图/事件/manifest |
| 本地控制界面 | 完成 | 客户、资料、官网、证据、档案、审批、任务、Session、暂停/继续、进度、导出 |
| artifacts 元数据 | 完成 | 路径、SHA-256、大小、MIME、类型、时间 |

## 平台上线状态

| Phase | 平台 | 状态 | 说明 |
|---|---|---|---|
| 1 | ChatGPT | EXECUTION_READY | 已完成真实 DOM、流式完成和删除验证 |
| 1 | 豆包 | EXECUTION_READY | 已完成真实 DOM、流式完成和删除验证 |
| 2 | DeepSeek | EXECUTION_READY | 已完成真实登录、发送意图、流式/最终结构、回答落盘及校准会话删除验证 |
| 2 | 千问 | CALIBRATION_REQUIRED | 已完成真实登录、唯一发送控件、用户/回答容器、流式/完成标记与实时保存校准；2026-08-23 固定问题返回“系统超时，请稍后重试”，已按平台错误失败关闭；停止控件、会话恢复/删除和正常回答仍待验证 |
| 2 | Gemini | EXECUTION_READY | 已完成真实登录、唯一发送、2 次实时 checkpoint、流式停止/最终结构、回答落盘、目标会话删除及历史缺失复核 |
| 3 | 元宝 | CALIBRATION_REQUIRED | 已有独立 Session、官方入口、结构采样和 fail-closed 门禁 |
| 3 | Kimi | CALIBRATION_REQUIRED | 已有独立 Session、官方入口、结构采样和 fail-closed 门禁 |
| 3 | Grok | CALIBRATION_REQUIRED | 已有独立 Session、官方入口、结构采样和 fail-closed 门禁 |
| 3 | Perplexity | CALIBRATION_REQUIRED | 已有独立 Session、官方入口、结构采样和 fail-closed 门禁 |
| 禁止 | Claude / Anthropic | PROHIBITED | 不创建插件、Session 或任务入口 |

`CALIBRATION_REQUIRED` 不是“支持完成”。这些平台在以下证据全部完成前，API 和 Worker 都禁止发送真实问题：

1. 人工登录并关闭原生 Chrome，使 Session 完整落盘；
2. 保存登录态、输入框、发送按钮、用户消息、助手回答、流式指示和停止按钮的仅结构快照；
3. 经固定测试问题验证等待逻辑、实时 checkpoint 和最终保存；
4. 人工打开会话菜单和删除确认框，保存仅结构快照；
5. 实际删除校准会话并验证历史记录中目标会话消失；
6. 完成验证码/登录失效/安全验证/页面异常的暂停与人工继续演练；
7. 完成该平台的串行任务包与 RESULT_PACKAGE 端到端验收。

## 交付校验

每次发布至少执行：

```powershell
uv run ruff check src tests scripts
uv run pytest -q
```

还必须从干净克隆安装并导入 `geo_operator.exports.ResultPackageService`，防止忽略规则再次漏掉源代码。真实平台状态以持久化校准证据与端到端结果为准，不能仅凭选择器配置或单元测试提升为 `EXECUTION_READY`。
