# MOY GEO Operator — Internal

临时内部 GEO 生产系统，目标支撑约 20 家并发客户。PostgreSQL 是唯一 System of
Record；NocoDB 是运营 UI；n8n 是流程编排。本仓库与 MOY 正式产品仓库完全独立。

> **当前能力状态（2026-08）**：**Shadow Gate Hotfix & Full Runtime E2E 已完成**。
> 本地全链路验证 verdict = **SHADOW_RUN_READY**（受监督）——`scripts/e2e/full-shadow-runtime.sh`
> 通过 L0–L6，含真实 n8n 执行的 WF-01 webhook 链路（`artifacts/shadow-runtime-e2e.json`）。
> 但 **REAL_CUSTOMER_NOT_READY** —— 仅具备 **FIRST_REAL_CLIENT_SHADOW_RUN** 的
> 前提条件。仓库内所有业务数据均为 synthetic fixture，不得当作真实业务结果。
> 尚未接入任何真实客户、真实凭证或真实对外发布。

## 能力状态（Capability State）

| 能力 | 状态 | 备注 |
|------|------|------|
| Truth Intake（WF-01） | **LIMITED** | 真实读取文档正文并解析 Claim；格式仅 TXT/MD/CSV；PDF/网页走 `parse_truth_document`（PDF 结构化正文解析为后置项，当前 PAGE/SECTION 记录尽力而为）。DOCX/XLSX 明确 **NOT_IMPLEMENTED**。 |
| Surface Discovery（WF-02） | **LIMITED** | 依赖工具型服务（SearXNG/Crawl4AI，`tooling` profile 才启动）；未接真实抓取。 |
| Intent / Query（WF-03） | **IMPLEMENTED** | 统一 0–100 加权评分（0.35/0.40/0.25），去重 + 确定性入队。 |
| Engine Observation（WF-04） | **LIMITED** | 真实 Adapter contract；`LOCAL_OLLAMA` 可用；`OPENAI/GEMINI/PERPLEXITY/UI_OBSERVATION` 未接 → **UNSUPPORTED / MANUAL_OBSERVATION_REQUIRED**，fail closed。 |
| Gap / Action（WF-05） | **IMPLEMENTED** | 高效的 gap→action 生成与优先级继承。 |
| Content Factory（WF-06） | **LIMITED** | 内容有独立 Fact Gate + Compliance Gate：`fact_check_status=PASSED` 与 `compliance_status=PASSED` 才进发布队列；禁止 `VERIFIED` 直接标内容。非法数值/新增事实 → `CONTENT_QA_FAILED` → BLOCK。 |
| Publication（WF-07） | **SHADOW_ONLY** | 生产路径**无 simulated publish**。无真实 adapter → `MANUAL_REQUIRED` / `WAITING_APPROVAL`，绝不直接 `PUBLISHED`。API 自动发布需真实凭证，当前 **unavailable**。 |
| Retest / Reporting（WF-08） | **IMPLEMENTED** | 周期报告 + 异常通知（Feishu webhook，HMAC-SHA256 加签）。报表只汇总已存在的 observation window。 |
| Job Lease / Retry | **IMPLEMENTED** | `recover_expired_leases` 回收过期 RUNNING；`fail_job` 指数退避 `RETRY_WAIT`→`FAILED`+Exception。 |
| Multi-client Isolation | **IMPLEMENTED** | 跨 client 的对象操作一律 fail closed；`SYNTH-A`/`SYNTH-B` adversarial 测试通过。 |
| Operator Runtime（NocoDB views） | **IMPLEMENTED** | `v_client_health` / `v_open_exceptions` / `v_manual_publish_queue` / `v_failed_retry_jobs` / `v_content_qa_failures` 等。 |
| CI / Verification Gate | **IMPLEMENTED** | 轻量 GitHub Actions（分钟级）：JSON 校验 + 违禁字符串扫描 + 静态契约检查 + 干净库迁移/视图/seeds + 集成测试（含 Shadow Runtime WF-01..WF-08 DB-contract E2E）。 |

**关键约束**：synthetic fixture 只允许存在于 `db/seeds/`、`tests/`；运行时 workflow
统一输入 `{ job_id, client_id, correlation_id }`，`client_id` 是权威 scope，
不得出现硬编码 `SYNTH-ACME` 或 placeholder 执行路径。

## 栈

- PostgreSQL 16 — System of Record（固定 `postgres:16-alpine`）
- NocoDB Community — 内部运营控制台（固定 `nocodb/nocodb:0.263.1`）
- n8n self-hosted — Workflow / Scheduler（固定 `n8nio/n8n:2.34.5`）
- Ollama — 默认本地 LLM（固定 `ollama/ollama:0.32.7`）
- 工具型（`tooling` profile，按需启动）：Crawl4AI、SearXNG

## 快速开始（首次部署）

```bash
cp .env.example .env        # 填写真实 secret，勿提交 .env
./scripts/deploy/deploy.sh  # 完整部署：stack up → migrations → views → import → verify
```

分步执行（等价）：
```bash
docker compose up -d
docker compose exec -T postgres bash /srv/db/run-migrations.sh
docker compose exec -T postgres bash /srv/db/apply-views.sh
docker compose exec -T n8n n8n import:workflow --input=/home/node/workflows --separate
```

### 部署 / 升级 / 激活说明（P0.11）

- Git 中 `n8n/workflows/*.json` 是 **source representation**（SSOT）；n8n 的 workflow
  metadata DB 只是 derived artifact，不当作 SSOT，也不手工编辑。
- `./scripts/deploy/deploy.sh` 支持：`full`（首部署）、`--reimport`（仅重导入 workflow）、
  `--verify`（仅验证）。
- 激活策略：默认 **无 workflow active**。Shadow Run 阶段推荐仅激活 `wf08`
  （周期报告），其余 wf01–wf07 保持手动，直到受监督。
  - 方式 A：`ACTIVE_WORKFLOWS="wf08" N8N_URL=... N8N_API_KEY=... ./scripts/deploy/deploy.sh`
  - 方式 B：n8n UI 手动 toggle（推荐首客户）。
- 升级：改 workflow JSON → `--reimport` → n8n UI 确认 → 同步激活。
- 验证已加载：`./scripts/deploy/deploy.sh --verify`，或浏览器访问 `http://localhost:5678`。

### 备份（P1）

- `scripts/backup/backup.sh` 做 PostgreSQL 逻辑备份（`pg_dump -Fc`），留存 daily/weekly。
- 调度建议（Linux cron，每日 02:00）：
  ```
  0 2 * * * cd /path/to/geo-operator && BACKUP_DIR=/srv/geo-operator/backups ./scripts/backup/backup.sh >> /var/log/geo-operator-backup.log 2>&1
  ```
- 恢复验证：`pg_restore -d <restore_db> --clean --if-exists <backup.dump>` 后，
  执行 `./scripts/deploy/deploy.sh --verify` 确认 schema_migrations 与 views 完整。

## 数据模型

迁移：`db/migrations/`（版本化 001–012，`schema_migrations` 记录）。核心表覆盖
Client / Truth / Entity / Surface / Intent / Observation / Gap / Action /
Content / Publication / Report / Job / Exception / LLM Run / Cost。

## 目录

```text
db/migrations/   版本化迁移（012 = Runtime Convergence P0 修复）
db/views/        operator_runtime.sql 等面向运营的视图
db/seeds/        SYNTHETIC 测试数据（仅测试 fixture）
db/run-migrations.sh / apply-views.sh / run-seeds.sh
n8n/workflows/   wf01..wf08（Git 为 source representation）
scripts/         backup / health / deploy / e2e（full-shadow-runtime.sh 全链路 E2E）
tests/integration/  集成测试（含 shadow_runtime_e2e.sql：WF-01..WF-08 全链路契约）
artifacts/       本地 E2E 产物（shadow-runtime-e2e.json）
.github/workflows/  轻量 CI
```

## 工程规则

- LLM 不直接制造 canonical 企业事实；公开内容只用 VERIFIED Claim。
- 所有客户对象带 `client_id`；cross-client 混写 = CRITICAL defect，一律 fail closed。
- 昂贵/外部动作必须有 deterministic idempotency key。
- 缺 Evidence / 无效 credential / 未支持平台 / 未确认策略 / 事实冲突 /
  引擎失败 / client 不匹配 → 一律 fail closed，创建 Exception。
- 发布：无真实 adapter → `MANUAL_REQUIRED`；有 adapter → 真实 provider request →
  verify → `PUBLISHED`。**禁止 simulated publish 标 PUBLISHED**。
- 凭证只存 reference；客户私有文件、raw crawls、截图不入 Git。

## Known Limitations（真实限制）

- **Truth parser**：TXT/MD/CSV 真实解析；PDF 结构化正文解析仍是后置项（尽力
  PAGE/SECTION），DOCX/XLSX **NOT_IMPLEMENTED**。
- **Engine adapters**：真正可用仅 `LOCAL_OLLAMA`（Ollama）。`OPENAI_API` /
  `GEMINI_API` / `PERPLEXITY_API` / `UI_OBSERVATION` / `MANUAL_OBSERVATION` 定义
  了 contract 但无真实凭证 → **MANUAL / UNSUPPORTED**，fail closed。
- **对外发布**：AUTO_API 无真实凭证 → `MANUAL_REQUIRED`。抖音/快手等真实 API
  未接入。
- **Factuality**：基于规则 + Truth comparison（token overlap + 数字矛盾检测），
  第二模型仅作辅助，不作唯一事实裁判。
- **尚未开始**真实客户 Shadow Run 的导入与执行；本地全链路 E2E 已用 synthetic
  tenant（SHADOW-E2E-A/B）通过，verdict=**SHADOW_RUN_READY**（`scripts/e2e/full-shadow-runtime.sh`）。

详见上游设计包 `../GEO_Operator_Internal_Pack/`。