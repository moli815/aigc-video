const test = require('node:test'), assert = require('node:assert/strict');
const policy = require('../config/image-auto-quality-balanced.json');
const { autoDecision, parseAutoPolicy } = require('../cloudfunctions/bf-image/image-routing');
const { sanitizeToolCall, ToolCallStreamGuard } = require('../cloudfunctions/shared/image-delivery');
const { requestsQuality, requestsModel } = require('../cloudfunctions/shared/image-quality-intent');
function request(user, args = {}) {
  const call = { id: 'one', type: 'function', function: { name: 'image_generate', arguments: JSON.stringify({prompt: '专业级高品质设计 ' + user, quality_tier: 'high', ...args}) } };
  return JSON.parse(sanitizeToolCall(call, user).function.arguments);
}
test('user quality is honored but Agent boilerplate and baked-in high are not human intent', () => {
  for (const user of ['高质量海报', '专业级海报', '做得精美一些', '正式印刷用', 'high quality poster']) {
    assert.equal(autoDecision(request(user), policy).reason, 'auto:user-quality');
  }
  assert.equal(autoDecision(request('画一只小猫'), policy).tier, 'fast');
  assert.equal(autoDecision({qualityTier: 'high'}, policy).tier, 'fast');
});
test('negative quality and model requests do not become affirmative upgrades', () => {
  for (const text of ['不需要高质量', '不用专业级', '不追求精美', '无需高品质']) assert.equal(requestsQuality(text), false, text);
  assert.equal(requestsQuality('不需要高质量，但要精美'), true);
  for (const text of ['不要用Pro', '不用Pro', '禁止使用 Pro']) assert.equal(requestsModel(text, 'pro'), false, text);
  assert.equal(autoDecision(request('不要用Pro，画普通小猫', {prompt: '普通小猫'}), policy).tier, 'fast');
  assert.equal(autoDecision(request('请使用Pro', {prompt: '小猫'}), policy).tier, 'high');
});
test('detailed layouts without input images and identity edits use configurable Pro reasons', () => {
  assert.equal(autoDecision(request('排一个复杂的产品功能布局', {quality_reason: 'detailed_layout'}), policy).reason, 'auto:detailed_layout');
  assert.equal(autoDecision({...request('保持本人五官换装', {quality_reason: 'identity_sensitive'}), image: ['a']}, policy).tier, 'high');
  assert.equal(autoDecision(request('复杂编辑', {quality_reason: 'complex_edit'}), {...policy, proReasons: []}).tier, 'fast');
});
test('direct old request gets literal fallback; user-origin auto prevents decoration from triggering it', () => {
  assert.equal(autoDecision({prompt: '高质量海报', qualityTier: 'high'}, policy).reason, 'auto:prompt-quality');
  assert.equal(autoDecision(request('普通配图'), policy).tier, 'fast');
  assert.equal(autoDecision(request('高质量海报'), {...policy, honorUserQuality: false}).tier, 'fast');
});
test('native copy threshold is configurable and overlay text does not inflate provider complexity', () => {
  const structured = {text: [{text: '文'.repeat(110)}]};
  assert.equal(autoDecision({structured}, policy).tier, 'high');
  assert.equal(autoDecision({structured, textMode: 'overlay'}, policy).tier, 'fast');
  assert.equal(autoDecision({structured}, {...policy, nativeTextCharsForPro: 180}).tier, 'fast');
});
test('JSON and fragmented SSE forward the same user-origin signal without changing reference ordering', () => {
  const args = {prompt: '普通背景', source: 'attached', source_indexes: [2,1], reference_roles: ['底图','人物素材']};
  const expected = request('高质量合成', args);
  const guard = new ToolCallStreamGuard('高质量合成');
  const raw = JSON.stringify(args), half = Math.floor(raw.length / 2);
  function frame(delta, finish = null) { return 'data: ' + JSON.stringify({choices: [{index:0, delta, finish_reason:finish}]}); }
  guard.pushLine(frame({tool_calls:[{index:0,id:'one',function:{name:'image_generate',arguments:raw.slice(0,half)}}]}));
  guard.pushLine(frame({tool_calls:[{index:0,function:{arguments:raw.slice(half)}}]}));
  const out = JSON.parse(guard.pushLine(frame({}, 'tool_calls')).slice(6)).choices[0].delta.tool_calls[0];
  const actual = JSON.parse(out.function.arguments);
  assert.deepEqual(actual.structured.routing, expected.structured.routing);
  assert.deepEqual(actual.source_indexes, [2,1]); guard.end();
});
test('representative workload is 70 percent Flash and 30 percent Pro, never a production quota', () => {
  const cheap = ['画猫','简单图标','普通背景','名片草稿','产品配图','只改颜色','简单海报'];
  const expensive = [request('高质量宣传海报'), request('复杂版式', {quality_reason:'detailed_layout'}), request('上一张排版不好，重做')];
  const tiers = [...cheap.map(x => request(x)), ...expensive].map(x => autoDecision(x, policy).tier);
  assert.equal(tiers.filter(x => x === 'high').length, 3);
  assert.equal(Array.from({length:10}, () => autoDecision(request('专业级印刷海报'), policy)).every(x => x.tier === 'high'), true);
});
test('malformed policy fields are ignored rather than disabling service', () => {
  const parsed = parseAutoPolicy({honorUserQuality: 'yes', proPromptTerms: [null]});
  assert.equal(parsed.honorUserQuality, false); assert.deepEqual(parsed.proPromptTerms, []);
  assert.deepEqual(parseAutoPolicy({proPromptTerms:['']}).proPromptTerms, []);
});
