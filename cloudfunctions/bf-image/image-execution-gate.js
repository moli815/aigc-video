"use strict";

// One authorization decision for every route that can create a paid image.
// Read-only status/cancel routes intentionally do not use this gate.
function capabilityEnabled(value) {
  if (value === false || value === 0) return false;
  return !["0", "false", "off", "no"].includes(String(value == null ? "1" : value).trim().toLowerCase());
}

function quotaDenial(q) {
  if (q?.denied) {
    const code = q.code || (q.denied === 401 ? "UNAUTHORIZED" : "MEMBERSHIP_EXPIRED");
    const fallback = code === "ACCOUNT_SUSPENDED" ? "该账号已停用，请联系客服"
      : code === "MEMBERSHIP_EXPIRED" ? "会员已到期，请联系续费"
        : "登录状态已失效，请重新登录";
    const msg = q.message || fallback;
    return { status: q.denied, body: {
      ok: false, code: q.denied, error: code, msg, message: msg,
      actions: q.denied === 401 ? ["relogin"] : ["renew"],
    } };
  }
  if (q?.unavailable) return { status: 503, body: {
    ok: false, code: 503, error: "QUOTA_CHECK_UNAVAILABLE",
    msg: "暂时无法确认额度，请稍后重试。这次没有生成图片，也不会扣费。",
  } };
  if (q?.exhausted) return { status: 429, body: {
    ok: false, code: 429, error: "POOL_EXHAUSTED",
    msg: "本月额度已用完，续费后立即恢复。", resetAt: q.resetAt || null,
  } };
  return null;
}

async function authorizeImageExecution(req, { enabled, quotaExhausted }) {
  if (!capabilityEnabled(enabled)) return { ok: false, denial: { status: 503, body: {
    ok: false, code: 503, error: "IMAGE_DISABLED", msg: "图片生成暂时停用，请稍后再试。",
  } } };
  const quota = await quotaExhausted(req);
  const denial = quotaDenial(quota);
  return denial ? { ok: false, denial } : { ok: true, quota };
}

module.exports = { capabilityEnabled, quotaDenial, authorizeImageExecution };
