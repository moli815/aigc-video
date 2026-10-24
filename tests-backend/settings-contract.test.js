/**
 * 配置中心契约测试（node --test）
 *
 * 覆盖三件事：
 *  1. 每个 RUNTIME_SPECS 键都有明确分区，不存在"谁也不知道在哪配"的孤儿；
 *  2. 字段级校验真正按类型工作（范围/枚举/开关/长文本/密钥），不是统一 0~100000 + 120 字；
 *  3. 生效来源能区分数据库覆盖、环境变量与内置默认。
 */
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { SECTIONS, SECTION_OF, describeSettings, validateValue, sourceOf } = require("../cloudfunctions/bf-api/settings-schema");

const SPECS = {
  IMAGE_QUALITY: { type: "num", label: "图片压缩质量", def: () => 0.78 },
  IMAGE_FAST_MODE: { type: "str", label: "生图提速模式", def: () => "1" },
  CHAT_PROVIDER: { type: "str", label: "对话服务商", def: () => "qwen" },
  APP_IMAGE_RETRY: { type: "num", label: "生图重试", def: () => 1 },
  META_RULE: { type: "str", label: "回答规则", def: () => "BUILTIN" },
  CHAT_API_KEY: { type: "secret", label: "对话 Key", def: () => "" },
};

test("每个配置分区 id 唯一，且都有标题与说明", () => {
  const ids = SECTIONS.map((s) => s.id);
  assert.equal(new Set(ids).size, ids.length);
  for (const s of SECTIONS) {
    assert.ok(s.title && s.title.length > 1, `${s.id} 缺少标题`);
    assert.ok(s.desc && s.desc.length > 6, `${s.id} 缺少说明`);
  }
});

test("settings-schema 覆盖 bf-api 中全部 RUNTIME_SPECS 键", () => {
  const src = fs.readFileSync(path.join(__dirname, "../cloudfunctions/bf-api/index.js"), "utf8");
  const start = src.indexOf("RUNTIME_SPECS");
  const block = src.slice(start, start + 40000);
  const keys = [...new Set([...block.matchAll(/^\s{2}([A-Z][A-Z0-9_]+):\s*\{/gm)].map((m) => m[1]))];
  assert.ok(keys.length > 60, `解析到的配置键过少：${keys.length}`);
  const assigned = new Set(Object.values(SECTION_OF).flat());
  const missing = keys.filter((k) => !assigned.has(k));
  assert.deepEqual(missing, [], `以下配置没有分区：${missing.join(", ")}`);
});

test("CHAT_API_KEY 只属于凭证分区，不会重复出现在服务商分组", () => {
  const hits = SECTIONS.filter((s) => (SECTION_OF[s.id] || []).includes("CHAT_API_KEY"));
  assert.equal(hits.length, 1);
  assert.equal(hits[0].id, "storage_credentials");
});

test("数值按字段范围校验，不再统一 0~100000", () => {
  const spec = SPECS.IMAGE_QUALITY;
  assert.equal(validateValue("IMAGE_QUALITY", "0.5", spec).ok, true);
  const bad = validateValue("IMAGE_QUALITY", "1.5", spec);
  assert.equal(bad.ok, false);
  assert.match(bad.reason, /0\.1~1/);

  const retry = validateValue("APP_IMAGE_RETRY", "9", SPECS.APP_IMAGE_RETRY);
  assert.equal(retry.ok, false, "重试次数必须受 0~5 限制");
});

test("开关只接受 0/1/true/false，并归一化为 1/0", () => {
  assert.deepEqual(validateValue("IMAGE_FAST_MODE", "true", SPECS.IMAGE_FAST_MODE), { ok: true, value: "1" });
  assert.deepEqual(validateValue("IMAGE_FAST_MODE", "0", SPECS.IMAGE_FAST_MODE), { ok: true, value: "0" });
  assert.equal(validateValue("IMAGE_FAST_MODE", "开启", SPECS.IMAGE_FAST_MODE).ok, false);
});

test("枚举拒绝未知值", () => {
  assert.equal(validateValue("CHAT_PROVIDER", "qwen", SPECS.CHAT_PROVIDER).ok, true);
  const bad = validateValue("CHAT_PROVIDER", "some-vendor", SPECS.CHAT_PROVIDER);
  assert.equal(bad.ok, false);
  assert.match(bad.reason, /必须是/);
});

test("长文本规则可以超过 120 字（旧规则会误拒）", () => {
  const long = "规则".repeat(200); // 400 字
  const r = validateValue("META_RULE", long, SPECS.META_RULE);
  assert.equal(r.ok, true);
  assert.equal(r.value.length, long.length);
});

test("密钥留空或掩码值一律视为未修改", () => {
  assert.equal(validateValue("CHAT_API_KEY", "", SPECS.CHAT_API_KEY).skip, true);
  assert.equal(validateValue("CHAT_API_KEY", "abcd****wxyz", SPECS.CHAT_API_KEY).skip, true);
  assert.equal(validateValue("CHAT_API_KEY", "short", SPECS.CHAT_API_KEY).ok, false);
  assert.equal(validateValue("CHAT_API_KEY", "sk-1234567890abcdef", SPECS.CHAT_API_KEY).ok, true);
});

test("来源优先级：数据库 > 环境变量 > 内置默认", () => {
  const key = "BOSS_TEST_SOURCE_KEY";
  delete process.env[key];
  assert.equal(sourceOf(key, {}), "builtin");
  process.env[key] = "from-env";
  assert.equal(sourceOf(key, {}), "environment");
  assert.equal(sourceOf(key, { [key]: "from-db" }), "database");
  delete process.env[key];
});

test("describeSettings 不返回密钥明文，只给掩码与已配置状态", () => {
  const runtime = { CHAT_API_KEY: "sk-abcdefghijklmnopqrstuvwxyz" };
  const list = describeSettings(SPECS, runtime, {});
  const secret = list.find((s) => s.key === "CHAT_API_KEY");
  assert.equal(secret.widget, "password");
  assert.equal(secret.secret, true);
  assert.equal(secret.configured, true);
  assert.ok(!JSON.stringify(list).includes("abcdefghijklmnopqrstuvwxyz"), "响应中不能出现完整密钥");
  assert.match(secret.value, /^sk-a\*\*\*\*/);
});
