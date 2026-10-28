const test = require('node:test');
const assert = require('node:assert/strict');
const { VERSION, enabledFor, injectLegacyBrandGuidance } = require('../cloudfunctions/shared/image-legacy-brand');
const { sanitizeToolCall, ToolCallStreamGuard } = require('../cloudfunctions/shared/image-delivery');

const accountId = 'isolated-compat-test';
const policy = { enabled: true, accountIds: [accountId] };
const tools = [{ type: 'function', function: { name: 'image_edit', parameters: { type: 'object',
  properties: { prompt: { type: 'string' }, source: { type: 'string', enum: ['last', 'attached', 'both'] },
    source_index: { type: 'integer' }, source_indexes: { type: 'array' }, reference_roles: { type: 'array' }, library_refs: { type: 'array' },
    structured: { type: 'object', properties: { preserve_assets: { type: 'array' }, text: { type: 'array' } } } } } } }];
const messages = [{ role: 'system', content: '旧包系统提示' }, { role: 'user', content: '在刚生成的海报左上角加上我们的Logo' }];
const inject = (options = {}) => injectLegacyBrandGuidance({ messages, tools, policy, accountId, ...options });

for (const value of [undefined, null, '', '{broken', [], true, 'true', {}, { enabled: 'true', accountIds: [accountId] },
  { enabled: false, accountIds: [accountId] }, { enabled: true }, { enabled: true, accountIds: ['*'] },
  { enabled: true, accountIds: ['another-account'] }]) {
  test('closed or invalid config preserves the exact legacy request: ' + JSON.stringify(value), () => {
    assert.equal(inject({ policy: value }), messages);
  });
}

test('admission uses an explicit exact account id, never a wildcard or substring', () => {
  assert.equal(enabledFor(JSON.stringify(policy), accountId), true);
  assert.equal(enabledFor(policy, ''), false);
  assert.equal(enabledFor(policy, 'isolated'), false);
  assert.equal(enabledFor({ enabled: true, accountIds: new Array(101).fill(accountId) }, accountId), false);
  assert.equal(enabledFor(' '.repeat(6001), accountId), false);
});

test('the phone must actually declare the compatible edit contract', () => {
  for (const value of [undefined, [], [{ type: 'function', function: { name: 'generate_image' } }],
    [{ type: 'function', function: { name: 'image_edit', parameters: { properties: {} } } }]]) {
    assert.equal(inject({ tools: value }), messages);
  }
  const old = structuredClone(tools);
  old[0].function.parameters.properties.source.enum = ['attached', 'last'];
  assert.equal(inject({ tools: old }), messages);
  for (const key of ['source_index', 'source_indexes', 'reference_roles', 'library_refs']) {
    const unsupported = structuredClone(tools);
    delete unsupported[0].function.parameters.properties[key];
    assert.equal(inject({ tools: unsupported }), messages);
  }
  const unsupported = structuredClone(tools);
  delete unsupported[0].function.parameters.properties.structured.properties;
  assert.equal(inject({ tools: unsupported }), messages);
});

test('normal chat, documents and ordinary image tasks do not get extra rules', () => {
  for (const content of ['你好', '给我做一张海报', '我是谁', '公司Logo的含义是什么', '导出合同']) {
    const request = [{ role: 'user', content }];
    assert.equal(inject({ messages: request }), request);
  }
});

test('admitted logo planning adds a system message without mutating images, tools or execution data', () => {
  const input = [{ role: 'user', content: [{ type: 'text', text: '把我们的Logo放到海报左上角' },
    { type: 'image_url', image_url: { url: 'data:image/png;base64,fixture-placeholder' } }] }];
  const before = JSON.stringify({ input, tools });
  const output = inject({ messages: input });
  assert.equal(output.length, 2);
  assert.equal(output[0], input[0]);
  assert.equal(output[1].role, 'system');
  assert.ok(output[1].content.includes(VERSION));
  assert.equal(JSON.stringify({ input, tools }), before);
  assert.equal(inject({ messages: output }), output);
});

test('turning off the policy affects the next request without changing its tool payload', () => {
  const enabled = inject();
  assert.equal(enabled.length, messages.length + 1);
  assert.equal(inject({ policy: { enabled: false, accountIds: [accountId] } }), messages);
});

const legacyCalls = [
  ['image_generate', { prompt: '普通插画', source: 'none', count: 1, aspect_ratio: '1:1' }],
  ['image_edit', { prompt: '只改背景', source: 'attached', source_index: 1 }],
  ['image_edit', { prompt: '将人物素材放入底图', source: 'attached', source_indexes: [2, 1], reference_roles: ['底图', '人物素材'] }],
  ['image_edit', { prompt: '将人物和产品素材放入底图', source: 'attached', source_indexes: [3, 1, 2], reference_roles: ['底图', '人物素材', '产品素材'] }],
  ['image_edit', { prompt: '添加Logo，保留原图', source: 'both', source_index: 1,
    structured: { preserve_outside: true, text: [], preserve_assets: [{ reference_index: 2, kind: 'logo', background: 'auto',
      box: { x: 0.055, y: 0.055, width: 0.16, height: 0.16 } }] } }],
  ['image_edit', { prompt: '替换原Logo', source: 'attached', library_refs: ['99EF56A7-E5F5-4425-BD52-F77657D3B111', '99EF56A7-E5F5-4425-BD52-F77657D3B112'],
    structured: { preserve_outside: true, text: [], preserve_assets: [{ reference_index: 2, kind: 'logo', background: 'keep',
      box: { x: 0.1, y: 0.1, width: 0.2, height: 0.1 } }] } }],
  ['image_series', { prompt: '四张风景图', source: 'none', count: 4 }],
  ['image_decompose', { prompt: '拆分图层', source: 'attached', source_index: 1 }],
];

for (const [name, args] of legacyCalls) test('existing execution fields survive JSON and fragmented SSE: ' + name + '/' + args.prompt, () => {
  const call = { index: 0, id: 'legacy', type: 'function', function: { name, arguments: JSON.stringify(args) } };
  const output = JSON.parse(sanitizeToolCall(call, args.prompt).function.arguments);
  const assertLegacy = value => {
    for (const [key, expected] of Object.entries(args)) {
      if (key === 'structured') {
        for (const [field, item] of Object.entries(expected)) assert.deepEqual(value.structured[field], item);
      } else assert.deepEqual(value[key], expected);
    }
  };
  assertLegacy(output);
  const stream = new ToolCallStreamGuard(args.prompt);
  const input = call.function.arguments, cut = Math.floor(input.length / 2);
  const frame = (delta, finish = null) => 'data: ' + JSON.stringify({ choices: [{ index: 0, delta, finish_reason: finish }] });
  stream.pushLine(frame({ tool_calls: [{ ...call, function: { name, arguments: input.slice(0, cut) } }] }));
  stream.pushLine(frame({ tool_calls: [{ index: 0, function: { arguments: input.slice(cut) } }] }));
  const last = JSON.parse(stream.pushLine(frame({}, 'tool_calls')).slice(6));
  assertLegacy(JSON.parse(last.choices[0].delta.tool_calls[0].function.arguments));
  stream.end();
});
