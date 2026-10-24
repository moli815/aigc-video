# 对《BossAI 全栈深度体检》第 1–2 章 P0/P1 的逐条复核

> 复核对象：审计文档 `BossAI_全栈深度体检与最终交付方案_..._2026-10-24.md`（其依据是 88 个文件、不含 `cloudfunctions/` 的 `BossAI.zip`）
> 复核基准：**当前工作树的真实代码**（含 `cloudfunctions/`、`Tests/`、`Package.swift`），不是 ZIP 快照。
> 结论只有三种：`已闭环`（有实现 + 有测试）、`部分`（有实现但缺某条路径）、`仍成立`（确实是问题，本轮修或明确列为未做）。

## 0. 为什么这份审计的多数 P0 已经不成立

审计包不含云函数与测试目录（§12.1.1 自述），所以它看到的是 **10-23 之前的 App 侧代码**。
而 10-24 一整轮已经把组图任务系统、账务幂等、错误信封、额度预留落地并部署。
下表逐条给证据；凡是没证据的一律标 `部分/仍成立`，不靠"我记得改过"。

## 1. P0 复核

| 编号 | 审计结论 | 复核 | 证据 |
|---|---|---|---|
| **P0-1** 子任务没先占位，账本/记账队列可能为空 | 已闭环 | **已闭环** | `bf-image/index.js:232-243` `runSeriesChild` 首行 `subRid = parentRid + "::s" + index` → `await claimIdem(subRid, accountId)` → 再 `generate()` → 再 `finishIdem(subRid…)`；已成功的子任务直接 `reused` 不重生成（`cost: 0`）。真实调用验证过：重放同一 index 0.2s 返回同 URL、额度不变 |
| **P0-2** App 只下载第一张图 | 已闭环 | **已闭环** | `ImageService.swift:342 generateSeries(...)`、`:429 SeriesTaskSnapshot`、`:455 parseTaskSnapshot`（按 `downloadIndices` 分别下载）、`:554 stepSeries`、`:575 seriesStatus`、`:600 cancelSeries`；`ChatViewModel+Series.swift` 逐张落库；`Views/SeriesImageGrid.swift` 网格展示 + 仅重试失败项 |
| **P0-3** 重放退化成单图缓存 | 已闭环 | **已闭环** | `finishIdem(..., kind: "series", result: payloadBody)` 持久化完整 `items[]`；`claimIdem` 命中 `done` 时返回 `result`（不只是 `url`），`/series/start` 重放走 `seriesTaskPayload(again)` 且带 `idempotent: true` |
| **P0-4** 费用提交非幂等，重试重复累加 | 已闭环 | **已闭环** | 唯一事件 `bf_billing_events`（`_id = sha256("bill:"+account+":"+jobKey)`，`:652`），账户累计用 CAS：先把 `accountApplied` 由 false 改 true 再 `inc`（`:700-747`），usage 行复用同一 `_id`；`flushJobs` 按 `costCommitted/costTries` 补偿，`jobKey` 必须传（传错=每次 flush 新事件） |

## 2. P1 复核

| 编号 | 审计结论 | 复核 | 证据 / 说明 |
|---|---|---|---|
| **P1-1** actions 没接到 UI | 已闭环 | **已闭环** | `Services/APIError.swift`（`APIErrorEnvelope` / `APIErrorCarrying`）、`ViewModels/ChatViewModel+ErrorRecovery.swift`（`adopt` + `handleErrorAction`，`case "retry"` / `case "single_only"` 白名单）、`Views/RecoverableErrorView.swift`（按钮 + 加载态） |
| **P1-2** 额度服务不可用误报"额度已用完" | 已闭环 | **已闭环** | `bf-image/index.js:1356`、`:1557`、`:1651` 三处先判 `q.unavailable` → 503 `QUOTA_CHECK_UNAVAILABLE`（文案"暂时无法确认额度"），只有 `unavailable=false` 才 429 `POOL_EXHAUSTED` |
| **P1-3** 失败项 message 含内部错误文本 | 已闭环 | **已闭环** | 子任务失败固定文案「这一张没有生成成功，可以单独重试。」+ `errorCategory`；测试 `SERIES-03` 断言 `doesNotMatch(/message: String\(r\.msg/)` |
| **P1-4** 缺 requestId 的兜底没有贯穿 | 已闭环 | **已闭环** | `normalizeRid()` 在**入口**生成一次并全程复用（注释即记着这次事故：`finishIdem('')` 直接 return → 任务永远 processing、钱没记上）；`claimIdem` 返回 `rid` |
| **P1-5** 同步串行、无状态机/取消 | 已闭环 | **已闭环** | 5 个端点：`/series/start:1349`、`/series/step:1447`、`/series/status:1506`、`/series/cancel:1522`、`/series/retry:1550`；状态 `queued/running/partial/done/failed/cancelled` 存 `bf_image_series`，`items.N` 点路径更新；客户端 `runSteps(maxConcurrent: 2)` |
| **P1-6** 单字段降级排序可能漏数据 | 仍成立（已修） | **已闭环（数学上）** | `bf-api/index.js:1805-1830` 页尾**毫秒组补齐**：`while` 里按 `updatedAt == lastTs && _id > lastId` 持续补齐，直到该毫秒组取完；下一页从严格更大的时间戳开始 → 不可能漏。响应带 `ordering` 字段可诊断 |
| **P1-7** 先查后 add 并发重复 | 已闭环 | **已闭环（本轮补齐约束层）** | 确定性 `_id = sha256(accountId|kind|refId)[:40]` + **数据库唯一索引** `acct_kind_ref(accountId,kind,refId) unique`（10-24 建立，重复写入实测报 `E11000`），`add` 撞车读回按 LWW |
| **P1-8** 静默 catch / requestId 不串联 | 部分 | **部分** | 已修：`ToolPipeline.reportFailure` 带 `requestId` + `errorCode`（`ToolPipeline.swift:143-160`，同时写 `X-Request-Id`）；服务端 `requestId` 由 `AsyncLocalStorage` 贯穿、日志统一脱敏。**仍存**：`touchIdem` 等少数 catch 无日志（有意为之：续租失败不影响本次执行），未加指标告警 |
| **P1-9** 组图模型配置说明过时 | 已闭环 | **已闭环** | `settings-schema.js:97` 已改为「作图模型 · 组图档（兼容项，已不参与主链路）」，描述明确写"留空即可，不会关闭组图功能" |
| **P1-10** image_decompose 仍禁用 | 仍成立 | **仍成立（有意）** | `ToolRegistry.swift:127` `availability: { false }`，文案「暂未开放」；服务端 `layerDecomposition && !caps.layers` → 422。**保持关闭，不宣称端到端完成** |
| **P1-11** 旧 `/api/image` 不可用 | 仍成立 | **仍成立（有意）** | `handleImage` 返回 503 `PLEASE_UPDATE`。兼容策略需产品决策（恢复代理 vs 版本门禁），本轮不改契约 |
| **P1-12** 没有按张数预留额度 | 已闭环 | **已闭环** | `bf_quota_reservations`（TTL 30min，`bf-image:293-340`）+ `quotaExhausted` 扣减生效中预留；start 时按最贵档 `unitWorst * n` 估算，不足返回 402 `QUOTA_INSUFFICIENT` + `single_only/renew/cancel` |

## 3. 第 4 章交付材料问题

| 项 | 状态 |
|---|---|
| 4.1 清单 54 vs 58 计数矛盾 | 旧交付物问题，本轮新报告已统一口径（不做假统计） |
| 4.2 HTML 汇总表空列 | 同上，本轮的清单每项都有内容列 |
| 4.3 README 提 IPA 但包内无 IPA | 已明确：IPA 单独产物 + SHA-256（`BossAI-unsigned-1024-series-v3.ipa`），不塞进源码包 |
| 4.4 "8/8 一致/CI 全绿"缺可复核凭证 | 本轮补：部署动作可查（CloudBase ModTime）、commit 可查（`a439eb5`）、测试可复跑 |
| 4.5 待办矩阵未打包 | 本文即矩阵；未做项在 §5 |
| 4.6 旧备份 `.bak` 混在函数目录 | **已修**：`bf-api/index.js.bak-1019` 移到 `bf-backend/_archive/`，不再进部署包 |

## 4. 本轮真正改了什么（与本审计直接相关）

1. `short_video` 专家三处同步（App 目录 / 能力档案 / 云端种子 + `EXPERTS_SEED_VERSION=3`）。
2. 契约测试：`ShortVideoSkillTests`（7 条）、`expert-seed-contract`（5 条）。
3. `docs/skill-system/*`：现状盘点、候选评估、Skill Schema、路由策略与评测集、短视频规范。
4. 部署包清理（`.bak` 移出）。
5. 新增文档明确写死「视频下载/ASR/抽帧/剪辑当前不存在」，禁止口径夸大。

## 5. 仍未做（不许标记完成）

| 项 | 原因 | 需要什么 |
|---|---|---|
| 真实模型参与的路由评测（12 条用例） | 没有 harness，且要花调用成本 | 你点头后按 `04-routing-policy.md` 跑，样本量与环境写进报告 |
| `image_decompose` 端到端 | 上游返回结构未实测 | 一次真实调用摸结构 |
| 旧 `/api/image` 兼容或版本门禁 | 产品决策 | 你选：恢复代理 / 设 minVersion |
| 静默 catch 的指标告警 | 需接监控 | 现有 `jobs_last_run` 只是运行统计，不是告警 |
| Swift 侧本轮改动的编译与单测 | 需 macOS/Xcode | 已推 CI，等 run 结果 |
