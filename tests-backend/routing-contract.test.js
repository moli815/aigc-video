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
  assert.match(IMAGE, /if \(caps\.fastPromptMode\)/,
    "optimize_prompt_options 未受能力表约束");
  assert.doesNotMatch(IMAGE, /const mode = String\(RT\.IMAGE_FAST_MODE\) === "0" \? "standard" : "fast";/,
    "仍是旧的全局 fast 开关");
  assert.match(IMAGE, /providerPromptOptions\(selectedModel, RT\.IMAGE_ROUTING_MODE, RT\.IMAGE_FAST_MODE\)/,
    "Pro 调试模式未使用统一的标准质量策略");
});

test("ROUTE-05 路由按任务与质量档分支，且能力优先", () => {
  const fn = IMAGE.slice(IMAGE.indexOf("function selectImageRoute"));
  const body = fn.slice(0, fn.indexOf("\nlet _rtLoadedAt", 10));
  assert.match(body, /kind === "series"[\s\S]{0,220}series-unsupported/, "组图无模型时未明确拒绝");
  assert.match(body, /kind === "decompose"[\s\S]{0,200}layers/, "图层任务未按能力选择");
  assert.match(body, /decision\.tier === "high"[\s\S]{0,80}m\.pro/, "服务端策略高质量档未路由到 Pro");
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

test("ROUTE-08 图片相似度只用于诊断，不自动重绘或重复扣费", () => {
  assert.match(IMAGE, /decision: "diagnostic_only"/,
    "相似度信号必须标记为诊断用途");
  assert.doesNotMatch(IMAGE, /edit_over_redraw_retry/,
    "全图像素差异不能触发第二次模型调用");
  assert.match(IMAGE, /const retried = false;/,
    "兼容响应里的 retried 字段应明确表达本链路不做隐式重试");
});

test("ROUTE-09 bf-api 配置项与管理端 schema 同步", () => {
  for (const key of ["IMAGE_MODEL_FAST", "IMAGE_MODEL_SERIES", "IMAGE_ROUTING_MODE"]) {
    assert.match(API, new RegExp(`${key}:\\s*\\{ type: "str"`), `RUNTIME_SPECS 缺少 ${key}`);
    assert.match(SCHEMA, new RegExp(`${key}:\\s*\\{ title:`), `settings-schema 缺少 ${key}`);
  }
});

test("ROUTE-10 旧 /api/image 已彻底停用：只剩 503 门禁，不留旧转发实现", () => {
  // 10-24：审计指出 `__legacyHandleImageDisabled` 是 472 行死代码，被误启用会绕过
  // bf-image 的额度/路由/幂等边界。现在它已从部署包移除，契约改为「只剩门禁」。
  assert.match(API, /async function handleImage\(req, res\)[\s\S]{0,1500}sendError\(res, 503, "PLEASE_UPDATE"\)/,
    "旧 /api/image 没有固定的升级门禁");
  assert.doesNotMatch(API, /__legacyHandleImageDisabled/, "旧图片实现仍在部署包里（可被误调用）");
  assert.doesNotMatch(API, /seedream-5-0-pro\|seedream-4-0/, "旧转发实现的上游分支仍然存在");
  assert.doesNotMatch(API, /IMG_DEBOUNCE/, "旧防抖缓存仍在（说明旧实现没删干净）");
});
