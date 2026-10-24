// ============================================================================
// 生图混合路由契约（10-24）
//
// 锁住三件事：
//   1. 模型能力表存在，且 Flash/Lite 不会被传 fast 参数
//   2. 路由按 task_kind / quality_tier 决策，能力不支持时明确拒绝
//   3. 记账记录真实使用的模型，而不是默认模型
// ============================================================================

const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.resolve(__dirname, "..");
const IMAGE = fs.readFileSync(path.join(ROOT, "cloudfunctions/bf-image/index.js"), "utf8");
const API = fs.readFileSync(path.join(ROOT, "cloudfunctions/bf-api/index.js"), "utf8");
const SCHEMA = fs.readFileSync(path.join(ROOT, "cloudfunctions/bf-api/settings-schema.js"), "utf8");

test("ROUTE-01 运行时读取三个档位 + 路由模式", () => {
  for (const key of ["IMAGE_MODEL_FAST", "IMAGE_MODEL_PRO", "IMAGE_MODEL_SERIES", "IMAGE_ROUTING_MODE"]) {
    assert.match(IMAGE, new RegExp(`"${key}"`), `RT_KEYS 缺少 ${key}`);
  }
});

test("ROUTE-02 模型能力表覆盖 Pro / Flash / Lite", () => {
  assert.match(IMAGE, /const MODEL_CAPS = \{/);
  assert.match(IMAGE, /doubao-seedream-5-0-pro-260628":\s*\{[^}]*fastPromptMode: true/);
  assert.match(IMAGE, /doubao-seedream-5-0-flash-260915":\s*\{[^}]*fastPromptMode: false/);
  assert.match(IMAGE, /doubao-seedream-5-0-260128":\s*\{[^}]*series: true/);
});

test("ROUTE-03 未知模型走保守默认（不给 fast / 组图 / 图层）", () => {
  assert.match(IMAGE, /function capsOf\(model\)[\s\S]{0,260}fastPromptMode: false[^}]*series: false[^}]*layers: false/,
    "未知模型未按保守能力处理");
});

test("ROUTE-04 fast 参数只在能力允许时下发", () => {
  assert.match(IMAGE, /if \(caps\.fastPromptMode && String\(RT\.IMAGE_FAST_MODE\) !== "0"\)/,
    "optimize_prompt_options 未受能力表约束");
  assert.doesNotMatch(IMAGE, /const mode = String\(RT\.IMAGE_FAST_MODE\) === "0" \? "standard" : "fast";/,
    "仍是旧的全局 fast 开关");
});

test("ROUTE-05 路由按任务与质量档分支，且能力优先", () => {
  const fn = IMAGE.slice(IMAGE.indexOf("function selectImageRoute"));
  const body = fn.slice(0, fn.indexOf("\nlet _rtLoadedAt", 10));
  assert.match(body, /kind === "series"[\s\S]{0,220}series-unsupported/, "组图无模型时未明确拒绝");
  assert.match(body, /kind === "decompose"[\s\S]{0,200}layers/, "图层任务未按能力选择");
  assert.match(body, /tier === "high"[\s\S]{0,80}m\.pro/, "高质量档未路由到 Pro");
  assert.match(body, /mode === "flash_only"[\s\S]{0,80}m\.fast/, "缺少运维强制快速档");
  assert.match(body, /mode === "pro_only"[\s\S]{0,80}m\.pro/, "缺少运维强制高质量档");
});

test("ROUTE-06 能力不支持时前置拦截，不发上游", () => {
  assert.match(IMAGE, /layerDecomposition === true && !caps\.layers[\s\S]{0,200}unsupported: true/);
  assert.match(IMAGE, /image && !caps\.edit[\s\S]{0,200}unsupported: true/);
  assert.match(IMAGE, /unsupported\)[\s\S]{0,300}abortIdem[\s\S]{0,200}422/,
    "不支持的任务未在路由层终止并返回 422");
});

test("ROUTE-07 记账与响应记录真实模型", () => {
  assert.match(IMAGE, /const usedModel = String\(out\.model \|\| RT\.IMAGE_MODEL \|\| ""\)/,
    "未记录实际使用模型");
  assert.match(IMAGE, /finishIdem\(rid, auth\.sub, out\.url, price, usedModel\)/,
    "台账仍写默认模型");
  assert.match(IMAGE, /model: usedModel, route_reason: out\.routeReason/,
    "响应未回传模型与路由原因");
});

test("ROUTE-08 重试沿用首轮模型，避免换模型", () => {
  // 重试块中间隔着一行长 prompt 拼接，放宽到 1200 字符
  assert.match(IMAGE, /重试必须沿用首轮选定[\s\S]{0,1200}model: out\.model/,
    "编辑重试未固定模型");
});

test("ROUTE-09 bf-api 配置项与管理端 schema 同步", () => {
  for (const key of ["IMAGE_MODEL_FAST", "IMAGE_MODEL_SERIES", "IMAGE_ROUTING_MODE"]) {
    assert.match(API, new RegExp(`${key}:\\s*\\{ type: "str"`), `RUNTIME_SPECS 缺少 ${key}`);
    assert.match(SCHEMA, new RegExp(`${key}:\\s*\\{ title:`), `settings-schema 缺少 ${key}`);
  }
});

test("ROUTE-10 旧转发路径的 fast 参数同样受模型约束", () => {
  assert.match(API, /seedream-5-0-pro\|seedream-4-0/,
    "bf-api 旧 /api/image 路径仍是无条件传 fast");
});
