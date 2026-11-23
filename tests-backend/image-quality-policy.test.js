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

test("both routes use the shared provider policy, omission is not treated as a disable switch", () => {
  const src = fs.readFileSync(path.join(__dirname, "../cloudfunctions/bf-api/index.js"), "utf8");
  assert.match(src, /arkPayload\.optimize_prompt_options = providerPromptOptions\(/);
  assert.match(source, /payload\.optimize_prompt_options = providerPromptOptions\(/);
  const { providerPromptOptions } = require('../cloudfunctions/shared/image-policy');
  assert.deepEqual(providerPromptOptions('doubao-seedream-5-0-pro-260628', 'pro_only', '1'), {mode:'standard'});
  assert.deepEqual(providerPromptOptions('doubao-seedream-5-0-pro-260628', 'auto', '1'), {mode:'fast'});
  assert.deepEqual(providerPromptOptions('unsupported', 'auto', '1'), {mode:'standard'});
});
