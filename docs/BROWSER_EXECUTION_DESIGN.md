# Browser Execution Engine Design

## 1. 状态

执行状态：

- CREATED
- WAIT_LOGIN
- READY
- WAIT_HUMAN_APPROVAL
- OPEN_PLATFORM
- SEND_QUERY
- WAIT_RESPONSE
- VERIFY_COMPLETE
- SAVE_RESULT
- DELETE_CHAT
- VERIFY_DELETE
- NEXT_TASK
- COMPLETED
- PAUSED
- FAILED

WAIT_HUMAN_APPROVAL 同时保存 approval_stage 和 resume_state。PAUSED 同时保存 pause_reason、paused_from_state 和 safe_resume_state。

## 2. 关键路径

```text
CREATED
  → WAIT_LOGIN
  → READY
  → WAIT_HUMAN_APPROVAL(TASK_EXECUTION)
  → OPEN_PLATFORM
  → SEND_QUERY
  → WAIT_RESPONSE
  → VERIFY_COMPLETE
  → SAVE_RESULT
  → DELETE_CHAT
  → VERIFY_DELETE
  → NEXT_TASK
  → OPEN_PLATFORM | COMPLETED
```

结果导出是独立流程：

```text
COMPLETED → WAIT_HUMAN_APPROVAL(RESULT_EXPORT) → EXPORT
```

## 3. 状态迁移不变量

- 未通过 TASK_EXECUTION 审批，不能进入 OPEN_PLATFORM。
- 未确认 query 已出现，不能进入 WAIT_RESPONSE。
- 未通过多信号完成验证，不能进入 SAVE_RESULT 的最终保存。
- 最终结果未持久化并校验，不能进入 DELETE_CHAT。
- 删除未确认或未明确记录跳过策略，不能进入 NEXT_TASK。
- 任意不确定外部状态都优先 PAUSED，禁止盲目重试。
- COMPLETED 和 FAILED 是终态，除非人工创建新的恢复执行。

## 4. 回答完成判断

平台插件返回一组观测信号：

- streaming_indicator_absent
- stop_control_absent
- input_ready
- response_text_stable
- final_response_element_present
- platform_error_absent

response_text_stable 使用多次观测的稳定窗口，但稳定窗口本身不是唯一完成条件。固定 sleep 和随机等待只用于节奏控制，不得作为完成证据。

若信号冲突、超时或 DOM 无法识别，进入 PAUSED/PAGE_ABNORMAL。

## 5. 实时保存

WAIT_RESPONSE 期间，每当回答文本变化且满足检查点节流条件时保存：

- 文本
- content_hash
- captured_at
- page_url
- response_locator_hint
- screenshot_path（按策略或异常时）
- sequence

最终结果采用幂等 upsert，并在同一事务记录 RESULT_SAVED 事件。文件通过临时文件和原子替换写入。

Checkpoint 的回答文本和哈希是首要耐久数据；瞬时页面刷新导致 checkpoint 截图失败时，仍原子保存文本并把 screenshot_path 记为空，下一次文本变化继续尝试截图。最终结果截图是硬门槛：截图失败必须 PAUSED/PAGE_ABNORMAL，不得写 RESULT_SAVED，也不得进入 DELETE_CHAT。

## 6. 外部副作用恢复

### 发送问题

1. 写入 QUERY_SEND_INTENT，包括 query_fingerprint。
2. 执行输入和发送。
3. 从页面观察问题节点。
4. 写入 QUERY_SEND_CONFIRMED。

进程在 2 和 4 之间崩溃时，恢复流程先检查聊天页面是否已有相同任务的问题。只有可靠确认未发送时才允许重试；否则暂停人工判断。

Phase 1 首次真实校准允许在输入框和发送控件已确认后单次发送。若发送后问题节点、回答节点或完成/删除信号尚未校准，QUERY_SEND 保持 INTENT，保存不含节点正文、Cookie 和存储数据的结构快照，并进入 PAUSED/PAGE_ABNORMAL。补齐选择器后恢复时必须先用幂等键和已发送问题节点对账，禁止再次发送。

### 删除聊天

1. 确认 RESULT_SAVED。
2. 写入 CHAT_DELETE_INTENT。
3. 执行删除。
4. 验证聊天不存在。
5. 写入 CHAT_DELETE_CONFIRMED。

删除状态不确定时不得进入下一任务。

## 7. 人工接管

暂停原因：

- CAPTCHA
- LOGIN_EXPIRED
- SECURITY_CHALLENGE
- PAGE_ABNORMAL
- RATE_LIMITED
- ACCOUNT_RESTRICTED
- COMPLETION_UNCERTAIN
- SESSION_LOST
- OPERATOR_REQUESTED

暂停时保存页面 URL、时间、原状态、安全恢复点和截图。浏览器保持可见供人工处理。

人工验证是平台/账号级调度屏障。任一执行因 CAPTCHA、LOGIN_EXPIRED、SECURITY_CHALLENGE、RATE_LIMITED 或 ACCOUNT_RESTRICTED 暂停后，同一 tenant_id、platform、account_id 下其他任务包的普通调度也必须停止。只允许被阻塞执行在收到 HUMAN_TAKEOVER_COMPLETED 后由 Worker 复核；复核成功并离开 PAUSED 后才解除屏障。本地界面的 Session 卡片显示 HUMAN_TAKEOVER_REQUIRED、原因和阻塞执行 ID。

若平台同时显示当前问题节点和已校准的明确发送失败标记，账本保留 action_attempted=true 并记录 delivery_failed=true，不得写入 CONFIRMED。人工验证完成且复核通过后，可复用同一 INTENT 重试。没有明确未投递证据时，仍禁止自动重发。

人工点击继续后，不直接恢复副作用操作。引擎首先调用插件 revalidate：

1. 验证 Session 和登录。
2. 验证当前页面属于目标平台。
3. 对账当前任务是否已发送。
4. 对账回答或删除状态。
5. 选择安全恢复状态。

revalidate 无法确定时继续暂停。系统禁止自动解决验证码或安全验证。

## 8. Session 管理

Session 键为 tenant_id、platform、account_id。每个键对应独立 persistent context 目录和单执行锁。

Session 健康状态：

- NEW
- LOGIN_REQUIRED
- READY
- IN_USE
- NEEDS_HUMAN
- INVALID

Cookie、local storage 和浏览器 profile 仅保存在租户 Session 目录，不写日志和导出包。

Playwright 管理的 headed Chrome 必须显式设置 chromium_sandbox=True；禁止 --no-sandbox、--disable-sandbox 或 --disable-setuid-sandbox。原生人工登录窗口同样不得携带这些参数。
## 9. Phase 1 真实页面校准

- 系统 Chrome 人工登录与 Playwright Worker 分离，人工登录进程不得带 remote debugging 或 automation 参数。
- 登录页、输入框和发送控件可以在不发送问题时校准。
- 回答节点、流式指示、停止控件、问题节点和删除动作只能从真实回答会话观察，不允许猜测选择器。
- 校准结构证据只保存可见节点的标签与有限属性；不读取节点正文、Cookie、local storage 或 session storage。
- 插件总体 calibration_complete 只有在发送、问题对账、回答完成和删除全链路都完成校准后才为 true。