# CloudBase 部署快照（脱敏）

> 采集时间：2026-10-24 20:50（北京时间）· 采集方式：CloudBase 管控 API（MCP），**未导出任何密钥明文**
> 用途：回应审计 §P1-5 / §P1-8「源码 ≠ 线上已部署」。本文件是**线上实际状态**的记录，不是计划值。
> 复核方式：控制台 → 云函数 → 对应函数 → 函数配置 / 触发器；或 `tcb fn detail <name>`。

## 1. 函数状态

| 函数 | 类型 | 运行时 | 超时 | 内存 | 最近部署(ModTime) | 代码包 | 触发器 |
|---|---|---|---|---|---|---|---|
| bf-api | HTTP | Nodejs18.15 | 300s | 256MB | **2026-10-24 20:48:13** | 6.41 MB | — |
| bf-image | HTTP | Nodejs18.15 | 未采集* | 未采集* | 2026-10-24 19:10 | — | — |
| bf-jobs | Event | Nodejs18.15 | 120s | 256MB | 2026-10-24 19:10:40 | 5.86 MB | `daily-cleanup` · `0 30 3 * * * *` |

\* bf-image 的 timeout/memory 本次未逐项采集（避免为读两个字段拉全量详情）。以控制台为准；如需写进验收记录，在控制台抄一次即可。

环境：`xmy-test-d5g8c0xcifcefcfd5` · 地域：ap-shanghai · 命名空间同环境 ID。

## 2. bf-api 环境变量（**只列名字与值长度，不记值**）

共 40 个键。密钥类（`*_API_KEY`）与 `TCB_ENV` 只标注存在性。

| 分组 | 变量 | 值长度 |
|---|---|---|
| 引导 | `BOOTSTRAP_ADMIN_USER` / `BOOTSTRAP_ADMIN_PASSWORD` | 10 / 13 |
| 对话 | `CHAT_API_KEY` | 116 |
| | `CHAT_BASE_URL` | 49 |
| | `CHAT_MODEL` / `CHAT_MODEL_STANDARD` / `CHAT_MODEL_HIGH` / `CHAT_MODEL_PRO` / `CHAT_MODEL_ULTRA` | 19 / 19 / 15 / 15 / 15 |
| | `CHAT_MODEL_UTILITY` / `CHAT_MODEL_UTILITY_LITE` / `CHAT_MODEL_VISION` | 13 / 13 / 13 |
| | `CHAT_THINKING_STYLE` | 9 |
| 计价 | `CHAT_PRICE_IN` / `CHAT_PRICE_OUT` / `CHAT_PRICE_HIGH_IN` / `CHAT_PRICE_HIGH_OUT` / `CHAT_PRICE_STANDARD_IN` / `CHAT_PRICE_STANDARD_OUT` / `CHAT_PRICE_ULTRA_IN` / `CHAT_PRICE_ULTRA_OUT` | 1–3 |
| | `CHAT_CAP_CNY` / `CHAT_NOTICE_CNY` | 3 / 2 |
| 向量 | `EMBED_API_KEY` / `EMBED_BASE_URL` / `EMBED_MODEL` | 116 / 49 / 17 |
| 生图 | `IMAGE_API_KEY` | 46 |
| | `IMAGE_BASE_URL` / `IMAGE_PROVIDER` / `IMAGE_MODEL` / `IMAGE_MODEL_PRO` | 40 / 3 / 30 / 30 |
| | `IMAGE_PRICE` / `IMAGE_PRICE_PRO` / `IMAGE_PRICE_2K` | 4 / 4 / 4 |
| | `IMAGE_SIZES` / `IMAGE_MAX_PIXELS` / `IMAGE_2K_PIXELS` / `IMAGE_CAP_CNY` / `IMAGE_NOTICE_CNY` | 75 / 7 / 7 / 2 / 2 |
| 运行时 | `TCB_ENV` | 26 |

> ⚠️ `IMAGE_API_KEY` 同时配在 bf-api 与 bf-image 上；**真正生效的是 bf-image** 的那份（`/api/image` 已停用）。
> 换生图密钥时必须两个函数一起换，否则管理台显示与实际上游不一致。

## 3. 定时触发器（bf-jobs）

```json
{
  "TriggerName": "daily-cleanup",
  "Type": "timer",
  "TriggerDesc": "{\"cron\":\"0 30 3 * * * *\"}",
  "AddTime": "2026-10-24 19:10:54"
}
```

- 7 段 cron：秒 分 时 日 月 周 年 → **每天 03:30:00**。
- 已用同一入口手工真跑验证：dryRun 命中 17 / 真删 17，写 `bf_config/jobs_last_run`，锁 `jobs_lock` 正常释放。
- 自然触发待明日 03:30 复核：`bf_config/jobs_last_run.trigger` 应为 `"timer"`。

## 4. 数据库集合与索引

集合（19）：`bf_accounts` `bf_staff` `bf_requests` `bf_deliveries` `bf_notifications` `bf_usage_logs` `bf_config` `bf_crashes` `bf_cache` `bf_user_data` `bf_sync_meta` `bf_schedules` `bf_custom_experts` `bf_image_jobs` `bf_image_series` `bf_quota_reservations` `bf_billing_events` `bf_rate` **`bf_audit_logs`（10-24 新增）**

| 集合 | 索引 | 唯一 | 说明 |
|---|---|---|---|
| bf_user_data | `acct_kind_ref (accountId,kind,refId)` | **是** | 同步唯一性兜底；重复写入实测 `E11000` |
| bf_user_data | `acct_updated (accountId,updatedAt)` | 否 | 增量拉取 |

## 5. 部署后 smoke test（真实响应）

| 检查 | 时间 | 结果 |
|---|---|---|
| `GET /api/health` | 20:49 | `ok=true`；image=`doubao-seedream-5-0-pro-260628` |
| `GET /api/capabilities` | 20:49 | chat / image / poster 均 `enabled=true`，依赖 Key `configured=true` |
| `GET /api/experts`（会员 token） | 20:49 | `version=4`, `count=16` |
| `POST /api/image`（旧路径） | 20:49 | `503 PLEASE_UPDATE` + 自然语言升级文案（门禁链路有效） |
| `GET /img/ping` | 19:15 | `ok=true` |
| 真实出图 `/img/image` | 19:15 | 12.1s，cost 0.3，Flash 1.5K |

## 6. 仍未采集（如实列）

- bf-image 的 timeout / memory / 代码包大小。
- 线上环境变量**值**（按设计不落盘，任何人都无法从本文件还原密钥）。
- 管理端/员工端浏览器的端到端回归（需要管理员口令与浏览器会话）。
- 旧版 App 收到 `PLEASE_UPDATE` 的实机表现（需要旧版本安装包）。
