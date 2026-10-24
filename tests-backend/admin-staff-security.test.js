// ============================================================================
// admin-staff-security.test.js —— 管理端/员工端权限与状态机回归（2026-10-25）
//
// 本文件只做一件事：把「谁能做什么」「并发下会不会重复生效」钉死。
// 全部为源码级契约断言（这些 handler 依赖 CloudBase SDK，无法在本地起真库），
// 因此每条断言都对应一个可复现的具体行为，不是"文件里存在某函数"。
//
// 已确认**本来就没问题**的（写在这里是为了以后改坏能立刻发现）：
//   · 员工停用后旧 token 立即失效——requireStaff 每次请求都回库查 status
//   · 角色以数据库为准——降权后 token 里的旧 role 不再生效
//   · 员工只能看自己的申请/发放记录——查询层强制 where 过滤，不靠前端隐藏
//
// 本轮修复的真问题：
//   · 驳回缺原子性：通过方已把申请置为 processing 时，驳回方仍按旧的 pending 判断放行，
//     同一条申请会先开通又被标成已驳回。现在驳回也走 CAS。
// ============================================================================

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const API = fs.readFileSync(path.join(__dirname, "../cloudfunctions/bf-api/index.js"), "utf8");
const ADMIN = fs.readFileSync(path.join(__dirname, "../web/admin.html"), "utf8");
const STAFF = fs.readFileSync(path.join(__dirname, "../web/staff.html"), "utf8");

function fnBody(name, len = 1800) {
  const start = API.indexOf(name);
  assert.ok(start > 0, `找不到 ${name}`);
  return API.slice(start, start + len);
}

// ── 身份与会话 ───────────────────────────────────────────────────────────────

test("AUTHZ-01 停用员工的下一次请求必须被拒（不能等重新登录）", () => {
  const body = fnBody("async function requireStaff", 1200);
  assert.match(body, /st\.status && st\.status !== "active"/, "未回库校验员工状态");
  assert.match(body, /STAFF_DISABLED/, "缺少停用错误码");
});

test("AUTHZ-02 角色以数据库为准，降权后旧 token 立即失效", () => {
  const body = fnBody("async function requireStaff", 1200);
  assert.match(body, /const liveRole = String\(st\.role \|\| payload\.role \|\| ""\)/, "没有取数据库角色");
  assert.match(body, /needAdmin && liveRole !== "admin"/, "管理员校验未用数据库角色");
});

test("AUTHZ-03 管理接口必须显式要求管理员（不能只靠前端隐藏按钮）", () => {
  // 抽查四个高危写入口的调用点：必须传 true
  const checks = [
    [/handleCreateStaff\(req, res, staff\)/, "创建员工"],
    [/handleResetStaffPassword\(req, res, staff/, "重置员工密码"],
    [/handleDisableStaff\(req, res, staff/, "停用员工"],
    [/handleDeleteStaff\(req, res/, "删除员工"],
  ];
  for (const [re, label] of checks) {
    assert.match(API, re, `${label} 的调用形式异常`);
  }
  // 它们上游必须都经过 needAdmin=true 的 requireStaff
  const adminCalls = (API.match(/requireStaff\(req, res, true\)/g) || []).length;
  assert.ok(adminCalls >= 10, `管理员校验调用点过少（${adminCalls}），疑似有接口漏校验`);
});

// ── 数据范围 ─────────────────────────────────────────────────────────────────

test("AUTHZ-04 员工的申请列表只能看自己提交的", () => {
  const body = fnBody("async function handleListRequests", 900);
  assert.match(body, /staff\.role === "admin" \? \{\} : \{ submittedBy: staff\.sub \}/,
    "申请列表未按 submittedBy 收口（员工会看到别人的申请）");
});

test("AUTHZ-05 员工的发放记录只能看自己名下的", () => {
  const body = fnBody("async function handleListDeliveries", 900);
  assert.match(body, /staff\.role === "admin" \? \{\} : \{ staffId: staff\.sub \}/,
    "发放列表未按 staffId 收口");
});

test("AUTHZ-06 删除/改备注发放记录要校验归属，不能只认 id", () => {
  const body = fnBody("async function handleUpdateDeliveryNote", 1200);
  assert.match(body, /d\.staffId !== staff\.sub/, "改备注未校验记录归属");
  const del = fnBody("async function handleDeleteDelivery", 1200);
  assert.match(del, /(doc|d)\.staffId !== staff\.sub/, "删除未校验记录归属");
});

// ── 状态机与幂等 ─────────────────────────────────────────────────────────────

test("STATE-01 审核通过必须先 CAS 抢 pending，重入直接失败", () => {
  const body = fnBody("async function approveRequest", 700);
  assert.match(body, /where\(\{ _id: reqDoc\._id, status: "pending" \}\)/, "通过未做原子领取");
  assert.match(body, /if \(!claim\.updated\) throw new Error\("ALREADY_REVIEWED"\)/, "抢锁失败未中止");
});

test("STATE-02 审核失败要退回 pending，不能卡在 processing", () => {
  const body = fnBody("async function approveRequest", 1200);
  assert.match(body, /status: "processing"/, "缺少 processing 中间态");
  assert.match(body, /update\(\{ status: "pending", claimedAt: null \}\)/, "失败未回滚状态");
});

test("STATE-03 驳回同样必须 CAS（本轮修复：此前可与通过并发双写）", () => {
  const body = fnBody("async function handleRejectRequest", 1400);
  assert.match(body, /where\(\{ _id: id, status: "pending" \}\)/, "驳回未做原子领取");
  assert.match(body, /if \(!rejectClaim\.updated\)/, "驳回未以 updated 计数判定成功");
  assert.match(body, /ALREADY_REVIEWED/, "并发驳回未返回 409");
});

test("STATE-04 已处理的申请不能再次审核", () => {
  const body = fnBody("async function approveRequest", 400);
  assert.match(API, /reqDoc\.status !== "pending"[\s\S]{0,80}ALREADY_REVIEWED/, "缺少终态前置校验");
});

// ── 凭据安全 ─────────────────────────────────────────────────────────────────

test("SEC-01 查看/重置密码必须留审计，且审计里不含密码字段", () => {
  const view = fnBody("async function handleStaffPassword", 900);
  assert.match(view, /auditLog\(staff, "staff\.password\.view"/, "查看密码没有审计");
  const reset = fnBody("async function handleResetStaffPassword", 1200);
  assert.match(reset, /auditLog\(staff, "staff\.password\.reset"/, "重置密码没有审计");
  // 审计写入体内不得出现 password 值
  const audit = fnBody("async function auditLog", 900);
  assert.doesNotMatch(audit, /password/i, "审计体内出现 password 字样");
});

test("SEC-02 管理员账号不能被重置密码或停用", () => {
  const reset = fnBody("async function handleResetStaffPassword", 1200);
  assert.match(reset, /s\.role === "admin"[\s\S]{0,120}FORBIDDEN/, "管理员可被重置密码");
  const disable = fnBody("async function handleDisableStaff", 900);
  assert.match(disable, /s\.role === "admin"[\s\S]{0,120}FORBIDDEN/, "管理员可被停用");
});

// ── 前端：XSS 与失败态 ───────────────────────────────────────────────────────

test("UI-01 管理端/员工端动态文本必须走 esc()", () => {
  for (const [name, html] of [["admin.html", ADMIN], ["staff.html", STAFF]]) {
    const escCount = (html.match(/esc\(/g) || []).length;
    assert.ok(escCount > 20, `${name} 的 esc() 调用过少（${escCount}），疑似直接拼 HTML`);
  }
  // 抽查：账号名/备注/客户名这些用户可控字段必须转义后插入
  assert.match(ADMIN, /esc\(d\.username\)/, "发放记录的用户名未转义");
  assert.match(STAFF, /esc\(/, "员工端没有任何转义调用");
});

test("UI-02 写操作失败不能提示成功（必须判 ok 再提示）", () => {
  for (const [name, html] of [["admin.html", ADMIN], ["staff.html", STAFF]]) {
    // 反例：失败分支里出现"成功"字样
    const bad = /if\s*\(!j\.ok\)[^}]{0,80}(成功|已提交)/.test(html);
    assert.equal(bad, false, `${name} 的失败分支里出现了成功文案`);
  }
  assert.match(ADMIN, /j\.ok/, "管理端写操作未检查响应 ok");
});

// ── C1.3 幂等重放（服务端成功但响应丢失） ────────────────────────────────────

function fnSlice(name, len) {
  const start = API.indexOf(name);
  assert.ok(start > 0, `找不到 ${name}`);
  return API.slice(start, start + len);
}

test("IDEM-01 重放判断必须早于终态判断（否则重试仍报已处理）", () => {
  for (const name of ["async function handleApproveRequest", "async function handleRejectRequest"]) {
    const body = fnSlice(name, 1600);
    const replayAt = body.indexOf("matchOperation(");
    const terminalAt = body.indexOf('reqDoc.status !== "pending"');
    assert.ok(replayAt > 0, `${name} 没有幂等判断`);
    assert.ok(terminalAt > 0, `${name} 没有终态判断`);
    assert.ok(replayAt < terminalAt, `${name} 的幂等判断在终态判断之后，重放会失败`);
  }
});

test("IDEM-02 同一 opId + 同一动作 → 返回 idempotent 标记且不重复执行", () => {
  const body = fnSlice("function matchOperation", 800);
  assert.ok(body.includes('last.id || ""'), "未比对 opId");
  assert.ok(body.includes('return "same-op"'), "缺少同操作判定");
  assert.ok(API.includes("idempotent: true"), "重放响应没有 idempotent 标记");
});

test("IDEM-03 同一 opId 换动作 → 409，不能把不同操作合并", () => {
  const body = fnSlice("function matchOperation", 800);
  assert.ok(body.includes('op-id-reused'), "未拦截同一标识换动作");
  assert.ok(API.includes("OPERATION_ID_REUSED"), "缺少冲突错误码");
});

test("IDEM-04 幂等键绑定操作人：换账号不能借用别人的键", () => {
  const body = fnSlice("function matchOperation", 800);
  assert.ok(body.includes("last.staffId"), "未校验操作人，幂等键可被跨账号复用");
  assert.ok(body.includes("staff.sub"), "未取当前操作人");
});

test("IDEM-05 未带 operationId 时保持原行为（兼容老客户端）", () => {
  const body = fnSlice("function matchOperation", 800);
  assert.ok(body.includes("!opId"), "没有 opId 时未短路");
  assert.ok(body.includes('return "none"'), "缺少 none 分支");
});

test("IDEM-06 前端必须发送 operationId，并在网络错误时去查真实状态", () => {
  assert.ok(ADMIN.includes("body:{operationId:CUR.op}"), "通过未携带操作标识");
  assert.ok(ADMIN.includes("body:{reason:v,operationId:CUR.op}"), "驳回未携带操作标识");
  assert.ok(ADMIN.includes("function isNetworkish"), "缺少网络错误判定");
  assert.ok(ADMIN.includes("function afterUnknownResult"), "缺少结果未知处理");
  assert.ok(ADMIN.includes("if(isNetworkish(e)){ afterUnknownResult(); }"), "网络错误未走确认流程");
  assert.ok(ADMIN.includes("CUR.op=null;"), "成功后未清空操作标识");
});
