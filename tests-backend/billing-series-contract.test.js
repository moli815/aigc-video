// ============================================================================
// billing-series-contract.test.js —— 10-24 组图闭环与账务幂等的契约测试
//
// 这里断言的是"结构不变量"，不是真实数据库行为：
//   · 子任务必须先 claim 再 generate 再 finish（少一步 = 这张图脱离台账）
//   · 父任务必须持久化完整结果，重放不能退化成单图缓存
//   · 账务必须走唯一事件 + 分阶段幂等，不能"两次独立写入 + 盲目重试"
//   · 额度不可用与额度用尽必须是两种响应
//   · 同步翻页的页边界不能落在同一毫秒组中间
//
// 真实数据库行为需要集成测试（见交付说明的"未验证"清单）。
// ============================================================================

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.join(__dirname, "..");
const IMAGE = fs.readFileSync(path.join(ROOT, "cloudfunctions/bf-image/index.js"), "utf8");
const API = fs.readFileSync(path.join(ROOT, "cloudfunctions/bf-api/index.js"), "utf8");

// ─────────────────────────────────────────────────────────────
// 组图：子任务台账
// ─────────────────────────────────────────────────────────────

test("SERIES-01 子任务先 claim 再 generate 再 finish", () => {
  const start = IMAGE.indexOf("async function runSeriesChild");
  assert.ok(start > 0, "缺少 runSeriesChild");
  const body = IMAGE.slice(start, start + 2600);
  const iClaim = body.indexOf("claimIdem(subRid");
  const iGen = body.indexOf("await generate(");
  const iFinish = body.indexOf("finishIdem(subRid");
  assert.ok(iClaim > 0, "子任务没有 claimIdem");
  assert.ok(iGen > 0, "子任务没有调用 generate");
  assert.ok(iFinish > 0, "子任务没有 finishIdem");
  assert.ok(iClaim < iGen, "必须先 claim 再调用上游（否则成功后无处落账）");
  assert.ok(iGen < iFinish, "必须先拿到结果再 finish");
});

test("SERIES-02 已成功的子任务重试时直接复用，不重复生成", () => {
  const start = IMAGE.indexOf("async function runSeriesChild");
  const body = IMAGE.slice(start, start + 1200);
  assert.match(body, /claim\.state === "done" && claim\.url/, "重试未复用已成功的子任务");
  assert.match(body, /reused: true/, "未标记 reused（客户端会重复计预算）");
});

test("SERIES-03 子任务失败文案固定，技术原因只进日志", () => {
  const start = IMAGE.indexOf("async function runSeriesChild");
  const body = IMAGE.slice(start, start + 2600);
  assert.match(body, /message: "这一张没有生成成功，可以单独重试。"/, "失败文案不是固定的人类语言");
  assert.doesNotMatch(body, /message: String\(r\.msg/, "仍把上游原文塞进 items[].message");
  assert.match(body, /errorCategory:/, "缺少机器分类字段（客户端无法据此判断可否重试）");
});

test("SERIES-04 父任务持久化完整结果与原始输入", () => {
  assert.match(IMAGE, /kind: "series",\s*\n\s*result: payloadBody/, "父任务未持久化完整结果");
  assert.match(IMAGE, /input: \{[\s\S]{0,300}prompt: String\(body\.prompt \|\| ""\)/, "父任务未持久化原始 prompt（无法重试失败项）");
  assert.match(IMAGE, /hasImage: !!body\.image/, "未记录是否带参考图");
});

test("SERIES-05 全失败不落 done（否则永远无法重试整组）", () => {
  const seg = IMAGE.slice(IMAGE.indexOf('if (okCount === 0)'));
  assert.match(seg.slice(0, 400), /abortIdem\(rid, auth\.sub, "series_all_failed"\)/, "全失败时未释放任务占位");
});

test("SERIES-06 组图重放返回完整 items，不退化成单图缓存", () => {
  const seg = IMAGE.slice(IMAGE.indexOf('if (claim.state === "done")'));
  assert.match(seg.slice(0, 700), /claim\.result\.task_kind === "series"/, "未识别组图结果");
  assert.match(seg.slice(0, 700), /Object\.assign\(\{\}, claim\.result, \{/, "重放未返回完整结果");
});

test("SERIES-07 有独立的「只重试失败项」接口", () => {
  assert.match(IMAGE, /u\.indexOf\("\/series\/retry"\) >= 0/, "缺少 /series/retry 路由");
  const start = IMAGE.indexOf('u.indexOf("/series/retry")');
  const body = IMAGE.slice(start, start + 3800);
  assert.match(body, /prev\.failedIndices/, "未读取失败序号");
  assert.match(body, /byIndex\.set\(i, item\)/, "未按序号合并重试结果");
  assert.match(body, /finishIdem\(parentRid[\s\S]{0,160}result: payload/, "重试后未回写父任务结果");
});

test("SERIES-08 串行执行时续租父任务（90s lease 与 4 张时长不匹配）", () => {
  assert.match(IMAGE, /async function touchIdem/, "缺少续租函数");
  assert.match(IMAGE, /if \(i > 1\) await touchIdem\(rid, auth\.sub\)/, "多张时未续租");
});

// ─────────────────────────────────────────────────────────────
// 账务：唯一事件 + 分阶段
// ─────────────────────────────────────────────────────────────

test("BILL-03 账务事件 ID 由账号 + 任务 key 派生", () => {
  assert.match(IMAGE, /function billingEventIdOf\(accountId, jobKey\)/);
  assert.match(IMAGE, /"bill:" \+ String\(accountId\) \+ ":" \+ String\(jobKey\)/);
});

test("BILL-04 明细复用事件 ID（重复写入必然失败）", () => {
  assert.match(IMAGE, /_id: eventId, accountId, kind: "image"/, "usage 明细未复用事件 ID");
  assert.match(IMAGE, /usageOk = !!\(await readOne\(C\.usage, eventId\)\)/, "重复写入未按已应用处理");
});

test("BILL-05 账户累计用 CAS 标记，失败可回滚重试", () => {
  assert.match(IMAGE, /col\.where\(\{ _id: eventId, accountApplied: false \}\)/, "缺少条件更新（会重复累加）");
  assert.match(IMAGE, /update\(\{ accountApplied: false \}\)/, "inc 失败后未回滚标记（钱会永久丢失）");
  assert.match(IMAGE, /billing_cas_unsupported/, "条件更新不支持时没有降级记录");
});

test("BILL-06 flushJobs 把 jobKey 传给账务（否则每次都是新事件）", () => {
  assert.match(IMAGE, /jobKey: String\(id\)/, "未传 jobKey，账务事件 ID 会漂移");
  assert.match(IMAGE, /parentJobId: d\.parentJobId \|\| ""/, "未传父子关系");
});

// ─────────────────────────────────────────────────────────────
// 额度与错误语义
// ─────────────────────────────────────────────────────────────

test("QUOTA-01 额度服务不可用返回 503，不误报「已用完」", () => {
  assert.match(IMAGE, /if \(q\.unavailable\)/, "未区分不可用");
  assert.match(IMAGE, /error: "QUOTA_CHECK_UNAVAILABLE"/, "缺少 503 专用错误码");
  assert.match(IMAGE, /这次没有生成图片，也不会扣费/, "缺少「未扣费」的明确说明");
});

test("QUOTA-02 组图先估算再启动，余额不足不跑半套", () => {
  const seg = IMAGE.slice(IMAGE.indexOf('if (taskKind === "series")'));
  assert.match(seg.slice(0, 1600), /const unitWorst = Math\.max/, "未按最贵档估算");
  assert.match(seg.slice(0, 1600), /error: "QUOTA_INSUFFICIENT"/, "余额不足时未拒绝");
  assert.match(seg.slice(0, 1600), /actions: \["single_only", "renew", "cancel"\]/, "未给出可执行降级选项");
});

// ─────────────────────────────────────────────────────────────
// 同步：翻页与并发
// ─────────────────────────────────────────────────────────────

test("SYNC-03 页尾毫秒组补齐，单字段降级也不漏数据", () => {
  assert.match(API, /TIE_TOTAL_CAP/, "缺少同毫秒组上限");
  assert.match(API, /updatedAt: _\.eq\(lastTs\), _id: _\.gt\(String\(last\._id\)\)/, "未补齐页尾同毫秒组");
  assert.match(API, /ordering = "updatedAt-only\+ties"/, "降级路径没有标记");
  assert.match(API, /hasMore, nextCursor, limit, ordering,/, "响应未暴露 ordering（运维看不到降级）");
});

test("SYNC-04 push 用确定性 _id，撞车按 LWW 合并", () => {
  assert.match(API, /const detId = crypto\.createHash\("sha256"\)/, "缺少确定性 ID");
  assert.match(API, /add\(Object\.assign\(\{ _id: detId \}, doc\)\)/, "新建未用确定性 ID");
  assert.match(API, /catch \(eAdd\)[\s\S]{0,700}skippedIds\.push\(refId\)/, "撞车后未按 LWW 处理");
});

// ─────────────────────────────────────────────────────────────
// 10-24 P1-5：组图任务状态机（start / step / status / cancel）
// ─────────────────────────────────────────────────────────────

test("SERIES-09 四个任务端点都存在且顺序正确", () => {
  for (const p of ["/series/start", "/series/step", "/series/status", "/series/cancel"]) {
    assert.ok(IMAGE.includes(`u.indexOf("${p}")`), `缺少路由 ${p}`);
  }
  // step 必须在重试接口之前被匹配（否则 /series/retry 会被当成 step）
  const iStep = IMAGE.indexOf('u.indexOf("/series/step")');
  const iRetry = IMAGE.indexOf('u.indexOf("/series/retry")');
  assert.ok(iStep > 0 && iRetry > iStep, "路由顺序异常");
});

test("SERIES-10 任务文档持久化请求参数，重启后可续跑", () => {
  const seg = IMAGE.slice(IMAGE.indexOf('u.indexOf("/series/start")'));
  const body = seg.slice(0, 4200);
  for (const k of ["prompt:", "structured:", "sizeResolved:", "qualityTier", "renderIntent", "aspectRatio"]) {
    assert.ok(body.includes(k), `任务文档缺少 ${k}（重开后无法续跑）`);
  }
  assert.match(body, /items: new Array\(n\)\.fill\(null\)/, "items 未按张数预置占位");
});

test("SERIES-11 step 幂等：已成功直接复用、已取消拒绝执行", () => {
  const seg = IMAGE.slice(IMAGE.indexOf('u.indexOf("/series/step")'));
  const body = seg.slice(0, 3000);
  assert.match(body, /existing && existing\.ok[\s\S]{0,200}reused: true/, "已成功的项未复用");
  assert.match(body, /status === "cancelled"[\s\S]{0,160}TASK_CANCELLED/, "已取消的任务仍会继续生成");
  assert.match(body, /accountId.*!==.*auth\.sub|String\(task\.accountId \|\| ""\) !== String\(auth\.sub\)/,
    "未校验任务归属（可跨账号操作别人的任务）");
});

test("SERIES-12 结束/取消时释放额度预留", () => {
  assert.match(IMAGE, /async function releaseQuota\(taskId, reason\)/);
  assert.match(IMAGE, /\["done", "partial", "failed", "cancelled"\]\.includes\(st\.status\)[\s\S]{0,120}releaseQuota/,
    "终态未释放预留");
  assert.match(IMAGE, /status: "cancelled"[\s\S]{0,200}releaseQuota\(taskId, "cancelled"\)/, "取消未释放预留");
});

test("SERIES-13 额度读取把生效中的预留算进去", () => {
  assert.match(IMAGE, /function authSubOf\(req\)/, "缺少从请求取 accountId 的辅助");
  assert.match(IMAGE, /const reserved = await activeReservedCny\(authSubOf\(req\)\)/, "quotaExhausted 未扣减预留");
  assert.match(IMAGE, /capCny - usedCny - reserved/, "剩余额度未减去预留");
  assert.match(IMAGE, /expiresAt: Date\.now\(\) \+ RESERVE_TTL_MS/, "预留缺少 TTL（进程崩溃会永久占额度）");
});

test("SERIES-14 两个 step 并发写同一任务不会互相覆盖", () => {
  assert.match(IMAGE, /\["items\." \+ \(index - 1\)\]: item/, "未用点路径更新单项（并发会丢项）");
  assert.match(IMAGE, /series_item_path_update_failed/, "点路径失败时没有降级记录");
});

test("SERIES-15 集合不存在时自动创建（否则记账与任务全部静默失效）", () => {
  assert.match(IMAGE, /async function ensureCollection\(name\)/, "缺少集合自建");
  assert.match(IMAGE, /getDb\(\)\.createCollection\(name\)/, "未调用 createCollection");
  assert.match(IMAGE, /await ensureCollection\(BILLING_COLL\)/, "记账前未确保账本集合存在");
  assert.match(IMAGE, /await ensureCollection\(RESERVE_COLL\)/, "预留前未确保集合存在");
  assert.match(IMAGE, /await ensureCollection\(SERIES_COLL\)/, "建任务前未确保集合存在");
});

test("SERIES-16 错误响应不吞掉任务状态字段", () => {
  assert.match(IMAGE, /if \(typeof body\.status === "number"\) delete body\.status/,
    "仍无条件删除 status（409 取消响应会丢失任务状态）");
});

test("SYNC-05 去重迁移默认只读，且用确定性 _id 迁移", () => {
  assert.match(API, /async function handleSyncDedupe\(req, res\)/, "缺少去重接口");
  assert.match(API, /const dryRun = body\.dryRun !== false/, "dryRun 未默认 true（误删风险）");
  assert.match(API, /const auth = await requireStaff\(req, res, true\)/, "去重接口未要求管理员");
  assert.match(API, /\.doc\(id\)\.remove\(\)/, "未删除重复记录");
  assert.match(API, /add\(Object\.assign\(\{ _id: item\.detId \}, copy\)\)[\s\S]{0,200}doc\(item\.keep\)\.remove\(\)/,
    "迁移不是「先写新、再删旧」（中途失败会丢数据）");
  // 10-24 新增：盘点必须能扫全集合，旧实现只取第一页，重复永远查不出来
  assert.match(API, /\.skip\(offset\)\.limit\(pageSize\)/, "去重盘点没有分页，扫不完整个集合");
});
