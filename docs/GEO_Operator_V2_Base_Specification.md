
# GEO Operator V2 Base Specification

## 定位
GEO Operator 是 GEO 交付执行脚本，不负责分析、策略、内容生成。
负责：
- 客户资料采集
- 信息整理
- 任务执行
- 浏览器操作
- AI平台答案采集
- 结果导出

## 核心原则
AI负责判断，Operator负责机械执行。

## 重要修正

### 1. 反脚本拦截设计
目标平台可能检测自动化行为，因此必须设计：
- Playwright真实浏览器环境
- 人工首次登录
- Session持久化
- 可配置操作节奏
- 随机等待
- 异常暂停
- 不绕过平台安全机制
- 不进行高频批量请求

Operator必须优先保证账号安全。

### 2. 客户资料采集
客户资料不要求完整。

输入：
- 官网URL
- PDF
- Word
- Excel
- 图片
- TXT
- 门店资料

系统同时进行：
A. 用户上传资料解析
B. 官网抓取
C. 公网公开信息证据采集

输出：
- CLIENT_PROFILE.zip
- PUBLIC_DISCOVERY.zip

CLIENT_PROFILE.zip包含：
- 原始资料
- 网站信息
- 结构化客户档案

客户资料整理完成后必须进入人工审批，未经批准不得进入后续任务执行流程。

### 2.1 Public Discovery Evidence Collection

公网搜索不是生成客户档案，而是生成可追溯的原始证据包。该模块不进行归纳、合并、可信度评分或客户画像更新。

每条证据必须保存：
- 来源URL
- 抓取时间
- 原始文本
- 截图
- 来源类型
- 可信度字段（待AI分析）

输出：
- PUBLIC_DISCOVERY.zip

证据包必须包含版本化manifest、证据索引、原始文本和截图。所有判断交由人工和外部AI完成。

### 2.2 Human Approval Gate

以下节点必须进入人工审批：
- 客户资料整理完成后
- GEO任务包执行前
- 结果导出前

统一使用状态：
- WAIT_HUMAN_APPROVAL

审批决定、审批时间、审批阶段、操作者标识和备注必须持久化并可审计。拒绝或尚未审批时，系统不得继续后续步骤。

### 3. 平台插件体系

国内：
- 豆包
- 元宝
- 千问
- Kimi
- DeepSeek

国外：
- ChatGPT
- Gemini
- Grok
- Perplexity

Claude被明确禁止接入。任务包、Session、插件注册和本地控制界面均不得接受 Claude 或 Anthropic 标识，也不得以兼容别名、聚合入口或隐藏开关绕过此限制。

平台必须插件化，根据客户选择启用。

平台开发顺序：

Phase 1：
- 豆包
- ChatGPT

Phase 2：
- DeepSeek
- 千问
- Gemini

Phase 3：
- 元宝
- Kimi
- Grok
- Perplexity

## 浏览器执行状态机

CREATED
WAIT_LOGIN
READY
OPEN_PLATFORM
SEND_QUERY
WAIT_RESPONSE
VERIFY_COMPLETE
SAVE_RESULT
DELETE_CHAT
VERIFY_DELETE
NEXT_TASK
COMPLETED
PAUSED
FAILED
WAIT_HUMAN_APPROVAL

GEO任务包执行前必须进入WAIT_HUMAN_APPROVAL。结果导出前必须再次进入WAIT_HUMAN_APPROVAL。

禁止使用固定sleep判断回答完成。固定或随机等待只能控制操作节奏，不能作为回答完成信号。

### 浏览器人工接管

出现以下情况时必须立即暂停：
- 验证码
- 登录失效
- 安全验证
- 页面异常或无法可靠识别页面状态

系统必须保存暂停原因、原状态、安全恢复点、页面URL、时间和必要截图，然后等待人工接管。

验证类暂停必须作用于同一租户、平台和账号的全部任务，不得通过另一个任务包继续调度。本地界面必须显示 HUMAN_TAKEOVER_REQUIRED、暂停原因和阻塞执行。人工处理完成后，只能通过 Continue 事件触发 Worker 重新验证并解除屏障。

人工处理完成并明确点击继续后，执行引擎必须先重新验证平台、登录、页面和任务状态，再从安全恢复点继续。

禁止自动绕过验证码、安全验证或平台安全机制。

## 数据保存

每条结果立即保存。

支持：
- 部分回答实时检查点
- 断点恢复
- 日志
- 截图
- 错误记录
- 状态迁移审计
- 人工审批审计

## 租户隔离

每个客户独立tenant_id。

目录：

data/
 tenants/
  tenant_id/
   source/
   profile/
   discovery/
   tasks/
   results/
   exports/
   sessions/

本地界面必须支持选定客户后彻底删除。删除属于不可恢复操作，必须先显示影响范围，再要求操作者完整输入客户名称确认。

删除前租户进入 DELETING，停止新任务调度；正在执行的 Worker 必须在安全检查点停止、关闭租户 Session 并释放租约。人工登录窗口未关闭、Session 文件仍被占用或执行租约尚未释放时不得强制删除或绕过。

删除成功后，客户资料、官网页面、公网证据、档案、审批、任务包、任务、执行状态与事件、副作用账本、回答检查点、结果、导出、校准、浏览器 Session 元数据及租户文件目录必须全部移除，最后删除 tenant 记录。

## 本地控制界面

系统提供轻量本地管理界面，不开发商业Web后台。

本地界面至少支持：
- 查看客户状态
- 查看任务进度
- 查看暂停原因和截图
- 暂停执行
- 人工处理后继续
- 审批或拒绝人工审批节点
- 导出证据包、客户资料包和结果包
- 彻底删除选定客户及其全部项目数据

界面仅绑定本机，默认不提供公网访问、商业账号、CRM或收费能力。

## 技术建议

Python 3.12
FastAPI
Playwright
SQLite
AsyncIO
Pydantic
