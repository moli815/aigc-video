// ============================================================================
// log-privacy.test.js —— 10-24 P1：日志 PII 打码
//
// 断言三件事：
//   1) 打码函数本身：邮箱/手机号（含分组写法）/身份证/银行卡/JWT/Bearer/sk-密钥/签名 query
//      必须被打码，且**普通数字不能被误伤**（ms/cost/count 仍是 number）。
//   2) 出口收口：bf-api 与 bf-image 里不再有裸 console.log(JSON.stringify(...))，
//      上游返回体原文不再进日志（只留长度 + 哈希）。
//   3) 三份 log-safe.js 必须字节一致 —— 云函数按目录独立打包，拷贝漏改是最容易出的错。
// ============================================================================

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");

const ROOT = path.join(__dirname, "..");
const CF = path.join(ROOT, "cloudfunctions");
const SAFE = require(path.join(CF, "bf-api/log-safe.js"));

const API = fs.readFileSync(path.join(CF, "bf-api/index.js"), "utf8");
const IMAGE = fs.readFileSync(path.join(CF, "bf-image/index.js"), "utf8");
const JOBS = fs.readFileSync(path.join(CF, "bf-jobs/index.js"), "utf8");

// ─────────────────────────────────────────────────────────────
// 1. 值形态打码
// ─────────────────────────────────────────────────────────────

test("PRIV-01 邮箱保留前 2 位与域名，可人工核对但不泄露完整地址", () => {
  assert.equal(SAFE.maskEmail("wangzong836@gmail.com"), "wa***@gmail.com");
  assert.equal(SAFE.maskEmail("a@b.com"), "a***@b.com");
  assert.equal(SAFE.maskText("登录失败 wangzong836@gmail.com"), "登录失败 wa***@gmail.com");
});

test("PRIV-02 手机号三种写法都要打码（纯数字 / 连字符 / +86 空格）", () => {
  assert.equal(SAFE.maskPhone("13812345678"), "138****5678");
  assert.equal(SAFE.maskPhone("138-1234-5678"), "138****5678");
  assert.equal(SAFE.maskPhone("+86 138 1234 5678"), "138****5678");
  const out = SAFE.maskText("联系 13812345678 或 139-0000-1111");
  assert.doesNotMatch(out, /13812345678|139-0000-1111/, "手机号原样残留");
  assert.match(out, /138\*\*\*\*5678/);
});

test("PRIV-03 身份证与银行卡脱敏，中间位数不可还原", () => {
  assert.equal(SAFE.maskDigits("320102199001011234"), "320***********1234");
  const id = SAFE.maskText("身份证 320102199001011234");
  assert.doesNotMatch(id, /19900101/, "出生日期段泄露");
  const bank = SAFE.maskText("卡号 6222021234567890123");
  assert.doesNotMatch(bank, /1234567890/, "卡号中段泄露");
});

test("PRIV-04 令牌类一律整段抹掉（JWT / Bearer / sk- 密钥 / URL 内嵌凭据）", () => {
  const jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghijklmnop";
  assert.doesNotMatch(SAFE.maskText("token " + jwt), /eyJhbGciOiJIUzI1NiJ9/);
  assert.equal(SAFE.maskText("Authorization: Bearer abcdefghijklmnop12345"), "Authorization: Bearer «redacted»");
  assert.doesNotMatch(SAFE.maskText("key sk-abcdefghijklmnopqrstuv"), /abcdefghijklmnopqrstuv/);
  assert.doesNotMatch(SAFE.maskText("https://user:pass123@host/x"), /pass123/);
});

test("PRIV-05 签名类 query 参数不落日志（临时票据可被他人复用）", () => {
  const out = SAFE.maskText("https://b.cos.ap-shanghai.myqcloud.com/a.png?X-Tos-Signature=deadbeef&x=1");
  assert.doesNotMatch(out, /deadbeef/, "签名值泄露");
  assert.match(out, /X-Tos-Signature=/, "签名键名应保留，便于排障");
});

test("PRIV-06 长文本截断并标注原长；换行折叠成单行（防伪造多行日志）", () => {
  const long = "x".repeat(500);
  const out = SAFE.maskText(long);
  assert.ok(out.length < 260, "未截断");
  assert.match(out, /…\(\+260\)/);
  assert.equal(SAFE.maskText("a\nb\tc"), "a b c");
});

// ─────────────────────────────────────────────────────────────
// 2. 结构化对象脱敏
// ─────────────────────────────────────────────────────────────

test("PRIV-07 accountId 转稳定短哈希：可关联、不可反推、跨实例一致", () => {
  const a1 = SAFE.scrub({ sub: "acc_7f3a91c0d2e4" });
  const a2 = SAFE.scrub({ sub: "acc_7f3a91c0d2e4" });
  assert.equal(a1.sub, a2.sub, "同一账号两次运行结果不一致");
  assert.match(a1.sub, /^acct:[a-f0-9]{8}$/, "不是稳定短标签");
  assert.doesNotMatch(JSON.stringify(a1), /7f3a91c0d2e4/, "原 ID 泄露");
  // 不同账号必须区分开（否则排障时全部串成一个人）
  assert.notEqual(SAFE.scrub({ sub: "acc_A" }).sub, SAFE.scrub({ sub: "acc_B" }).sub);
});

test("PRIV-08 用户原文只留长度与哈希，正文不进日志", () => {
  const prompt = "帮我做一张非遗海报，联系电话 13812345678";
  const out = SAFE.scrub({ prompt });
  assert.equal(typeof out.prompt, "object");
  assert.equal(out.prompt.len, prompt.length);
  assert.match(out.prompt.sha, /^[a-f0-9]{8}$/);
  assert.doesNotMatch(JSON.stringify(out), /非遗|13812345678/);
});

test("PRIV-09 上游原文直接丢弃（只留长度），密钥键整体替换", () => {
  const body = '{"error":"too many"}';
  const out = SAFE.scrub({ body, raw: "abcdef", password: "hunter2", IMAGE_API_KEY: "sk-xx" });
  assert.equal(out.body, "«omitted:" + body.length + "»", "上游 body 未被丢弃");
  assert.equal(out.password, "«redacted»");
  assert.equal(out.IMAGE_API_KEY, "«redacted»");
  assert.doesNotMatch(JSON.stringify(out), /hunter2|too many/);
});

test("PRIV-10 URL 保留 host+path、抹掉 query（签名/ticket 都在 query）", () => {
  const out = SAFE.scrub({ url: "https://x.com/a/b.png?sign=abc&exp=1" });
  assert.equal(out.url, "https://x.com/a/b.png?«omitted»");
});

test("PRIV-11 数字字段必须保持 number（否则日志聚合/告警规则全废）", () => {
  const out = SAFE.scrub({ ms: 12, cost: 0.3, code: 500, count: 1750000000000 });
  assert.equal(typeof out.ms, "number");
  assert.equal(typeof out.cost, "number");
  assert.equal(out.count, 1750000000000);
  // 但数字形态的手机号仍要打码
  assert.equal(SAFE.scrub({ phone: 13812345678 }).phone, "138****5678");
});

test("PRIV-12 白名单键原样保留（tag/stage/requestId 是排障检索入口）", () => {
  const out = SAFE.scrub({ tag: "series_started", stage: "quota", requestId: "req_abc123", fn: "bf-image" });
  assert.equal(out.tag, "series_started");
  assert.equal(out.requestId, "req_abc123");
});

test("PRIV-13 深层嵌套与循环保护：不抛异常、有深度上限", () => {
  let deep = { v: "13812345678" };
  for (let i = 0; i < 8; i++) deep = { child: deep };
  const out = SAFE.scrub(deep);
  assert.doesNotMatch(JSON.stringify(out), /max-depth»\s*:\s*null/, "异常结构");
  assert.match(JSON.stringify(out), /max-depth/);
  const cyclic = { a: 1 };
  cyclic.self = cyclic;
  assert.doesNotThrow(() => SAFE.scrub(cyclic));
});

// ─────────────────────────────────────────────────────────────
// 3. 出口收口（源码契约）
// ─────────────────────────────────────────────────────────────

test("PRIV-14 bf-api 不再有裸 console.log(JSON.stringify(...))，全部走 logSafe", () => {
  assert.doesNotMatch(API, /console\.log\(JSON\.stringify/, "仍有裸日志出口");
  assert.doesNotMatch(API, /console\.error\(/, "仍有裸 console.error 出口");
  assert.match(API, /require\("\.\/log-safe"\)/, "未引入 log-safe");
});

test("PRIV-15 bf-image 的 logStage 走脱敏；错误出口也走 logSafe", () => {
  assert.match(IMAGE, /function logStage\(stage, extra\)[\s\S]{0,200}logSafe\(/, "logStage 未脱敏");
  assert.match(IMAGE, /tag: "image_error"[\s\S]{0,260}logSafe|logSafe\(\{[\s\S]{0,200}tag: "image_error"/, "image_error 未脱敏");
});

test("PRIV-16 向量化接口失败时不再打上游原文（只留长度 + 哈希）", () => {
  assert.doesNotMatch(API, /body=\$\{errBody/, "仍在打印上游 body");
  assert.match(API, /tag: "embed_http_error"[\s\S]{0,240}bodyLen/, "缺少长度字段");
  assert.match(API, /bodySha/, "缺少内容哈希（无法与上游工单比对）");
});

test("PRIV-17 访问日志只留 path，且 path 也过打码", () => {
  assert.match(API, /p: maskText\(String\(req\.url \|\| ""\)\.split\("\?"\)\[0\], 160\)/, "访问日志 path 未打码");
});

test("PRIV-18 去重盘点响应对账号脱敏（管理台截图/工单外传也不泄露）", () => {
  assert.match(API, /account: tagId\(parts\[0\], "acct"\)/, "dedupe 盘点回显了明文账号 ID");
});

test("PRIV-19 三份 log-safe.js 必须字节一致（打包是按目录独立的）", () => {
  const files = ["bf-api/log-safe.js", "bf-image/log-safe.js", "bf-jobs/log-safe.js"];
  const hashes = files.map((f) => crypto.createHash("sha256")
    .update(fs.readFileSync(path.join(CF, f))).digest("hex"));
  assert.equal(new Set(hashes).size, 1, "log-safe.js 三份副本已漂移，必须同步修改");
});
