# MOY GEO Operator — Internal

临时内部 GEO 生产系统，支撑约 20 家并发客户。PostgreSQL 是唯一 System of
Record；NocoDB 是运营 UI；n8n 是流程编排。本仓库与 MOY 正式产品仓库完全独立。

> 当前进度：**Stage 8 — Retest / Reporting（WF-08）完成**，含异常队列通知闭环
> （OPEN 异常经 `EXCEPTION_NOTIFY_URL` webhook 通知人工介入）。
> WF-05 已加固：所有 PostgreSQL 节点由不兼容的 `:param` 命名参数改为 n8n 内联
> 表达式，GAP_ANALYSIS 全链路验证通过（gaps=12 / actions=5 / CONTENT_FACTORY=5）。

## 栈

- PostgreSQL 16 — System of Record
- NocoDB Community — 内部运营控制台
- n8n self-hosted — Workflow / Scheduler
- 后续 Stage 加入：Crawl4AI、SearXNG、Ollama、Playwright

## 快速开始

```bash
cp .env.example .env        # 填写真实 secret，勿提交 .env
docker compose up -d        # 启动 postgres / nocodb / n8n
docker compose exec -T postgres bash /srv/db/run-migrations.sh   # 应用迁移
docker compose exec -T postgres bash /srv/db/apply-views.sh      # 创建 views
```

服务端口（见 `.env`）：Postgres `5432`、NocoDB `8080`、n8n `5678`。

## 数据模型

迁移：`db/migrations/`（版本化，`schema_migrations` 记录）。核心表覆盖
Client / Truth / Entity / Surface / Intent / Observation / Gap / Action /
Content / Publication / Report / Job / Exception / LLM Run / Cost。

## 目录

```text
db/           迁移、views、init、schema-reference
n8n/workflows/编排定义（后续 Stage）
scripts/      backup / health / maintenance
templates/    客户 Truth Pack、发布包、报告（后续 Stage）
storage/      运行时产物，不入 Git
```

## 工程规则

- LLM 不直接制造 canonical 企业事实；公开内容只用 VERIFIED Claim。
- 所有客户对象带 `client_id`；cross-client 混写 = CRITICAL defect。
- 昂贵/外部动作必须有 deterministic idempotency key。
- 缺 Evidence / 无效 credential / 未支持平台 / 未确认策略 / 事实冲突 /
  引擎失败 / client 不匹配 → 一律 fail closed，创建 Exception。
- 凭证只存 reference；客户私有文件、raw crawls、截图不入 Git。

详见上游设计包 `../GEO_Operator_Internal_Pack/`。