// ============================================================================
// audit-and-config.test.js —— 10-24 联合审计的整改契约
//
// 覆盖三件事（都是"改回去就会挂"的硬约束）：
//   1. 敏感操作（看/重置密码、停用账号）必须留审计，且审计里**不能出现密码**；
//   2. 发放存档回显初始密码必须有止损开关，且默认仍是回显（不打断现有发放流程）；
//   3. 旧 /api/image 的 472 行死代码不得回流，且必须只剩 503 门禁。
// ============================================================================

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.join(__dirname, "..");
const API = fs.readFileSync(path.join(ROOT, "cloudfunctions/bf-api/index.js"), "utf8");
const SCHEMA = fs.readFileSync(path.join(ROOT, "cloudfunctions/bf-api/settings-schema.js"), "utf8");

test("AUDIT-01 审计集合存在，且写入函数不记录任何密码字段", () => {
  assert.match(API, /audit:\s*"bf_audit_logs"/, "缺少审计集合常量");
  const start = API.indexOf("async function auditLog");
  assert.ok(start > 0, "缺少 auditLog 实现");
  const body = API.slice(start, start + 900);
  assert.doesNotMatch(body, /password/i, "审计写入体里出现了 password 字样（可能记录密码）");
  assert.match(body, /catch/, "审计写失败必须被吞掉，不能影响业务");
});

test("AUDIT-02 五个敏感动作必须留审计", () => {
  const actions = [
    "deliveries.list.reveal",
    "deliveries.list.masked",
    "staff.password.view",
    "staff.password.reset",
    "staff.create",
    "staff.disable",
  ];
  for (const a of actions) {
    assert.ok(API.includes(`"${a}"`), `缺少审计动作 ${a}`);
  }
});

test("AUDIT-03 发放存档回显密码有止损开关，默认回显（不打断现有流程）", () => {
  assert.match(API, /REVEAL_DELIVERY_PASSWORD/, "缺少回显开关");
  assert.match(API, /const reveal = String\(RUNTIME\.REVEAL_DELIVERY_PASSWORD \|\| "1"\) !== "0";/,
    "开关默认值不是 1（会改变现有发放流程）");
  assert.match(API, /password: reveal \? decryptPwd\(d\.passwordCipher\) : ""/,
    "关闭时仍返回明文密码");
  assert.match(API, /passwordMasked: !reveal && !!d\.passwordCipher/, "关闭时缺少 masked 标记");
  // 配置中心必须能改：RUNTIME_SPECS + settings-schema 都要有
  assert.match(API, /REVEAL_DELIVERY_PASSWORD:\s*\{ type: "str"/, "RUNTIME_SPECS 缺少该开关");
  assert.match(SCHEMA, /REVEAL_DELIVERY_PASSWORD/, "settings-schema 缺少该开关（管理台看不到）");
});

test("AUDIT-04 敏感 handler 必须拿到操作人（不能靠 req.__staff 这种不存在的字段）", () => {
  assert.doesNotMatch(API, /req\.__staff/, "仍在使用不存在的 req.__staff");
  for (const fn of ["handleStaffPassword", "handleResetStaffPassword", "handleDisableStaff", "handleCreateStaff"]) {
    assert.match(API, new RegExp(`async function ${fn}\\(req, res, staff`), `${fn} 没有接收操作人参数`);
  }
  assert.match(API, /handleSuspendAccount\(req, res, st, sub\[1\]\)/, "停用账号未把操作人传进去");
});

test("AUDIT-05 旧图片实现不得回流，且 /api/image 只剩门禁", () => {
  assert.doesNotMatch(API, /__legacyHandleImageDisabled/, "旧图片实现回来了");
  assert.doesNotMatch(API, /IMG_DEBOUNCE/, "旧防抖缓存回来了");
  const start = API.indexOf("async function handleImage");
  const body = API.slice(start, start + 1600);
  assert.match(body, /sendError\(res, 503, "PLEASE_UPDATE"\)/, "旧路径没有升级门禁");
  assert.doesNotMatch(body, /fetch\(/, "旧路径里又出现了上游调用");
});
