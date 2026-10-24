// ============================================================================
// image-models-endpoint.test.js —— GET /img/models（10-24 新增）
//
// 目的：把「配置里写了 IMAGE_MODEL_PRO」和「实际会用哪个模型」摊开。
// 审计反复提同一个问题：配置存在 ≠ 请求真的走了那个模型。
// 这个端点给出运行态解析结果（三档 model id + 能力位 + 路由模式），且**不泄露密钥**。
// ============================================================================

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const IMG = fs.readFileSync(path.join(__dirname, "../cloudfunctions/bf-image/index.js"), "utf8");

test("MODELS-01 /img/models 路由存在且走运行态配置", () => {
  assert.match(IMG, /req\.method === "GET" && u\.indexOf\("\/models"\) >= 0/, "缺少 /img/models 路由");
  const start = IMG.indexOf('u.indexOf("/models")');
  const body = IMG.slice(start, start + 1600);
  assert.match(body, /await refreshRuntime\(\)/, "没有先刷新运行态配置（会读到旧值）");
  assert.match(body, /const m = modelsOf\(\)/, "没有用统一的 modelsOf() 解析三档");
  assert.match(body, /capsOf\(model\)/, "没有输出模型能力位");
});

test("MODELS-02 返回结构包含档位、能力、路由模式，且不含密钥值", () => {
  const start = IMG.indexOf('u.indexOf("/models")');
  const body = IMG.slice(start, start + 1600);
  for (const key of ["routingMode", "models: m", "caps", "keys:"]) {
    assert.ok(body.includes(key), `返回体缺少 ${key}`);
  }
  // 密钥只回布尔，绝不回值
  assert.match(body, /IMAGE_API_KEY: !!String\(RT\.IMAGE_API_KEY \|\| ""\)\.trim\(\)/, "IMAGE_API_KEY 未做布尔化");
  assert.doesNotMatch(body, /IMAGE_API_KEY: String\(RT\.IMAGE_API_KEY/, "疑似直接返回了密钥值");
});

test("MODELS-03 三档解析规则：新键优先、旧键做 pro 兼容别名、series 单独一档", () => {
  const start = IMG.indexOf("function modelsOf()");
  assert.ok(start > 0, "缺少 modelsOf()");
  const body = IMG.slice(start, start + 500);
  assert.match(body, /fast: String\(RT\.IMAGE_MODEL_FAST \|\| ""\)\.trim\(\) \|\| legacy/, "fast 档解析不对");
  assert.match(body, /pro: String\(RT\.IMAGE_MODEL_PRO \|\| ""\)\.trim\(\) \|\| legacy/, "pro 档解析不对（旧 IMAGE_MODEL 兼容丢失）");
  assert.match(body, /series: String\(RT\.IMAGE_MODEL_SERIES \|\| ""\)\.trim\(\)/, "series 档解析不对");
});

test("MODELS-04 端点必须同时返回 selectImageRoute 的真实结果（不只是配置）", () => {
  const start = IMG.indexOf('u.indexOf("/models")');
  const body = IMG.slice(start, start + 2600);
  assert.match(body, /selectImageRoute\(/, "没有调用真实的选模函数（只回配置等于没验证）");
  for (const k of ["generate_auto", "generate_pro", "edit_pro", "series"]) {
    assert.ok(body.includes(`key: "${k}"`), `缺少路由探针 ${k}`);
  }
  assert.match(body, /model: r\.model \|\| ""/, "探针没有回传实际 model");
  assert.match(body, /unsupported: !!r\.unsupported/, "没有回传不支持标记");
});

test("MODELS-05 路由失败不能把整个端点打挂", () => {
  const start = IMG.indexOf('u.indexOf("/models")');
  const body = IMG.slice(start, start + 2600);
  assert.match(body, /catch \(e\) \{[\s\S]{0,160}route-error/, "单个探针异常没有兜底");
});
