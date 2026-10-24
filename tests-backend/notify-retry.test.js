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
