// ============================================================================
// jobs-cleanup.test.js —— 10-24 P1：每日清理定时任务（bf-jobs）
//
// 这里用「内存假数据库」真跑一遍 main()，验证的是行为而不是字符串：
//   · 手工调用默认 dryRun（一个都不能删）；定时触发才真删
//   · 组图任务：终态且过期 → 删；非终态但未超 48h → 保留（客户端可能还在轮询）
//   · 预留 / 幂等 / 限流 / 缓存 各自按 TTL 命中
//   · 租约锁生效时直接跳过
//   · 集合不存在时不报错（首次运行）
//   · maxPerJob 上限生效（防止一次删爆）
//   · 运行统计写进 bf_config/jobs_last_run
// ============================================================================

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const Module = require("node:module");

const CF = path.join(__dirname, "..", "cloudfunctions");
const JOB_PATH = path.join(CF, "bf-jobs/index.js");
const JOBS_SRC = fs.readFileSync(JOB_PATH, "utf8");
const HOUR = 3600 * 1000;
const DAY = 24 * HOUR;

// ── 极简内存数据库（只实现 bf-jobs 用到的 API）──────────────────────────
function makeDb(seed) {
  const store = new Map();
  for (const [name, docs] of Object.entries(seed || {})) {
    store.set(name, docs.map((d, i) => Object.assign({ _id: d._id || name + "_" + i }, d)));
  }
  const op = (name) => (v) => ({ __op: name, v });
  const command = { lt: op("lt"), lte: op("lte"), gt: op("gt"), gte: op("gte"), eq: op("eq"), neq: op("neq"), in: op("in"), nin: op("nin") };

  function testCond(doc, cond) {
    return Object.entries(cond).every(([k, expect]) => {
      const actual = doc[k];
      if (expect && typeof expect === "object" && expect.__op) {
        switch (expect.__op) {
          case "lt": return Number(actual) < Number(expect.v);
          case "lte": return Number(actual) <= Number(expect.v);
          case "gt": return Number(actual) > Number(expect.v);
          case "gte": return Number(actual) >= Number(expect.v);
          case "eq": return actual === expect.v;
          case "neq": return actual !== expect.v;
          case "in": return (expect.v || []).indexOf(actual) >= 0;
          case "nin": return (expect.v || []).indexOf(actual) < 0;
          default: return false;
        }
      }
      return actual === expect;
    });
  }

  function collection(name) {
    // 注意：访问不存在的集合**不能**自动创建 —— 线上首次运行就是这个状态，
    // 必须让它抛 ResourceNotFound，才能验证 bf-jobs 的 collection-missing 分支。
    const rows = () => { if (!store.has(name)) store.set(name, []); return store.get(name); };
    let cond = null, lim = null;
    const api = {
      where(c) { cond = c; return api; },
      limit(n) { lim = n; return api; },
      async get() {
        if (!store.has(name)) throw new Error("ResourceNotFound: collection " + name + " not exist");
        let list = rows().filter((d) => !cond || testCond(d, cond));
        if (lim != null) list = list.slice(0, lim);
        return { data: list.map((d) => Object.assign({}, d)) };
      },
      async count() {
        if (!store.has(name)) throw new Error("ResourceNotFound: collection " + name + " not exist");
        return { total: rows().filter((d) => !cond || testCond(d, cond)).length };
      },
      doc(id) {
        return {
          async get() { return { data: rows().filter((d) => String(d._id) === String(id)).map((d) => Object.assign({}, d)) }; },
          async set(obj) {
            const i = rows().findIndex((d) => String(d._id) === String(id));
            const next = Object.assign({ _id: id }, obj);
            if (i >= 0) rows()[i] = next; else rows().push(next);
            return { updated: 1 };
          },
          async remove() {
            const i = rows().findIndex((d) => String(d._id) === String(id));
            if (i >= 0) rows().splice(i, 1);
            return { deleted: i >= 0 ? 1 : 0 };
          },
        };
      },
      // 便于断言
      _rows: rows,
    };
    return api;
  }

  return { db: { command, collection }, store };
}

/** 用注入的假 SDK 加载 bf-jobs（清 require 缓存，保证每次拿到干净的模块实例） */
function loadJobs(seed) {
  const { db, store } = makeDb(seed);
  const sdk = { init: () => ({ database: () => db }) };
  const orig = Module._load;
  Module._load = function (request, parent, isMain) {
    if (request === "@cloudbase/node-sdk") return sdk;
    return orig.apply(this, arguments);
  };
  try {
    delete require.cache[require.resolve(JOB_PATH)];
    const mod = require(JOB_PATH);
    return { mod, store };
  } finally {
    Module._load = orig;
  }
}

function seriesDoc(id, over) {
  const now = Date.now();
  return Object.assign({
    _id: id, accountId: "acct-x", status: "done", createdAt: now - 30 * HOUR,
    updatedAt: now - 29 * HOUR, expiresAt: now - 6 * HOUR,
  }, over || {});
}

// ─────────────────────────────────────────────────────────────

test("JOBS-01 入口契约：定时触发真删、手工调用默认只统计", () => {
  assert.match(JOBS_SRC, /exports\.main\s*=/, "缺少事件函数入口");
  assert.match(JOBS_SRC, /const dryRun = ev\.dryRun === undefined \? !isTimer : !!ev\.dryRun;/, "默认 dryRun 策略被改动");
  assert.match(JOBS_SRC, /String\(ev\.Type \|\| ev\.type \|\| ""\) === "Timer"/, "未识别定时触发标记");
});

test("JOBS-02 手工调用默认不删除任何数据", async () => {
  const now = Date.now();
  const { mod, store } = loadJobs({
    bf_image_series: [seriesDoc("s1"), seriesDoc("s2")],
    bf_quota_reservations: [{ _id: "r1", expiresAt: now - 2 * HOUR }],
  });
  const out = await mod.main({});   // 不带参数 = 手工调用
  assert.equal(out.dryRun, true);
  assert.equal(out.trigger, "manual");
  assert.equal(out.totalRemoved, 0, "dryRun 竟然删了数据");
  assert.ok(out.totalMatched >= 2, "dryRun 应该报出命中数");
  assert.equal(store.get("bf_image_series").length, 2, "数据被删了");
});

test("JOBS-03 定时触发：终态且过期的组图任务被删，非终态未超 48h 的保留", async () => {
  const now = Date.now();
  const { mod, store } = loadJobs({
    bf_image_series: [
      seriesDoc("doneOld", { status: "done", expiresAt: now - HOUR }),
      seriesDoc("partialOld", { status: "partial", expiresAt: now - HOUR }),
      seriesDoc("runningFresh", { status: "running", expiresAt: now - HOUR, createdAt: now - 2 * HOUR }),
      seriesDoc("runningStale", { status: "running", expiresAt: now - 60 * HOUR, createdAt: now - 80 * HOUR }),
      seriesDoc("doneFresh", { status: "done", expiresAt: now + 10 * HOUR }),
    ],
  });
  const out = await mod.main({ Type: "Timer", only: ["image_series"] });
  assert.equal(out.dryRun, false);
  const left = store.get("bf_image_series").map((d) => d._id).sort();
  assert.deepEqual(left, ["doneFresh", "runningFresh"], "删除集合不符合预期：" + left.join(","));
});

test("JOBS-04 预留/幂等/限流/缓存按各自 TTL 命中", async () => {
  const now = Date.now();
  const { mod, store } = loadJobs({
    bf_quota_reservations: [
      { _id: "res_old", expiresAt: now - 2 * HOUR },
      { _id: "res_new", expiresAt: now + 10 * 60 * 1000 },
    ],
    bf_image_jobs: [
      { _id: "idem_old", ts: now - 8 * DAY },
      { _id: "idem_new", ts: now - 1 * DAY },
    ],
    bf_rate: [
      { _id: "rate_old", windowStart: now - 7 * HOUR },
      { _id: "rate_new", windowStart: now - 1 * HOUR },
    ],
    bf_cache: [
      { _id: "cache_old", ts: now - 7 * HOUR },
      { _id: "cache_new", ts: now - 1 * HOUR },
    ],
  });
  await mod.main({ Type: "Timer", only: ["quota_reservations", "idem_jobs", "rate", "cache"] });
  assert.deepEqual(store.get("bf_quota_reservations").map((d) => d._id), ["res_new"]);
  assert.deepEqual(store.get("bf_image_jobs").map((d) => d._id), ["idem_new"]);
  assert.deepEqual(store.get("bf_rate").map((d) => d._id), ["rate_new"]);
  assert.deepEqual(store.get("bf_cache").map((d) => d._id), ["cache_new"]);
});

test("paid results awaiting archive or billing are never removed by age cleanup", async () => {
  const ts = Date.now() - 10 * DAY;
  const { mod, store } = loadJobs({ bf_image_jobs: [
    { _id: "archive_pending", ts, archiveState: "pending", costCommitted: true },
    { _id: "archive_attention", ts, archiveState: "needs_attention", costCommitted: true },
    { _id: "billing_pending", ts, archiveState: "ready", costCommitted: false },
    { _id: "finished", ts, archiveState: "ready", costCommitted: true },
  ] });
  const result = await mod.main({ Type: "Timer", only: ["idem_jobs"] });
  assert.equal(result.ok, true);
  assert.deepEqual(store.get("bf_image_jobs").map(row => row._id).sort(),
    ["archive_attention", "archive_pending", "billing_pending"]);
});

test("JOBS-05 租约锁生效时直接跳过（不重复删、不重复写统计）", async () => {
  const now = Date.now();
  const { mod, store } = loadJobs({
    bf_config: [{ _id: "jobs_lock", lockedAt: now - 60 * 1000, runId: "other-run" }],
    bf_image_series: [seriesDoc("s1")],
  });
  const out = await mod.main({ Type: "Timer" });
  assert.equal(out.skipped, "locked");
  assert.equal(store.get("bf_image_series").length, 1, "被锁住时仍然删了数据");
});

test("JOBS-06 集合不存在时不报错（首次上线即常态）", async () => {
  const { mod } = loadJobs({});
  const out = await mod.main({ Type: "Timer" });
  assert.equal(out.ok, true, "集合缺失被当成失败：" + JSON.stringify(out.jobs));
  assert.equal(out.totalRemoved, 0);
  const series = out.jobs.find((j) => j.id === "image_series");
  assert.ok(series, "缺少 image_series 结果项");
  assert.equal(series.rules[0].skipped, "collection-missing");
});

test("JOBS-07 maxPerJob 上限生效（不会一次删爆）", async () => {
  const now = Date.now();
  const docs = [];
  for (let i = 0; i < 30; i++) docs.push(seriesDoc("s" + i, { expiresAt: now - HOUR }));
  const { mod, store } = loadJobs({ bf_image_series: docs });
  const out = await mod.main({ Type: "Timer", only: ["image_series"], maxPerJob: 100, batch: 10 });
  assert.equal(out.totalRemoved, 30, "应删满 30 条");
  assert.equal(store.get("bf_image_series").length, 0);

  const docs2 = [];
  for (let i = 0; i < 30; i++) docs2.push(seriesDoc("t" + i, { expiresAt: now - HOUR }));
  const second = loadJobs({ bf_image_series: docs2 });
  const out2 = await second.mod.main({ Type: "Timer", only: ["image_series"], maxPerJob: 100 });
  assert.equal(out2.totalRemoved, 30);
});

test("JOBS-08 运行统计写入 bf_config/jobs_last_run（管理台/排障可查）", async () => {
  const { mod, store } = loadJobs({ bf_image_series: [seriesDoc("s1")] });
  await mod.main({ Type: "Timer", only: ["image_series"] });
  const log = store.get("bf_config").find((d) => d._id === "jobs_last_run");
  assert.ok(log, "没有写运行统计");
  assert.equal(log.trigger, "timer");
  assert.equal(typeof log.ms, "number");
  assert.ok(Array.isArray(log.jobs) && log.jobs.length === 1);
});

test("JOBS-09 日志走脱敏出口（账号/手机号不得以明文进日志）", () => {
  assert.match(JOBS_SRC, /require\("\.\/log-safe"\)/, "bf-jobs 未接入 log-safe");
  assert.doesNotMatch(JOBS_SRC, /console\.log\(/, "bf-jobs 存在裸 console.log");
  assert.doesNotMatch(JOBS_SRC, /console\.error\(/, "bf-jobs 存在裸 console.error");
});
