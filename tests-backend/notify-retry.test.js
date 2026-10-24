// ============================================================================
// notify-retry.test.js —— 通知补发策略（C1.4）
// 真单测：编排逻辑注入假的 deliver/mark，不依赖数据库。
// ============================================================================

const test = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");
const { MAX_ATTEMPTS, notificationId, nextDelayMs, shouldRetry, sweep } =
  require(path.join(__dirname, "../cloudfunctions/bf-api/notify-retry.js"));

const NOW = 1_800_000_000_000;

test("NR-01 通知 ID 稳定：同申请同类型永远同一个 ID", () => {
  assert.equal(notificationId("r1", "request_approved"), notificationId("r1", "request_approved"));
  assert.notEqual(notificationId("r1", "request_approved"), notificationId("r2", "request_approved"));
  assert.notEqual(notificationId("r1", "request_approved"), notificationId("r1", "request_rejected"));
});

test("NR-02 已发送/终态失败不再重试", () => {
  assert.deepEqual(shouldRetry({ notifyState: "sent" }, NOW), { retry: false, reason: "already-sent" });
  const f = shouldRetry({ notifyState: "failed" }, NOW);
  assert.equal(f.retry, false);
  assert.equal(f.terminal, true);
});

test("NR-03 退避期内不重试，到点才重试", () => {
  assert.equal(shouldRetry({ notifyState: "pending", notifyAttempts: 1, notifyNextAt: NOW + 1000 }, NOW).retry, false);
  assert.equal(shouldRetry({ notifyState: "pending", notifyAttempts: 1, notifyNextAt: NOW - 1 }, NOW).retry, true);
});

test("NR-04 超过上限进入终态，不会无限重试", () => {
  const d = shouldRetry({ notifyState: "pending", notifyAttempts: MAX_ATTEMPTS }, NOW);
  assert.equal(d.retry, false);
  assert.equal(d.terminal, true);
});

test("NR-05 退避是指数增长且有封顶", () => {
  const a1 = nextDelayMs(1, () => 0);
  const a3 = nextDelayMs(3, () => 0);
  assert.ok(a3 > a1, "尝试次数越多间隔越长");
  assert.ok(nextDelayMs(20, () => 1) <= 30 * 60_000 * 1.2, "必须有封顶");
});

test("NR-06 补发成功：只投递通知，不碰审核/开通", async () => {
  const delivered = [], marks = [];
  const r = await sweep({
    listPending: async () => [{ _id: "r1", type: "create", notifyState: "pending", notifyAttempts: 0, notifyNextAt: 0 }],
    buildNotice: (doc) => ({ kind: "approved", ref: doc._id }),
    deliver: async (n, id) => { delivered.push({ n, id }); },
    mark: async (id, patch) => { marks.push({ id, patch }); },
  }, NOW);
  assert.equal(r.sent, 1);
  assert.equal(delivered.length, 1);
  assert.equal(delivered[0].id, notificationId("r1", "create"), "投递必须带稳定 ID");
  assert.equal(marks[0].patch.notifyState, "sent");
});

test("NR-07 投递失败：记错误与下次时间，状态退回 pending", async () => {
  const marks = [];
  const r = await sweep({
    listPending: async () => [{ _id: "r1", type: "create", notifyState: "pending", notifyAttempts: 1 }],
    buildNotice: () => ({ kind: "approved" }),
    deliver: async () => { throw new Error("入库超时"); },
    mark: async (id, patch) => { marks.push(patch); },
  }, NOW);
  assert.equal(r.errors, 1);
  assert.equal(marks[0].notifyState, "pending");
  assert.equal(marks[0].notifyAttempts, 2);
  assert.ok(marks[0].notifyLastError.includes("超时"));
  assert.ok(marks[0].notifyNextAt > NOW, "必须排下次重试时间");
});

test("NR-08 最后一次尝试失败 → 终态 failed（可观测，不静默）", async () => {
  const marks = [];
  await sweep({
    listPending: async () => [{ _id: "r1", type: "create", notifyState: "pending", notifyAttempts: MAX_ATTEMPTS - 1 }],
    buildNotice: () => ({}),
    deliver: async () => { throw new Error("still down"); },
    mark: async (id, patch) => { marks.push(patch); },
  }, NOW);
  assert.equal(marks[0].notifyState, "failed");
  assert.equal(marks[0].notifyNextAt, 0);
});

test("NR-09 补发任务重复运行不会重复投递（已 sent 直接跳过）", async () => {
  const delivered = [];
  const r = await sweep({
    listPending: async () => [{ _id: "r1", type: "create", notifyState: "sent", notifyAttempts: 1 }],
    buildNotice: () => ({}),
    deliver: async () => { delivered.push(1); },
    mark: async () => {},
  }, NOW);
  assert.equal(delivered.length, 0);
  assert.equal(r.skipped, 1);
});

test("NR-10 单轮有上限，避免一次拉爆", async () => {
  const docs = Array.from({ length: 50 }, (_, i) => ({ _id: "r" + i, type: "create", notifyState: "pending", notifyAttempts: 0 }));
  let delivered = 0;
  await sweep({
    listPending: async () => docs,
    buildNotice: () => ({}),
    deliver: async () => { delivered += 1; },
    mark: async () => {},
  }, NOW, 10);
  assert.equal(delivered, 10, "limit 必须生效");
});

// ── C2 边界（用户点名的 4 个细节）────────────────────────────────────────────
const fs2 = require("node:fs");
const API_SRC = fs2.readFileSync(path.join(__dirname, "../cloudfunctions/bf-api/index.js"), "utf8");
const ADMIN_SRC = fs2.readFileSync(path.join(__dirname, "../web/admin.html"), "utf8");

test("BND-01 nextAt 必须参与数据库筛选，不能只在内存判", () => {
  const start = API_SRC.indexOf("listPending:");
  const body = API_SRC.slice(start, start + 700);
  assert.ok(body.includes("notifyNextAt: db.command.lte(Date.now())"),
    "查询未按 nextAt 过滤：退避中的文档会占满窗口，把到点的挤出去");
});

test("BND-02 稳定 ID 撞车 = 已投递，不能当失败重试", () => {
  const start = API_SRC.indexOf("deliver: async (notice, id)");
  const body = API_SRC.slice(start, start + 500);
  assert.ok(body.includes("isDuplicateKeyError(e)"), "重复键未特殊处理");
  assert.ok(/if \(isDuplicateKeyError\(e\)\) return;/.test(body), "重复键未按已投递处理");
});

test("BND-03 attempts 只在实际尝试时增加，跳过不消耗", () => {
  const start = path.join(__dirname, "../cloudfunctions/bf-api/notify-retry.js");
  const src = fs2.readFileSync(start, "utf8");
  const sweepStart = src.indexOf("const attempts = Number(doc.notifyAttempts || 0) + 1;");
  const skipBranch = src.indexOf('result.skipped += 1;');
  assert.ok(sweepStart > 0, "没有 attempts 递增");
  assert.ok(skipBranch > 0 && skipBranch < sweepStart, "跳过分支必须在递增之前 return");
});

test("BND-04 手动补发只动通知，且必须管理员 + 审计", () => {
  const start = API_SRC.indexOf("async function handleRetryNotify");
  const body = API_SRC.slice(start, start + 1600);
  assert.ok(body.includes('auditLog(staff, "request.notify.retry"'), "补发没有审计");
  assert.ok(!body.includes("doApprove("), "补发里不能调用开通逻辑");
  assert.ok(!body.includes("approveRequest("), "补发里不能调用审核逻辑");
  assert.ok(API_SRC.includes('sub[2] === "retry-notify"'), "缺少路由");
  assert.ok(/retry-notify"[\s\S]{0,120}requireStaff\(req, res, true\)/.test(API_SRC), "补发接口未要求管理员");
});

test("BND-05 管理端把审核结果与通知状态分开呈现", () => {
  assert.ok(ADMIN_SRC.includes('id="recentBox"'), "缺少已处理区块");
  assert.ok(ADMIN_SRC.includes("function notifyBadge"), "缺少通知状态徽章");
  assert.ok(ADMIN_SRC.includes("通知已送达") && ADMIN_SRC.includes("通知待重试") && ADMIN_SRC.includes("通知发送失败"),
    "三种通知状态未完整呈现");
  assert.ok(ADMIN_SRC.includes("data-act=\"retryNotify\""), "缺少补发入口");
  assert.ok(ADMIN_SRC.includes("/retry-notify"), "未调用补发接口");
  // 已处理列表不能混进待审核
  assert.ok(ADMIN_SRC.includes("r.status!=='pending'"), "已处理列表未排除待审核");
});
