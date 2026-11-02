const test = require('node:test');
const assert = require('node:assert/strict');
const { VERSION, injectCommercialImageGuidance } = require('../cloudfunctions/bf-api/commercial-image-guidance');

test('old phone receives business image guidance even when it already carries truthfulness rules', () => {
  const messages = [{role: 'system', content: '数据真实性铁律'}, {role: 'user', content: '做一张展会海报'}];
  const tools = [{type: 'function', function: {name: 'image_generate'}}];
  const once = injectCommercialImageGuidance(messages, tools, '做一张展会海报');
  assert.equal(once.length, 3);
  assert.match(once[2].content, /真实使用场景/);
  assert.equal(once[2].content.includes(VERSION), true);
  assert.equal(injectCommercialImageGuidance(once, tools, '做一张展会海报'), once);
  assert.equal(messages.length, 2);
});

test('normal chat and noncommercial image retain the existing prompt', () => {
  const messages = [{role: 'user', content: '你好'}];
  const tools = [{type: 'function', function: {name: 'image_generate'}}];
  assert.equal(injectCommercialImageGuidance(messages, tools, '你好'), messages);
  assert.equal(injectCommercialImageGuidance(messages, tools, '画一只小猫'), messages);
  assert.equal(injectCommercialImageGuidance(messages, [], '做展会海报'), messages);
});
