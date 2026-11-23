"use strict";
/**
 * S0-6 · 「提示词 ↔ 工具集」离线对账（防复发，纯静态/纯内存，不调用模型）
 *
 * 近两周反复出现同一类事故：提示词命令模型调用一个根本没下发到 tools[] 的工具
 * （10-24 image_series availability:false；10-28 both schema 骗 Agent），
 * 或提示词点名一个早已被排除的幽灵工具（generate_image）。此前每次都靠用户先发现。
 *
 * 本测试从 Swift 源码反推「本轮实际开放的工具集合」，再扫描所有会注入系统提示词的
 * 文本，断言提示词提到的工具名必须真的可调用。客户端 S1 待出包项如实登记、不假装通过。
 */
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.join(__dirname, "..");
const read = p => fs.readFileSync(path.join(ROOT, p), "utf8");
const { validateValue, SECTION_OF } = require("../cloudfunctions/bf-api/settings-schema");
const { arbitrateDelivery, enabledFor, hasRigidWrapper, parsePolicy, MARKER, ARBITRATION_BLOCK } =
  require("../cloudfunctions/bf-api/expert-delivery-arbitration");

const API = read("cloudfunctions/bf-api/index.js");
const REGISTRY = read("BossAI/Services/ToolRegistry.swift");
const SCHEMA = read("BossAI/Services/ToolManifest+Schema.swift");

/** 从 ToolRegistry 的 id: "..." 块反推工具 id，并识别恒关闭 / 被排除的项。 */
function toolInventory() {
  const all = new Set();
  const disabled = new Set();
  for (const chunk of REGISTRY.split(/(?=id:\s*")/)) {
    const m = chunk.match(/^id:\s*"([a-z0-9_]+)"/);
    if (!m) continue;
    all.add(m[1]);
    if (/availability:\s*\{\s*false\s*\}/.test(chunk.slice(0, 700))) disabled.add(m[1]);
  }
  const excluded = new Set([...SCHEMA.matchAll(/plugin\.id\s*!==?\s*"([a-z0-9_]+)"/g)].map(m => m[1]));
  return { all, disabled, excluded, notDelivered: new Set([...disabled, ...excluded]) };
}
const INV = toolInventory();

/** 服务端会注入系统提示词的文本：CHAT_RULES、META_RULE 与 guidance / 审查模块。 */
function serverPromptText() {
  const crStart = API.indexOf("CHAT_RULES:         { type:");
  const crEnd = API.indexOf("// P0-38 对话档位", crStart);
  const chatRules = API.slice(crStart, crEnd > crStart ? crEnd : crStart + 14000);
  const metaStart = API.indexOf("const META_RULE_BUILTIN = `");
  const metaEnd = API.indexOf("`;", metaStart);
  const meta = metaStart > 0 ? API.slice(metaStart, metaEnd) : "";
  const files = [
    "cloudfunctions/bf-api/assistant-guidance.js",
    "cloudfunctions/bf-api/assistant-style-policy.js",
    "cloudfunctions/bf-api/response-behavior.js",
    "cloudfunctions/bf-api/commercial-copy-review.js",
    "cloudfunctions/bf-api/commercial-chat-review.js",
    "cloudfunctions/bf-api/image-tool-schema.js",
    "cloudfunctions/bf-api/image-single-reference-guidance.js",
    "cloudfunctions/bf-api/image-series-reference-guidance.js",
    "cloudfunctions/bf-api/expert-delivery-arbitration.js",
  ].filter(p => fs.existsSync(path.join(ROOT, p))).map(read);
  return { text: [chatRules, meta, ...files].join("\n"), chatRules, meta };
}
const PROMPT = serverPromptText();

/** 挑出「看起来是工具 id」的 token，只与 ToolRegistry 的 id 求交集，避免参数名误报。 */
function mentionedTools(text) {
  return [...new Set([...text.matchAll(/\b[a-z][a-z0-9]*(?:_[a-z0-9]+)+\b/g)].map(m => m[0]))]
    .filter(t => INV.all.has(t));
}

test("ALIGN-01 工具清单来自 Swift 源码，且能识别出恒关闭/被排除的工具", () => {
  assert.ok(INV.all.size >= 10, "工具太少，源码提取可能失效：" + INV.all.size);
  assert.ok(INV.disabled.has("image_decompose"), "未识别出 image_decompose availability:false");
  assert.ok(INV.excluded.has("generate_image"), "未识别出 generate_image 被 schema 排除");
  assert.ok(INV.all.has("image_generate") && INV.all.has("image_edit") && INV.all.has("image_series"));
});

test("ALIGN-02 服务端提示词不得提到任何未下发的工具（S0-1 回归门禁）", () => {
  const ghosts = mentionedTools(PROMPT.text).filter(t => INV.notDelivered.has(t));
  assert.deepEqual(ghosts, [], "服务端提示词仍在命令模型调用不可用的工具：" + ghosts.join(", "));
  assert.ok(PROMPT.chatRules.length > 3000, "CHAT_RULES 切片失败，测试会假通过");
  assert.ok(PROMPT.meta.includes("数据真实性铁律"), "META_RULE 切片失败，测试会假通过");
});

test("ALIGN-03 图像来源提示词与 10-28 已修复的多图 schema 语义一致", () => {
  assert.doesNotMatch(PROMPT.chatRules, /双图融合才用\s*both/, "CHAT_RULES 仍在教模型用已废弃的 both 语义");
  assert.match(PROMPT.chatRules, /source_indexes/, "未说明两张附件互合成应使用 source_indexes");
  assert.match(PROMPT.chatRules, /不要使用\s*both/, "未明确禁止 both");
});

test("ALIGN-04 客户端幽灵工具如实锁定在 S1 清单内，不允许新增扩散", () => {
  // 这些文件在已发布 IPA 内，服务端改不到，必须等下次统一出包（S1）。
  // 测试不把它们当通过：遍历整个 BossAI 目录，若幽灵引用扩散到新文件即失败。
  const known = new Set([
    "BossAI/Models/Expert.swift",
    "BossAI/Services/ToolManifest+Schema.swift",
    "BossAI/Services/ToolRegistry.swift",
    "BossAI/Services/ChatService.swift",
    "BossAI/Services/EffectiveToolPolicy.swift",
    "BossAI/Services/ImageToolArguments.swift",
    "BossAI/Services/HostedAccount.swift",
    // ALIGN-04 首次运行新发现：旧能力名残留在注释里，已登记到 S1 台账。
    "BossAI/Services/ImageService.swift",
    "BossAI/ExpertCore/ExpertCapabilities.swift",
    "BossAI/ExpertCore/Resources/ExpertSkills.json",
    "BossAI/ViewModels/ChatViewModel.swift",
    "BossAI/ViewModels/ChatViewModel+Streaming.swift",
    "BossAI/ViewModels/ChatViewModel+Sending.swift",
  ]);
  const acc = [];
  (function walk(dir) {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      const abs = path.join(dir, e.name);
      if (e.isDirectory()) { if (!/node_modules|__pycache__/.test(e.name)) walk(abs); }
      else if (/\.(swift|json)$/.test(e.name)) acc.push(path.relative(ROOT, abs).replace(/\\/g, "/"));
    }
  })(path.join(ROOT, "BossAI"));
  const found = acc.filter(p => /image_decompose|generate_image/.test(read(p)));
  const unknown = found.filter(p => !known.has(p));
  assert.deepEqual(unknown, [], "幽灵工具引用扩散到未登记文件（S1 台账需更新）：" + unknown.join(", "));
  assert.ok(found.length > 0, "若幽灵工具已随出包修复，请同步更新台账 S1 与本测试预期");
});

test("ALIGN-05 /me 真正下发能力开关，白标读写两侧都有档位门控（S0-3/S0-4）", () => {
  assert.match(API, /capabilityExtra:\s*String\(RUNTIME\.CAPABILITY_EXTRA/, "未下发 capabilityExtra");
  assert.match(API, /capabilityOverrides:\s*\(\(\)\s*=>/, "未下发 capabilityOverrides 对象");
  assert.match(API, /appName:\s*tierDefOf\(acc\)\.features\.whiteLabel/, "appName 缺少 Ultra 门控");
  assert.match(API, /brandName:\s*tierDef\.features\.whiteLabel/, "建号写入 brandName 缺少 Ultra 门控");
});

test("ALIGN-06 交付仲裁默认关闭、已接入 chat 注入链", () => {
  assert.match(API, /CHAT_DELIVERY_ARBITRATION:\s*\{[^}]*enabled":false/, "开关默认值不是关闭");
  assert.match(API, /arbitrateDelivery\(messages, RUNTIME\.CHAT_DELIVERY_ARBITRATION, auth\.sub\)/, "未接入 handleChat");
  assert.equal(enabledFor("{\"enabled\":false,\"audience\":\"all\"}", "u1"), false);
  assert.equal(enabledFor("{\"enabled\":true,\"audience\":\"accounts\",\"accountIds\":[\"u1\"]}", "u1"), true);
  assert.equal(enabledFor("{\"enabled\":true,\"audience\":\"accounts\",\"accountIds\":[\"u1\"]}", "u2"), false);
  assert.equal(enabledFor("not-json", "u1"), false, "非法配置必须 fail-closed");
  assert.equal(parsePolicy(null).enabled, false);
});

test("ALIGN-07 仲裁只在启用时追加到最后一条 system，幂等且不改入参", () => {
  const msgs = [
    { role: "system", content: "【必须遵循的工作流】\n1. 三个角度" },
    { role: "user", content: "写一段纯口播" },
    { role: "system", content: "【能力表达铁律】" },
  ];
  const frozen = JSON.stringify(msgs);
  assert.strictEqual(arbitrateDelivery(msgs, "{\"enabled\":false}", "u1"), msgs, "关闭时必须原样返回");
  assert.equal(hasRigidWrapper(msgs), true, "未识别出旧包刚性包装");

  const out = arbitrateDelivery(msgs, "{\"enabled\":true}", "u1");
  assert.notStrictEqual(out, msgs);
  assert.equal(out.length, msgs.length, "不应新增消息条数");
  assert.ok(out[2].content.includes(MARKER), "仲裁应追加到最后一条 system");
  assert.ok(!out[0].content.includes(MARKER), "不应破坏首条 system（前缀缓存）");
  assert.equal(JSON.stringify(msgs), frozen, "不得修改入参");
  assert.strictEqual(arbitrateDelivery(out, "{\"enabled\":true}", "u1"), out, "必须幂等");
});

test("ALIGN-07b 没有 system 消息时也能安全追加", () => {
  const out = arbitrateDelivery([{ role: "user", content: "hi" }], { enabled: true }, "u1");
  assert.equal(out.length, 2);
  assert.ok(out[0].content.includes(MARKER));
});

test("ALIGN-08 三个新增配置键都有分区、字段校验与 fail-closed 默认值", () => {
  const jsonSpec = { type: "json", label: "测试" };
  const strSpec = { type: "str", label: "测试" };
  assert.equal(validateValue("CHAT_DELIVERY_ARBITRATION", "{\"enabled\":false}", jsonSpec).ok, true);
  assert.equal(validateValue("CHAT_DELIVERY_ARBITRATION", "{\"enabled\":true,\"evil\":1}", jsonSpec).ok, false);
  assert.equal(validateValue("CHAT_DELIVERY_ARBITRATION", "{\"enabled\":true,\"accountIds\":[1]}", jsonSpec).ok, false);
  assert.equal(validateValue("CAPABILITY_OVERRIDES", "{}", jsonSpec).ok, true);
  assert.equal(validateValue("CAPABILITY_OVERRIDES", "{\"image_series\":{\"enabled\":false,\"limits\":[\"a\"]}}", jsonSpec).ok, true);
  assert.equal(validateValue("CAPABILITY_OVERRIDES", "{\"bad id\":{\"enabled\":true}}", jsonSpec).ok, false);
  assert.equal(validateValue("CAPABILITY_OVERRIDES", "{\"x\":{\"run\":\"rm -rf /\"}}", jsonSpec).ok, false);
  assert.equal(validateValue("CAPABILITY_EXTRA", "补充说明", strSpec).ok, true);
  assert.equal(validateValue("CAPABILITY_EXTRA", "x".repeat(3000), strSpec).ok, false);
  for (const key of ["CHAT_DELIVERY_ARBITRATION", "CAPABILITY_OVERRIDES", "CAPABILITY_EXTRA"]) {
    assert.ok(Object.values(SECTION_OF).flat().includes(key), key + " 没有配置分区");
  }
});

test("ALIGN-09 仲裁规则不覆盖工具调用与真实性铁律", () => {
  assert.match(ARBITRATION_BLOCK, /不改变工具调用规则/);
  assert.match(ARBITRATION_BLOCK, /不得补写/);
  assert.match(ARBITRATION_BLOCK, /最高优先级/);
});
