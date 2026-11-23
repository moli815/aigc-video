/**
 * bf-jobs —— 每日数据清理定时任务（CloudBase 事件函数，timer 触发）
 *
 * 为什么需要它
 *   生图链路引入了若干「短期状态」集合：组图任务、额度预留、幂等台账、限流计数、语义缓存。
 *   它们都有各自的过期语义，但**没有任何东西去删**：
 *     · bf_image_series      expiresAt = 创建 + 24h，任务结束后就没人再看
 *     · bf_quota_reservations expiresAt = 创建 + 30min，只是并发预检用的临时登记
 *     · bf_image_jobs        幂等台账，5 分钟就失效，但文档永久留着
 *     · bf_rate              每小时一个桶，写完再也不会被读
 *     · bf_cache             读侧 6h TTL，但行本身永远不删
 *   数据无限累积 → 集合变大 → 查询变慢、按量计费上升，且历史 prompt/任务记录长期留存（合规风险）。
 *
 * 设计要点（防呆优先）
 *   1. **默认安全**：手工调用（不带参数）默认 dryRun=true，只统计不删除；
 *      定时触发器调用（event.Type === "Timer"）才真删。避免误点一下就清库。
 *   2. **有界**：每集合每次最多删 maxPerJob 条、每批 batch 条，单次执行不会跑爆超时。
 *   3. **只删该删的**：组图任务分两条规则 —— 已终态且过期立即删；非终态要过期 48h 才删
 *      （避免把「客户端还在轮询的长任务」提前删掉导致 404）。
 *   4. **可观测**：每次运行把统计写进 bf_config/jobs_last_run，管理台/排障可直接查。
 *   5. **不重叠**：bf_config/jobs_lock 做 15 分钟租约锁，前一次没跑完时本次直接跳过。
 *   6. 任何一步失败都不影响其它集合；返回体里逐项如实报错。
 *
 * 触发时间：每天 03:30（CloudBase 7 段 cron：0 30 3 * * * *），低峰期。
 */
const tcb = require("@cloudbase/node-sdk");
const { logSafe } = require("./log-safe");
const { createImageArchiver } = require("./shared/image-archive");

let __db = null;
let __app = null;
function getDb() {
  if (!__db) {
    const env = process.env.TCB_ENV || process.env.SCF_NAMESPACE || "";
    __app = tcb.init(env ? { env } : {});
    __db = __app.database();
  }
  return __db;
}

const DAY = 24 * 3600 * 1000;
const HOUR = 3600 * 1000;

// 可调参数（环境变量覆盖，便于不重新部署就调整保留期）
const CFG = {
  batch: Math.min(200, Math.max(10, Number(process.env.JOBS_BATCH || 100))),
  maxPerJob: Math.min(20000, Math.max(100, Number(process.env.JOBS_MAX_PER_JOB || 5000))),
  seriesStaleHours: Math.max(24, Number(process.env.JOBS_SERIES_STALE_HOURS || 48)),
  idemDays: Math.max(1, Number(process.env.JOBS_IDEM_DAYS || 7)),
  rateHours: Math.max(1, Number(process.env.JOBS_RATE_HOURS || 6)),
  cacheHours: Math.max(1, Number(process.env.JOBS_CACHE_HOURS || 6)),
  crashDays: Math.max(7, Number(process.env.JOBS_CRASH_DAYS || 90)),
};

const LOCK_ID = "jobs_lock";
const LOCK_TTL = 15 * 60 * 1000;

function specsOf(_, now) {
  const staleMs = CFG.seriesStaleHours * HOUR;
  return [
    {
      id: "image_series", collection: "bf_image_series", label: "组图任务",
      rules: [
        { name: "expired_terminal", desc: "已终态且过 24h 过期", where: () => ({ expiresAt: _.lt(now), status: _.in(["done", "partial", "failed", "cancelled"]) }) },
        { name: "expired_stale", desc: "非终态但过期超 48h（客户端早已放弃）", where: () => ({ expiresAt: _.lt(now - staleMs) }) },
      ],
    },
    {
      id: "quota_reservations", collection: "bf_quota_reservations", label: "额度预留",
      rules: [
        { name: "expired", desc: "预留 TTL(30min) 已过 + 1h 宽限", where: () => ({ expiresAt: _.lt(now - HOUR) }) },
      ],
    },
    {
      id: "idem_jobs", collection: "bf_image_jobs", label: "幂等台账",
      rules: [
        { name: "aged", desc: `创建超过 ${CFG.idemDays} 天，且没有待恢复归档`, where: () => ({
          ts: _.lt(now - CFG.idemDays * DAY), archiveState: _.nin(["pending", "needs_attention"]), costCommitted: _.neq(false),
        }) },
      ],
    },
    {
      id: "rate", collection: "bf_rate", label: "限流计数",
      rules: [
        { name: "aged", desc: `窗口早于 ${CFG.rateHours} 小时`, where: () => ({ windowStart: _.lt(now - CFG.rateHours * HOUR) }) },
      ],
    },
    {
      id: "cache", collection: "bf_cache", label: "语义缓存",
      rules: [
        { name: "aged", desc: `写入超过 ${CFG.cacheHours} 小时（读侧 TTL 也是 6h）`, where: () => ({ ts: _.lt(now - CFG.cacheHours * HOUR) }) },
      ],
    },
    {
      id: "crashes", collection: "bf_crashes", label: "崩溃上报",
      rules: [
        { name: "aged", desc: `超过 ${CFG.crashDays} 天`, where: () => ({ ts: _.lt(now - CFG.crashDays * DAY) }) },
      ],
    },
  ];
}

/** 统计一个条件命中的条数；集合不存在时返回 -1（首次运行很常见，不算错误） */
async function countMatching(colName, cond) {
  try {
    const r = await getDb().collection(colName).where(cond).count();
    return Number(r && (r.total !== undefined ? r.total : r.totalCount) || 0);
  } catch (e) {
    const msg = String((e && e.message) || e);
    if (/not exist|ResourceNotFound|collection not found|DATABASE_COLLECTION_NOT_EXIST/i.test(msg)) return -1;
    throw e;
  }
}

/** 分批删除：每批取 _id 再按 id 删（比 where().remove() 可控，能精确统计与限流） */
async function deleteBatch(colName, cond, limit) {
  const col = getDb().collection(colName);
  const r = await col.where(cond).limit(CFG.batch).get();
  const rows = (r && r.data) || [];
  if (!rows.length) return { removed: 0, full: false };
  let removed = 0;
  for (const row of rows) {
    if (removed >= limit) break;
    try { await col.doc(row._id).remove(); removed++; }
    catch (e) { /* 单条删失败：下次运行再试 */ }
  }
  return { removed, full: rows.length >= CFG.batch };
}

/** 租约锁：防止定时器重入 / 手工触发与定时触发撞车 */
async function acquireLock(runId, now, skip) {
  if (skip) return { ok: true, skipped: true };
  const col = getDb().collection("bf_config");
  try {
    const cur = await col.doc(LOCK_ID).get();
    const doc = (cur && cur.data && cur.data[0]) || null;
    if (doc && Number(doc.lockedAt || 0) > now - LOCK_TTL) {
      return { ok: false, holder: String(doc.runId || "").slice(0, 24), since: Number(doc.lockedAt || 0) };
    }
  } catch (e) { /* 读不到就当作没锁：宁可跑，也不要因为读失败永久卡住清理 */ }
  try {
    await col.doc(LOCK_ID).set({ lockedAt: now, runId, ttlMs: LOCK_TTL });
  } catch (e) {
    // 集合/文档不存在或写入失败：不阻断清理（锁是优化，不是正确性前提）
  }
  return { ok: true };
}

async function releaseLock(runId) {
  try {
    const col = getDb().collection("bf_config");
    const cur = await col.doc(LOCK_ID).get();
    const doc = (cur && cur.data && cur.data[0]) || null;
    if (doc && String(doc.runId || "") === String(runId)) {
      await col.doc(LOCK_ID).set({ lockedAt: 0, runId: "", ttlMs: LOCK_TTL, lastReleasedAt: Date.now() });
    }
  } catch (e) { /* 释放失败：等 TTL 自然过期 */ }
}

async function recordRun(summary) {
  try {
    const col = getDb().collection("bf_config");
    await col.doc("jobs_last_run").set(summary);
  } catch (e) { /* 只关心清理结果，观测写失败不影响返回 */ }
}

/**
 * 入口。event 支持：
 *   dryRun  —— 默认：定时触发 false / 手工调用 true（显式传 true 可强制只统计）
 *   only    —— 只跑指定集合 id（如 ["image_series"]）
 *   batch / maxPerJob —— 覆盖批次大小与单次上限
 *   skipLock —— 跳过租约锁（仅排障用）
 */
exports.main = async function main(event, context) {
  const startedAt = Date.now();
  const ev = event || {};
  const isTimer = String(ev.Type || ev.type || "") === "Timer";
  if (isTimer && String(ev.TriggerName || ev.triggerName || "") === "asset_archive_retry") {
    const database = getDb();
    const result = await createImageArchiver({ db: database, app: __app }).retryBatch(3);
    logSafe({ tag: "asset_archive_retry", ...result });
    return { ok: true, ...result };
  }
  const dryRun = ev.dryRun === undefined ? !isTimer : !!ev.dryRun;
  if (Number(ev.batch) > 0) CFG.batch = Math.min(200, Math.max(10, Number(ev.batch)));
  if (Number(ev.maxPerJob) > 0) CFG.maxPerJob = Math.min(20000, Math.max(100, Number(ev.maxPerJob)));
  const only = Array.isArray(ev.only) && ev.only.length ? ev.only.map(String) : null;
  const runId = (context && (context.request_id || context.requestId)) || ("job-" + startedAt.toString(36));
  const now = Date.now();

  let _;
  try { _ = getDb().command; }
  catch (e) {
    logSafe({ tag: "jobs_db_unavailable", runId, err: String((e && e.message) || e) }, "error");
    return { ok: false, error: "DB_UNAVAILABLE", message: "数据库初始化失败" };
  }

  const lock = await acquireLock(runId, now, !!ev.skipLock);
  if (!lock.ok) {
    logSafe({ tag: "jobs_skipped_locked", runId, holder: lock.holder });
    return { ok: true, skipped: "locked", holder: lock.holder, since: lock.since };
  }

  const specs = specsOf(_, now).filter((s) => !only || only.indexOf(s.id) >= 0);
  const result = { dryRun, runId, trigger: isTimer ? "timer" : "manual", startedAt: new Date(startedAt).toISOString(), jobs: [] };

  for (const spec of specs) {
    const jobOut = { id: spec.id, collection: spec.collection, label: spec.label, matched: 0, removed: 0, rules: [], errors: [] };
    for (const rule of spec.rules) {
      let cond;
      try { cond = rule.where(); }
      catch (e) { jobOut.errors.push(rule.name + ": build-condition"); continue; }
      try {
        const matched = await countMatching(spec.collection, cond);
        // 集合还没建过（首次运行常见）：跳过并标注，不算失败 —— 否则每次运行都会亮红灯
        if (matched < 0) { jobOut.rules.push({ rule: rule.name, skipped: "collection-missing" }); break; }
        jobOut.matched += matched;
        let removed = 0;
        if (!dryRun) {
          let guard = 0;
          // 每轮删一批，直到删够上限或没有可删的（guard 防止条件写错时死循环）
          while (removed < CFG.maxPerJob && guard++ < Math.ceil(CFG.maxPerJob / CFG.batch) + 2) {
            const r = await deleteBatch(spec.collection, cond, CFG.maxPerJob - removed);
            removed += r.removed;
            if (!r.full || removed >= CFG.maxPerJob) break;
          }
        }
        jobOut.removed += removed;
        jobOut.rules.push({ rule: rule.name, desc: rule.desc, matched, removed });
      } catch (e) {
        jobOut.errors.push(rule.name + ": " + String((e && e.message) || e).slice(0, 120));
      }
    }
    // 同一集合被多条规则命中时，removed 以实际删除次数为准；matched 是「规则视角」的命中数，
    // 两者不强行对齐（第二条规则执行时，第一条已经删掉一部分）。
    result.jobs.push(jobOut);
  }

  result.ms = Date.now() - startedAt;
  result.totalMatched = result.jobs.reduce((n, j) => n + j.matched, 0);
  result.totalRemoved = result.jobs.reduce((n, j) => n + j.removed, 0);
  result.ok = result.jobs.every((j) => !j.errors.length);
  result.finishedAt = new Date().toISOString();

  logSafe({
    tag: "jobs_done", runId, dryRun, trigger: result.trigger, ms: result.ms,
    totalMatched: result.totalMatched, totalRemoved: result.totalRemoved,
    jobs: result.jobs.map((j) => ({ id: j.id, matched: j.matched, removed: j.removed, errors: j.errors.length })),
  });

  await recordRun({
    runId, at: result.finishedAt, dryRun, trigger: result.trigger, ms: result.ms,
    totalMatched: result.totalMatched, totalRemoved: result.totalRemoved,
    jobs: result.jobs.map((j) => ({ id: j.id, matched: j.matched, removed: j.removed, errors: j.errors })),
    cfg: CFG,
  });
  await releaseLock(runId);
  return result;
};
