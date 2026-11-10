// ============================================================================
// auth-denied-contract.test.js —— 会员到期/停用的拒绝链路（2026-10-24 真机反馈）
//
// 现场：Ultra 账号侧栏误显示"已过期"时仍能正常聊天。查完后确认两件事：
//   ① 服务端 **确实** 拦到期账号（requireMember 校验 expiresAt），聊天能通说明账号本身有效，
//      是客户端显示错了 —— 这条要用测试锁住，防止哪天真的漏了；
//   ② bf-image 把 403（到期/停用）折叠成了 503「暂时无法确认额度」，用户与客服都无法判断原因，
//      这条是**真 bug**，已修为透传 401/403。
// ============================================================================

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.join(__dirname, "..");
const API = fs.readFileSync(path.join(ROOT, "cloudfunctions/bf-api/index.js"), "utf8");
const IMG = fs.readFileSync(path.join(ROOT, "cloudfunctions/bf-image/index.js"), "utf8");

test("DENY-01 bf-api 的会员鉴权必须校验到期/停用/会话代次", () => {
  const start = API.indexOf("async function requireMember");
  assert.ok(start > 0, "缺少 requireMember");
  const body = API.slice(start, start + 1600);
  assert.match(body, /acc\.status !== "active"[\s\S]{0,120}ACCOUNT_SUSPENDED/, "停用账号未被拦截");
  assert.match(body, /acc\.expiresAt[\s\S]{0,160}MEMBERSHIP_EXPIRED/, "会员到期未被拦截（会白送服务）");
  assert.match(body, /acc\.sv[\s\S]{0,120}SESSION_REPLACED/, "单设备登录校验缺失");
  assert.match(body, /acc\.pwv[\s\S]{0,120}UNAUTHORIZED/, "改密后旧 token 未失效");
});

test("DENY-02 聊天与作图都必须走 requireMember（不能有绕过口子）", () => {
  for (const fn of ["handleChat", "handleImage"]) {
    const start = API.indexOf(`async function ${fn}`);
    assert.ok(start > 0, `缺少 ${fn}`);
    const body = API.slice(start, start + 600);
    assert.match(body, /requireMember\(req, res\)/, `${fn} 没有做会员鉴权`);
  }
  // bf-image 独立函数：token 校验 + 额度回查（回查同时承担会员状态校验）
  assert.match(IMG, /async function requireMember/, "bf-image 缺少鉴权");
  assert.match(IMG, /quotaExhausted\(req\)/, "bf-image 没有回查额度/会员状态");
});

test("DENY-03 401/403 必须透传，不能折叠成「额度不可用」", () => {
  const start = IMG.indexOf("async function quotaExhausted");
  const body = IMG.slice(start, start + 2200);
  assert.match(body, /r\.status === 401 \|\| r\.status === 403/, "没有区分会员拒绝");
  assert.match(body, /denied: r\.status/, "拒绝状态没有带出来");
  assert.match(body, /errBody && errBody\.error/, "没有透传上游错误码");
  // 5xx 仍必须 fail-closed
  assert.match(body, /unavailable: true, reason: "auth-unavailable"/, "5xx 兜底被改动（会变成免费出图）");
});

test("DENY-04 所有付费作图入口共用同一个会员与额度门禁", () => {
  for (const route of ["/series/start", "/series/step", "/series/retry", "/image"]) {
    const start = IMG.indexOf(`u.indexOf("${route}")`);
    assert.ok(start > 0, `缺少 ${route}`);
    assert.match(IMG.slice(start, start + 4500), /paidImageGate\(req\)/, `${route} 未接入统一门禁`);
  }
  const gate = require("../cloudfunctions/bf-image/image-execution-gate");
  assert.equal(gate.quotaDenial({ denied: 401 }).status, 401);
  assert.equal(gate.quotaDenial({ denied: 403 }).status, 403);
  assert.equal(gate.quotaDenial({ unavailable: true }).status, 503);
  assert.equal(gate.quotaDenial({ exhausted: true }).status, 429);
});

test("DENY-05 门禁文案、actions 与 requestId 可直接使用", () => {
  const { quotaDenial } = require("../cloudfunctions/bf-image/image-execution-gate");
  assert.deepEqual(quotaDenial({ denied: 401 }).body.actions, ["relogin"]);
  assert.deepEqual(quotaDenial({ denied: 403 }).body.actions, ["renew"]);
  assert.match(quotaDenial({ denied: 403, code: "MEMBERSHIP_EXPIRED" }).body.msg, /会员已到期/);
  assert.match(quotaDenial({ denied: 403, code: "ACCOUNT_SUSPENDED" }).body.msg, /已停用/);
  assert.match(IMG, /requestId: currentRequestId\(\)/, "拒绝响应缺少 requestId（无法排查）");
});
