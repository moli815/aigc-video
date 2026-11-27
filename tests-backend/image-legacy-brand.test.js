const test = require('node:test');
const assert = require('node:assert/strict');
const { VERSION, enabledFor, injectLegacyBrandGuidance, guardBrandCalls, requestsMultipleBrandOutputs } = require('../cloudfunctions/shared/image-legacy-brand');
const { sanitizeToolCall, sanitizeCompletion, ToolCallStreamGuard } = require('../cloudfunctions/shared/image-delivery');

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

test('explicit all-member rollout is enabled only for a nonempty authenticated subject', () => {
  assert.equal(enabledFor({ enabled: true, audience: 'all' }, accountId), true);
  assert.equal(enabledFor({ enabled: true, audience: 'all' }, ''), false);
  assert.equal(enabledFor({ enabled: true, audience: '*' }, accountId), false);
  assert.equal(enabledFor({ enabled: false, audience: 'all' }, accountId), false);
  assert.equal(inject({ policy: { enabled: true, audience: 'all' } }).length, messages.length + 1);
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

const edit = (id, args = { prompt: '添加原Logo', source: 'both', source_index: 1 }) =>
  ({ id, type: 'function', function: { name: 'image_edit', arguments: JSON.stringify(args) } });
test('identical parallel image calls yield one executable edit, with privacy-safe diagnostics', () => {
  const first = edit('a'), second = edit('b', { source_index: 1, source: 'both', prompt: '添加原Logo' });
  const document = { id: 'doc', function: { name: 'create_document', arguments: '{"body":"合同"}' } }, logs = [];
  const output = guardBrandCalls([first, document, second], event => logs.push(event));
  assert.deepEqual(output, [first, document]);
  assert.deepEqual(logs, [{ event: 'brand_duplicate_calls_removed', removed: 1 }]);
});
test('different positions, prompts or source material fail before any executable call is forwarded', () => {
  const logs = [];
  assert.throws(() => guardBrandCalls([edit('a'), edit('b', { prompt: '添加原Logo', source: 'both', source_index: 2 })], e => logs.push(e)), { code: 'BRAND_PLAN_CONFLICT' });
  assert.deepEqual(logs, [{ event: 'brand_plan_conflict', imageCallCount: 2 }]);
});
test('two input photos do not imply two deliverables; explicit per-poster edits remain supported', () => {
  assert.equal(requestsMultipleBrandOutputs('我发两张图片，一张Logo一张海报，把Logo加上海报'), false);
  for (const text of ['给每张海报加上Logo', '两张海报都加上Logo', '分别给两张海报添加Logo']) {
    assert.equal(requestsMultipleBrandOutputs(text), true);
    const calls = [edit('a'), edit('b', { prompt: '第二张加Logo', source: 'attached', source_index: 2 })];
    assert.equal(guardBrandCalls(calls, () => {}, text), calls);
  }
});
test('non-stream completion uses the same duplicate-call boundary', () => {
  const response = { choices: [{ message: { role: 'assistant', tool_calls: [edit('a'), edit('b')] } }] };
  const output = sanitizeCompletion(response, '加上Logo', undefined, guardBrandCalls);
  assert.equal(output.choices[0].message.tool_calls.length, 1);
  assert.equal(response.choices[0].message.tool_calls.length, 2);
});
test('stream duplicate calls are withheld until complete and sent only once', () => {
  const guard = new ToolCallStreamGuard('加上Logo', undefined, guardBrandCalls);
  const frame = (calls, finish = null) => 'data: ' + JSON.stringify({ choices: [{ index: 0, delta: { tool_calls: calls }, finish_reason: finish }] });
  const early = guard.pushLine(frame([{ ...edit('a'), index: 0 }, { ...edit('b'), index: 1 }]));
  assert.equal(JSON.parse(early.slice(6)).choices[0].delta.tool_calls, undefined);
  const last = guard.pushLine(frame([], 'tool_calls'));
  assert.equal(JSON.parse(last.slice(6)).choices[0].delta.tool_calls.length, 1);
  guard.end();
});
test('stream conflicting plans cannot partially leak an image call', () => {
  const guard = new ToolCallStreamGuard('加上Logo', undefined, guardBrandCalls);
  guard.pushLine('data: ' + JSON.stringify({ choices: [{ index: 0, delta: { tool_calls: [
    { ...edit('a'), index: 0 }, { ...edit('b', { prompt: '不同方案', source: 'both' }), index: 1 }] } }] }));
  assert.throws(() => guard.pushLine('data: [DONE]'), { code: 'BRAND_PLAN_CONFLICT' });
});

test("successful image tool return suppresses only a second image on the current single-image turn", () => {
  const { deliveredSingleImage } = require("../cloudfunctions/bf-api/image-task-readiness");
  const prompt = "根据今天的AI热点新闻做一个海报";
  const user = { role: "user", content: prompt };
  const toolCall = { role: "assistant", tool_calls: [{ id: "first", function: { name: "image_generate" } }] };
  const delivered = { role: "tool", tool_call_id: "first", content: "图片生成已完成并展示给用户。给用户的回复控制在一句话内。" };
  const history = [user, toolCall, delivered];
  assert.equal(deliveredSingleImage(history, prompt), true);
  assert.equal(deliveredSingleImage(history, "做两张海报"), false);
  assert.equal(deliveredSingleImage([...history, user], prompt), false);
  assert.equal(deliveredSingleImage([user, toolCall, {...delivered, tool_call_id: "different"}], prompt), false);
  assert.equal(deliveredSingleImage([user, toolCall, {...delivered, content: "图片生成失败"}], prompt), false);
});

test("adding one attached Logo preserves the selected poster and rejects ungrounded redraw plans", () => {
  const { uploadedLogoAddition, finalizeUploadedLogoAddition } = require("../cloudfunctions/shared/image-legacy-brand");
  const user = "在海报上加上这个logo";
  const text = text => ({ type: "text", text });
  const photo = url => ({ type: "image_url", image_url: { url } });
  const withPreview = [{ role: "user", content: [
    text("【本次编辑前生成图预览】"), photo("base"),
    text("【以下是用户本轮输入与上传附件，source_index仍按原附件顺序从1计数】"),
    text(user), photo("logo")
  ] }];
  const intent = uploadedLogoAddition(withPreview, user);
  assert.deepEqual(intent, { base: true });
  const edit = { function: { name:"image_edit", arguments:JSON.stringify({
    source:"attached", prompt:"重画海报，标题和正文", structured:{
      text:[{key:"title",role:"title",text:"和正文"}],
      preserve_assets:[{reference_index:1,box:{x:0.03,y:0.03,width:0.12,height:0.12}}]
    }
  }) } };
  const clean = JSON.parse(finalizeUploadedLogoAddition([edit], intent)[0].function.arguments);
  assert.equal(clean.source, "both");
  assert.equal(clean.source_index, 1);
  assert.equal(clean.structured.preserve_assets[0].reference_index, 2);
  assert.equal(clean.structured.exact_logo_addition, true);
  assert.deepEqual(clean.structured.text, []);
  assert.doesNotMatch(clean.prompt, /和正文|重画/);
  const pending = { prompt: "参考原海报改成竖版9:16", image: ["base"], structured: clean.structured };
  assert.equal(require("../cloudfunctions/shared/poster-reformat").normalize(pending), pending);
  assert.throws(() => finalizeUploadedLogoAddition([edit], { base: false }), { code: "BRAND_PLAN_CONFLICT" });
  assert.throws(() => finalizeUploadedLogoAddition([{function:{...edit.function,name:"image_generate"}}], intent), { code: "BRAND_PLAN_CONFLICT" });
  assert.equal(uploadedLogoAddition(withPreview, "在海报上加上这个logo，另外换成漫画风"), null);
});

test('纠错必须带贴标前原稿和同一份原Logo', () => {
  const {uploadedLogoAddition} = require('../cloudfunctions/shared/image-legacy-brand');
  const text = '我要科技风的 而且这个这个标题是个什么东西 我只要加上logo';
  const parts = [{type:'text',text:'【本次编辑前生成图预览】已回到上次贴标前的原海报。'},
    {type:'image_url'}, {type:'text',text:'【以下是用户本轮输入与上传附件，source_index仍按原附件顺序从1计数】'},
    {type:'text',text}, {type:'image_url'}];
  const intent = content => uploadedLogoAddition([{role:'user',content}],text);
  assert.deepEqual(intent(parts),{base:true});
  assert.deepEqual(intent(parts.slice(3)),{base:false});
  assert.deepEqual(intent(text),{base:false});
  assert.deepEqual(intent([{type:'text',text:'【本次编辑前生成图预览】最新成图'},...parts.slice(1)]),{base:false});
});

test('two uploaded originals: restyle with numbered logo keeps source copy and asset roles', () => {
  const {uploadedLogoAddition, finalizeUploadedLogoAddition} = require('../cloudfunctions/shared/image-legacy-brand');
  const messages = [{role:'user',content:[{type:'image_url'},{type:'image_url'}]}];
  const text = '换成科技风的并且加上图二的logo';
  const intent = uploadedLogoAddition(messages, text);
  const decoy = {function:{name:'image_edit',arguments:JSON.stringify({prompt:'标题区加冷蓝色霓虹光效',structured:{
    text:[{role:'title',text:'和正文'}],preserve_assets:[{box:{x:.82,y:.04,width:.1,height:.08}}]}})}};
  const args = JSON.parse(finalizeUploadedLogoAddition([decoy], intent)[0].function.arguments);
  assert.deepEqual(args.source_indexes,[1,2]);
  assert.equal(args.source,'attached');
  assert.deepEqual(args.reference_roles,['原海报', 'Logo原件']);
  assert.equal(args.structured.preserve_assets,undefined);
  assert.deepEqual(args.structured.text,[]);
  assert.match(args.prompt,/科技风/); assert.doesNotMatch(args.prompt,/霓虹|和正文/);
  const legacy = uploadedLogoAddition(messages,'把这张海报换成科技风并加上图二的logo');
  const local = JSON.parse(finalizeUploadedLogoAddition([decoy],legacy)[0].function.arguments);
  assert.equal(local.structured.preserve_assets[0].reference_index,2);
  assert.equal(local.structured.preserve_outside,false);
  assert.deepEqual(uploadedLogoAddition(messages, '改成水墨风并加上图一的徽标').indices,[2,1]);
  assert.equal(uploadedLogoAddition(messages,text+'，并把标题改成夜航'),null);
});

test('poster palette defaults to a content-driven saturated accent and keeps explicit requests', () => {
  const {mark, compile, DEFAULT_COLOR_DIRECTION} = require('../cloudfunctions/shared/poster-delivery');
  const text=[{key:'t',role:'title',text:'AI 热讯日报'}];
  const visual='主视觉展示相应主题的现场';
  assert.ok(compile({visual,structured:mark({text},'制作一张海报'),density:'dense'}).includes(DEFAULT_COLOR_DIRECTION));
  const user='采用低饱和配色和黑白摄影，用大量留白';
  const explicit=compile({visual,structured:mark({text},user),density:'dense'});
  assert.ok(explicit.includes(user)); assert.ok(!explicit.includes(DEFAULT_COLOR_DIRECTION));
  const minimal=compile({visual,structured:mark({text},'极简海报，只写标题'),density:'sparse'});
  assert.ok(!minimal.includes(DEFAULT_COLOR_DIRECTION));
});

test('a named corner for the uploaded Logo is kept on the selected original poster',()=>{
 const {uploadedLogoAddition,finalizeUploadedLogoAddition}=require('../cloudfunctions/shared/image-legacy-brand');
 const text='请在原海报右下角加上这个Logo';
 const intent=uploadedLogoAddition([{role:'user',content:[
  {type:'text',text:'【本次编辑前生成图预览】'},{type:'image_url'},
  {type:'text',text:'【以下是用户本轮输入与上传附件，source_index仍按原附件顺序从1计数】'},
  {type:'text',text},{type:'image_url'}
 ]}],text);
 assert.deepEqual(intent,{base:true,corner:'右下角'});
 const make=(x,y)=>[{function:{name:'image_edit',arguments:JSON.stringify({prompt:'放在左上角并重排文字',structured:{
  preserve_assets:[{reference_index:2,box:{x,y,width:.08,height:.08}}]}})}}];
 assert.throws(()=>finalizeUploadedLogoAddition(make(.08,.08),intent),{code:'BRAND_PLAN_CONFLICT'});
 const args=JSON.parse(finalizeUploadedLogoAddition(make(.83,.81),intent)[0].function.arguments);
 assert.equal(args.source,'both');
 assert.equal(args.source_index,1);
 assert.equal(args.structured.preserve_outside,true);
 assert.deepEqual(args.structured.text,[]);
 assert.match(args.prompt,/右下角/);
 assert.doesNotMatch(args.prompt,/左上角|重排/);
 const twoUploads=[{role:'user',content:[{type:'image_url'},{type:'image_url'}]}];
 const selected=uploadedLogoAddition(twoUploads,'请在图二海报左下角加上图一的Logo');
 assert.deepEqual(selected,{base:true,corner:'左下角',indices:[2,1]});
 const attached=JSON.parse(finalizeUploadedLogoAddition(make(.08,.81),selected)[0].function.arguments);
 assert.equal(attached.source,'attached');
 assert.deepEqual(attached.source_indexes,[2,1]);
 assert.match(attached.prompt,/左下角/);

});
