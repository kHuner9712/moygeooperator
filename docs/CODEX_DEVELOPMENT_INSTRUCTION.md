
# Codex Development Instruction

请创建全新的 GEO Operator V2 项目。

不要修改旧版本。

严格阅读 docs/GEO_Operator_V2_Base_Specification.md。

开发目标：
创建一个稳定的GEO执行机器人。

必须实现：

1. 多租户隔离
2. 客户资料导入
3. 官网抓取
4. Public Discovery Evidence Collection模块
5. CLIENT_PROFILE导出
6. PUBLIC_DISCOVERY导出
7. GEO任务包导入
8. Human Approval Gate
9. 浏览器任务执行状态机
10. 浏览器人工接管
11. AI平台插件架构
12. 实时结果保存
13. 断点恢复
14. 结果包导出
15. 轻量本地控制界面

开发原则：
- 不开发AI分析
- 不开发内容生成
- 不开发CRM
- 不开发收费
- 不开发商业Web后台
- 稳定优先

Public Discovery要求：
- 公网搜索只生成原始证据，不生成或修改客户档案
- 保存来源URL、抓取时间、原始文本、截图、来源类型
- 可信度字段固定为待AI分析
- 输出PUBLIC_DISCOVERY.zip

人工审批节点：
- 客户资料整理完成后
- GEO任务包执行前
- 结果导出前

统一状态为WAIT_HUMAN_APPROVAL，未经明确批准不得继续。审批必须持久化并可审计。

浏览器模块必须考虑：
- 平台自动化限制
- 登录状态管理
- 低频人工化操作
- 异常暂停
- 验证码、登录失效、安全验证和页面异常时人工接管
- 人工处理后验证状态再继续
- 禁止自动绕过平台安全机制
- 禁止使用固定sleep判断回答完成

平台开发顺序：

Phase 1：
豆包、ChatGPT

Phase 2：
DeepSeek、千问、Gemini

Phase 3：
元宝、Kimi、Grok、Perplexity

平台采用插件结构。

明确禁止 Claude。不得实现 Claude/Anthropic 插件、Session、任务导入或控制界面入口；平台注册必须使用统一允许清单并在未知或禁止平台上失败关闭。

新增平台必须先完成官方入口、独立 Session 和结构快照接入，状态标记为 CALIBRATION_REQUIRED；只有回答完成判定、实时保存、断点恢复和聊天删除均通过真实账号校准后，才可标记 EXECUTION_READY 并进入 Worker 调度。

本地控制界面只用于查看客户状态、查看任务进度、暂停、继续、人工审批和导出，不扩展为商业Web后台或用户系统。

完成后输出：
- 运行方式
- 测试结果
- 已知限制
