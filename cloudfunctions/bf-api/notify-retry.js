// notify-retry.js —— 通知补发的策略层（2026-10-25 C1.4）
//
// 为什么单独成模块：补发的正确性全在"该不该再试一次"这个判断上，
// 而它最容易写成 "while(true) 重试" 或者"失败就当成功"。抽出来才能单测。
//
// 生命周期：
//   sent    → 投递成功（终态）
//   pending → 待补发（可重试，带退避）
//   failed  → 超过上限（终态，必须人工看，不能静默）
//
// 关键约束：
//   · 补发只重建**通知**，绝不重跑审核/开通（调用方只传通知内容）；
//   · 每次尝试用固定 _id（幂等），重复执行不会产生两条通知；
//   · 失败不伪装成审核失败：审核结果与通知状态分离存放。

const MAX_ATTEMPTS = 5;
const BASE_DELAY_MS = 60_000;        // 1 分钟起
const MAX_DELAY_MS = 30 * 60_000;    // 封顶 30 分钟

/** 稳定的通知 ID：同一申请 + 同一类型只会有一条 */
function notificationId(requestId, kind) {
  const raw = String(requestId) + ":" + String(kind || "notice");
  let h = 0;
  for (let i = 0; i < raw.length; i++) {
    h = (h * 31 + raw.charCodeAt(i)) >>> 0;
  }
  return "ntf_" + h.toString(36) + "_" + raw.length;
}

/** 指数退避（带 20% 抖动，避免同一时刻一起重试） */
function nextDelayMs(attempts, rand = Math.random) {
  const exp = Math.min(MAX_DELAY_MS, BASE_DELAY_MS * Math.pow(2, Math.max(0, attempts - 1)));
  const jitter = exp * 0.2 * rand();
  return Math.round(exp + jitter);
}

/**
 * 是否应该现在补发。
 * @param {{notifyState?:string, notifyAttempts?:number, notifyNextAt?:number}} doc
 * @param {number} nowMs
 * @returns {{retry:boolean, reason:string, terminal?:boolean}}
 */
function shouldRetry(doc, nowMs) {
  const state = String((doc && doc.notifyState) || "");
  const attempts = Number((doc && doc.notifyAttempts) || 0);
  if (state === "sent") return { retry: false, reason: "already-sent" };
  if (state === "failed") return { retry: false, reason: "terminal-failed", terminal: true };
  if (attempts >= MAX_ATTEMPTS) return { retry: false, reason: "attempts-exhausted", terminal: true };
  const nextAt = Number((doc && doc.notifyNextAt) || 0);
  if (nextAt && nextAt > nowMs) return { retry: false, reason: "backoff" };
  return { retry: true, reason: state === "pending" ? "pending" : "missing-status" };
}

/**
 * 执行一轮补发（纯编排，副作用由注入的函数完成，便于测试）。
 * @param {object} deps
 * @param {() => Promise<Array>} deps.listPending 返回待处理的申请文档（已筛选）
 * @param {(doc) => Promise<object>} deps.buildNotice 由申请文档构造通知体
 * @param {(notice, id) => Promise<void>} deps.deliver 投递（重复投递应抛错或幂等）
 * @param {(id, patch) => Promise<void>} deps.mark 回写状态
 * @param {number} nowMs
 * @param {number} limit 单轮上限，防止一次拉爆
 */
async function sweep(deps, nowMs, limit = 20) {
  const docs = (await deps.listPending()) || [];
  const result = { scanned: docs.length, retried: 0, sent: 0, failed: 0, skipped: 0, errors: 0 };
  for (const doc of docs.slice(0, limit)) {
    const decision = shouldRetry(doc, nowMs);
    if (!decision.retry) {
      if (decision.terminal) {
        await deps.mark(doc._id, { notifyState: "failed", notifyLastError: decision.reason });
        result.failed += 1;
      } else {
        result.skipped += 1;
      }
      continue;
    }
    const attempts = Number(doc.notifyAttempts || 0) + 1;
    result.retried += 1;
    try {
      const notice = deps.buildNotice(doc);
      await deps.deliver(notice, notificationId(doc._id, doc.type));
      await deps.mark(doc._id, {
        notifyState: "sent", notifyAttempts: attempts, notifyLastError: "", notifySentAt: nowMs,
      });
      result.sent += 1;
    } catch (e) {
      const msg = String((e && e.message) || e).slice(0, 120);
      const exhausted = attempts >= MAX_ATTEMPTS;
      await deps.mark(doc._id, {
        notifyState: exhausted ? "failed" : "pending",
        notifyAttempts: attempts,
        notifyLastError: msg,
        notifyNextAt: exhausted ? 0 : nowMs + nextDelayMs(attempts),
      });
      result.errors = (result.errors || 0) + 1;
      if (exhausted) result.failed += 1;
    }
  }
  return result;
}

module.exports = { MAX_ATTEMPTS, notificationId, nextDelayMs, shouldRetry, sweep };
