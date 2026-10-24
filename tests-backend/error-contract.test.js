// ============================================================================
// 全局错误兜底契约（10-24）
//
// 锁住三件最容易退化的事：
//   1. 用户可见文案里不能出现内部错误码 / HTTP 状态 / 供应商原文 / 堆栈 / 路径；
//   2. error 字段必须保持字符串（旧 App 用 `obj["error"] as? String` 判会话失效）；
//   3. 未知错误必须落到安全兜底，不能把原始 code 原样透出。
// ============================================================================

const test = require("node:test");
const assert = require("node:assert");
const path = require("node:path");
const fs = require("node:fs");

const { CATALOG, publicError, sanitizePublicMessage } =
  require("../cloudfunctions/bf-api/error-catalog");

const FORBIDDEN = /HTTP|\b[45]\d{2}\b|ECONN|ETIMEDOUT|ENOTFOUND|stack|undefined|NaN|\.js\b|\.swift\b/;

test("ERR-01 已知错误码返回自然语言与受控动作", () => {
  const cases = [
    ["UNAUTHORIZED", ["relogin"]],
    ["ACCOUNT_SUSPENDED", ["contact_support"]],
    ["MEMBERSHIP_EXPIRED", ["renew"]],
    ["QUOTA_EXCEEDED", ["view_quota"]],
    ["UPSTREAM_TIMEOUT", ["retry", "edit_request"]],
    ["TASK_UNSUPPORTED", ["single_only", "edit_request", "cancel"]],
  ];
  for (const [code, actions] of cases) {
    const p = publicError(code, { requestId: "req_test" });
    assert.strictEqual(p.ok, false);
    assert.strictEqual(p.requestId, "req_test");
    assert.ok(p.message.length > 8, `${code} 文案过短`);
    assert.doesNotMatch(p.message, FORBIDDEN, `${code} 文案含技术痕迹：${p.message}`);
    assert.deepStrictEqual(p.actions, actions, `${code} 动作不匹配`);
  }
});

test("ERR-02 用户可见文案不含任何内部错误码", () => {
  for (const [code, entry] of Object.entries(CATALOG)) {
    assert.doesNotMatch(entry.message, FORBIDDEN, `${code} 文案含技术痕迹：${entry.message}`);
    // 文案里不该出现形如 SERIES_UNSUPPORTED 的机器码
    assert.doesNotMatch(entry.message, /\b[A-Z][A-Z0-9_]{3,}\b/, `${code} 文案含机器码：${entry.message}`);
    // 也不该出现连字符形式的内部原因
    assert.doesNotMatch(entry.message, /[a-z]+-unsupported/i, `${code} 文案含内部原因`);
  }
});

test("ERR-03 未知错误码落到 INTERNAL，不暴露原始标识", () => {
  const p = publicError("SOME_WEIRD_INTERNAL_CODE", { requestId: "req_x" });
  assert.strictEqual(p.error, "INTERNAL", "未知码应归一为 INTERNAL");
  assert.strictEqual(p.errorDetail.code, "INTERNAL");
  assert.doesNotMatch(p.message, /SOME_WEIRD/);
});

test("ERR-04 error 字段保持字符串（旧 App 会话失效判断依赖它）", () => {
  const p = publicError("SESSION_REPLACED", { requestId: "req_y" });
  assert.strictEqual(typeof p.error, "string", "error 必须是字符串，不能改成对象");
  assert.strictEqual(p.error, "SESSION_REPLACED");
  assert.strictEqual(typeof p.errorDetail, "object");
  assert.strictEqual(p.errorDetail.category, "auth");
});

test("ERR-05 调用方文案含技术痕迹时被丢弃，改用目录文案", () => {
  const dirty = [
    "HTTP 500 internal error",
    "ECONNRESET",
    "series-unsupported",
    "INTERNAL_ERROR",
    "at Handler (/var/user/index.js:12)",
    "/var/user/cloudfunctions/bf-image/index.js",
    "undefined",
  ];
  for (const d of dirty) {
    assert.strictEqual(sanitizePublicMessage(d), "", `未拦截：${d}`);
  }
  // 正常业务文案要保留
  assert.strictEqual(sanitizePublicMessage("请填写客户称呼"), "请填写客户称呼");
});

test("ERR-06 组图场景：不出现 series-unsupported，给出可执行选项", () => {
  // 模拟 bf-image 现在的实际返回
  const p = publicError("TASK_UNSUPPORTED", { requestId: "req_z", stage: "image_route" });
  assert.doesNotMatch(p.message, /series|unsupported|422/i, `组图文案泄露内部原因：${p.message}`);
  assert.ok(p.actions.includes("single_only"), "应提供「先生成一张」选项");
  assert.ok(p.actions.includes("cancel"));
  assert.strictEqual(p.errorDetail.stage, "image_route");
});

test("ERR-07 两个云函数的错误目录保持一致", () => {
  const a = require("../cloudfunctions/bf-api/error-catalog");
  const b = require("../cloudfunctions/bf-image/error-catalog");
  const ka = Object.keys(a.CATALOG).sort();
  const kb = Object.keys(b.CATALOG).sort();
  assert.deepStrictEqual(ka, kb, "bf-api 与 bf-image 的错误码集合已漂移");
  for (const k of ka) {
    assert.strictEqual(a.CATALOG[k].message, b.CATALOG[k].message, `${k} 文案不一致`);
    assert.deepStrictEqual(a.CATALOG[k].actions, b.CATALOG[k].actions, `${k} 动作不一致`);
  }
});

test("ERR-08 每个错误都有分类与可重试标记", () => {
  const VALID = new Set(["input", "auth", "capability", "billing", "upstream_timeout",
    "upstream_busy", "upstream_error", "storage", "cancelled", "internal"]);
  for (const [code, e] of Object.entries(CATALOG)) {
    assert.ok(VALID.has(e.category), `${code} 分类非法：${e.category}`);
    assert.strictEqual(typeof e.retryable, "boolean", `${code} 缺少 retryable`);
  }
});
