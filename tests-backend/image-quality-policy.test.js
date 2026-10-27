const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../cloudfunctions/bf-image/index.js'), 'utf8');
const start = source.indexOf('function promptOptimizationMode(');
const end = source.indexOf('\n}', start) + 2;
const context = {};
vm.runInNewContext(source.slice(start, end), context);

test('Pro-only quality tuning always uses standard, including stale fast=1 configuration', () => {
  assert.equal(context.promptOptimizationMode('pro_only', '1'), 'standard');
  assert.equal(context.promptOptimizationMode('pro_only', '0'), 'standard');
});

test('fast optimization is opt-in outside Pro-only, never the missing-config default', () => {
  assert.equal(context.promptOptimizationMode('auto', undefined), 'standard');
  assert.equal(context.promptOptimizationMode('auto', '0'), 'standard');
  assert.equal(context.promptOptimizationMode('auto', '1'), 'fast');
});

test('app series orchestration requests one image per child, independent of native-series capability', () => {
  const start = source.indexOf('async function runSeriesChild(');
  const end = source.indexOf('\nfunction ', start);
  const child = source.slice(start, end > 0 ? end : start + 5000);
  assert.match(child, /taskKind: "generate"/);
  assert.match(child, /requestedCount: 1/);
  assert.match(child, /claimIdem\(subRid, accountId\)/);
  assert.match(child, /claim\.state === "done"/);
  assert.doesNotMatch(child.slice(0, child.indexOf('const model =')), /capsOf|sequential_image_generation/);
});

// 10-27：服务端提示词优化会改写我们的硬约束 —— 带参考图的任务必须关掉它
test("prompt optimization is disabled whenever a reference image is present", () => {
  const src = fs.readFileSync(path.join(__dirname, "../cloudfunctions/bf-api/index.js"), "utf8");
  const start = src.indexOf("const wantsPromptOpt");
  assert.ok(start > 0, "缺少提示词优化开关判定");
  assert.match(src.slice(start, start + 200), /const wantsPromptOpt = !hasRefImg &&/,
    "开关没有以「无参考图」为前提，编辑/参考图任务仍会被改写 prompt");
  const block = src.slice(start, start + 520);
  assert.match(block, /if \(wantsPromptOpt && RUNTIME\.IMAGE_ROUTING_MODE === "pro_only"\)/,
    "pro_only 分支绕过了 wantsPromptOpt，会把编辑任务的 prompt 也交给平台改写");
  assert.match(block, /delete arkPayload\.optimize_prompt_options/,
    "缺少兜底删除，非白名单场景可能带着上一次的优化配置发出");
});
