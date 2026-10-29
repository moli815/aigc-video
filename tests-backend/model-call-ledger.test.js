const test = require('node:test'), assert = require('node:assert/strict');
const { createModelCallLedger, tokenCost, usageOf, orderIdOf } = require('../cloudfunctions/shared/model-call-ledger');
const { parseQuery } = require('../cloudfunctions/bf-api/domains/model-call-report');
function harness(opts = {}) {
  const rows = new Map(), logs = [], ctx = { accountId: 'member-1', requestId: 'trace-1', endpoint: '/api/chat' };
  let failures = 0;
  const db = { collection: () => ({
    async add(row) { if (opts.failInsert) throw new Error('database unavailable'); rows.set(row._id, { ...row }); },
    doc: id => ({ async update(patch) { if (opts.failUpdate && failures++ < 2) throw new Error('write failed'); assert.ok(rows.has(id)); Object.assign(rows.get(id), patch); } }),
  }) };
  const ledger = createModelCallLedger({ db, context: () => ctx, source: 'test', log: x => logs.push(x),
    pricing: () => opts.pricing || null });
  const options = { method: 'POST', headers: { Authorization: 'Bearer PRIVATE_KEY' }, body: JSON.stringify({
    model: 'deepseek-test', messages: [{role:'user',content:'PRIVATE_PROMPT'}], stream: !!opts.stream,
  }) };
  return { rows, logs, ctx, ledger, options };
}
test('JSON call preserves response and tracks account, vendor IDs, cached tokens and separate prices', async () => {
  const h = harness({pricing:{rates:{input:2,output:8,cachedInput:0.5}}});
  const data = { id:'completion-7',model:'actual-model',usage:{prompt_tokens:1000,completion_tokens:200,prompt_tokens_details:{cached_tokens:100}},choices:[] };
  const result = await h.ledger.fetch('https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions',h.options,
    async(url,options) => { assert.equal(options,h.options); return new Response(JSON.stringify(data),{headers:{'x-request-id':'vendor-1'}}); });
  assert.deepEqual(await result.json(),data);
  const row = h.rows.get(result.modelCallId);
  assert.equal(row.status,'succeeded'); assert.equal(row.accountId,'member-1'); assert.equal(row.model,'actual-model');
  assert.equal(row.vendorRequestId,'vendor-1'); assert.equal(row.providerResponseId,'completion-7');
  assert.equal(row.supplierCostEstimateCny,0.00345); assert.equal(row.supplierBilledCny,null);
  await h.ledger.charge(result.modelCallId,0.01,'billing-event');
  await h.ledger.charge(result.modelCallId,0.01,'billing-event');
  assert.equal(row.priceCny,0.01); assert.equal(row.chargeState,'committed'); assert.equal(h.rows.size,1);
  assert.ok(!JSON.stringify([...h.rows.values()]).includes('PRIVATE')); assert.ok(!JSON.stringify(h.logs).includes('PRIVATE'));
});
test('fragmented UTF-8 SSE is unchanged, bounded and records final provider usage', async () => {
  const h = harness({stream:true});
  const raw = 'data: '+JSON.stringify({id:'stream-1',choices:[{delta:{content:'中文测试'},finish_reason:null}]})+'\n\n'
    +'data: '+JSON.stringify({choices:[{delta:{},finish_reason:'stop'}],usage:{prompt_tokens:20,completion_tokens:3,total_tokens:23}})+'\n\ndata: [DONE]\n\n';
  const bytes = new TextEncoder().encode(raw);
  const result = await h.ledger.fetch('https://dashscope.aliyuncs.com/chat/completions',h.options,async()=>new Response(new ReadableStream({start(c){for(let i=0;i<bytes.length;i+=7)c.enqueue(bytes.slice(i,i+7));c.close();}}),{headers:{'content-type':'text/event-stream'}}));
  assert.equal(await result.text(),raw);
  const row=h.rows.get(result.modelCallId); assert.equal(row.inputTokens,20); assert.equal(row.outputTokens,3); assert.equal(row.status,'succeeded');
  assert.equal(row.supplierCostEstimateCny,null);
});
test('provider HTTP retries have separate call IDs under one order; discarded error body still records rejection', async () => {
  const h=harness();
  for(let i=0;i<2;i++) await h.ledger.fetch('https://dashscope.aliyuncs.com/chat/completions',h.options,async()=>new Response('{}',{status:429}));
  const rows=[...h.rows.values()]; assert.equal(rows.length,2); assert.equal(rows[0].orderId,rows[1].orderId);
  assert.deepEqual(rows.map(x=>x.retryIndex),[0,1]); assert.ok(rows.every(x=>x.status==='rejected'&&x.priceCny===null));
});
test('timeouts and 5xx remain unknown costs, never zero-cost success', async () => {
  const h=harness();
  await assert.rejects(h.ledger.fetch('https://ark.cn-beijing.volces.com/api/v3/images/generations',h.options,async()=>{throw new Error('timeout');}));
  await h.ledger.fetch('https://ark.cn-beijing.volces.com/api/v3/images/generations',h.options,async()=>new Response('{}',{status:502}));
  assert.ok([...h.rows.values()].every(x=>x.status==='outcome_unknown'&&x.supplierBilledCny===null));
});
test('image output count and current model rate yield estimate without inventing token usage', async () => {
  const h=harness({pricing:{unitCostCny:0.12}});
  const r=await h.ledger.fetch('https://ark.cn-beijing.volces.com/api/v3/images/generations',h.options,async()=>new Response(JSON.stringify({data:[{url:'https://example.com/a'},{url:'https://example.com/b'}]})));
  await r.json(); const row=h.rows.get(r.modelCallId);
  assert.equal(row.outputImages,2); assert.equal(row.supplierCostEstimateCny,0.24); assert.equal(row.inputTokens,null);
});
test('truncated stream, SSE error and consumer cancel do not become successful generations', async () => {
  for(const raw of ['data: {"choices":[{"delta":{"content":"hello"}}]}\n\n', 'data: {"error":{"code":"RATE_LIMIT"}}\n\ndata: [DONE]\n\n']){
    const h=harness(); const r=await h.ledger.fetch('https://dashscope.aliyuncs.com/chat/completions',h.options,async()=>new Response(raw,{headers:{'content-type':'text/event-stream'}})); await r.text();assert.equal([...h.rows.values()][0].status,'outcome_unknown');
  }
  const h=harness(); const r=await h.ledger.fetch('https://dashscope.aliyuncs.com/chat/completions',h.options,async()=>new Response(new ReadableStream({pull(){}})));
  await r.body.cancel(); assert.equal([...h.rows.values()][0].errorCode,'CONSUMER_CANCELLED');
});
test('database finalization failures retain pending row and diagnostic; provider reply survives', async()=>{
  const h=harness({failUpdate:true}); const r=await h.ledger.fetch('https://dashscope.aliyuncs.com/chat/completions',h.options,async()=>new Response('{"usage":{"prompt_tokens":1,"completion_tokens":1}}'));
  await r.json(); assert.equal([...h.rows.values()][0].status,'pending'); assert.equal(h.logs.length,1); assert.equal(typeof h.logs[0].record.endedAt,'string');
});
test('provider token-limit truncation remains a charged partial response with exact usage',async()=>{
  const h=harness();const r=await h.ledger.fetch('https://dashscope.aliyuncs.com/chat/completions',h.options,async()=>new Response(JSON.stringify({choices:[{finish_reason:'length'}],usage:{prompt_tokens:100,completion_tokens:40}})));
  await r.json();const row=h.rows.get(r.modelCallId);assert.equal(row.status,'partial');assert.equal(row.outputTokens,40);assert.equal(row.finishReason,'length');
});
test('cache replay is zero-charge event under stable business order and another account cannot collide', async()=>{
  const h=harness(); h.ctx.businessRequestId='client-uuid';await h.ledger.cached('m','image');h.ctx.requestId='another-trace';await h.ledger.cached('m','image');
  const rows=[...h.rows.values()];assert.equal(rows[0].orderId,rows[1].orderId);assert.equal(rows[0].priceCny,0);
  assert.notEqual(orderIdOf('a','r'),orderIdOf('b','r'));
});
test('absent usage and missing cache rate stay unknown; micro-costs preserve precision',()=>{
  assert.equal(usageOf(null).inputTokens,null);
  assert.equal(tokenCost({inputTokens:100,outputTokens:5,cachedInputTokens:50},{input:1,output:1}),null);
  assert.equal(tokenCost({inputTokens:1,outputTokens:1},{input:0.8,output:2.7}),0.0000035);
});
test('admin query rejects oversized ranges, invalid account IDs and unbounded pagination',()=>{
  assert.equal(parseQuery(new URLSearchParams()).limit,50);
  for(const query of ['start=invalid','limit=100000','page=-1','accountId=%24ne','orderId=bad','start=2020-01-01&end=2026-01-01'])assert.throws(()=>parseQuery(new URLSearchParams(query)));
});
