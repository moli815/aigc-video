'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { extract } = require('../cloudfunctions/shared/verbatim-image-prompt');
const intent = require('../cloudfunctions/bf-api/intent-contract');
const { sanitizeCompletion } = require('../cloudfunctions/shared/image-delivery');
const brief = '4:3 丝网印刷。\n  标题「山城徒步夜」。\n数据来源：用户指定的正文';
const request = '这段是另一个 AI 润色好的成稿提示词，请不要再润色或替换风格，按下面这段做图：\n' + brief;
test('only a current affirmative envelope selects the authored prompt', () => {
  assert.equal(extract(request),brief);
  assert.equal(extract('原样直传：'+brief),brief);
  for (const text of ['请针对海报润色：'+brief, '不要原样传给绘图模型：'+brief, '能否原样传给绘图模型：'+brief, '把 Logo 原样贴上去：正中', '只印标题：提示词不要再润色']) assert.equal(extract(text),null);
});
function final(user,previous,extra={}) {
  const messages=[{role:'user',content:previous},{role:'user',content:user}];
  const tool={function:{name:'image_generate',arguments:JSON.stringify({source:'attached',source_indexes:[1,2],reference_roles:['产品','背景'],prompt:'重写了的说明',aspect_ratio:'3:4',structured:{text:[{role:'title',key:'t',text:'模型标题'}],...extra}})}};
  const response=sanitizeCompletion({choices:[{message:{tool_calls:[tool]}}]},user,()=>{},calls=>intent.apply(calls,intent.resolve({messages})));
  return JSON.parse(response.choices[0].message.tool_calls[0].function.arguments);
}
test('approved wording survives finalization with aspect and attachment slots',()=>{
 const out=final(request,'上次做竖版海报。');
 assert.equal(out.structured.verbatim_prompt,brief);
 assert.equal(out.aspect_ratio,'4:3');
 assert.deepEqual(out.source_indexes,[1,2]);
 assert.deepEqual(out.reference_roles,['产品','背景']);
 assert.equal(out.structured.text,undefined);
});
test('historic request and planner cannot opt the current ordinary poster into verbatim mode',()=>{
 const out=final('画一张商业海报',request,{verbatim_prompt:'模型伪造'});
 assert.equal(out.structured.verbatim_prompt,undefined);
 assert.equal(out.structured.poster_delivery.version,1);
});
test('normal legacy edit keeps creative directions and freely chosen canvas',()=>{
 const fn={name:'image_edit',arguments:JSON.stringify({source:'last',prompt:'八个小节全幅对开，保留右栏空白。',aspect_ratio:'2:1',structured:{text:[{role:'body',text:'原版文字'}]}})};
 const out=intent.apply([{function:fn}],intent.resolve({messages:[{role:'user',content:'只改海报标题'}]}));
 const args=JSON.parse(out[0].function.arguments);
 assert.equal(args.aspect_ratio,undefined);assert.equal(args.prompt,JSON.parse(fn.arguments).prompt);
});

test('all supplied references stay present in an explicitly authored brief', () => {
 const user='原样生图：三张产品图全部用上，纯白底。';
 const args={prompt:'模型重写',source:'attached',source_index:2};
 const call={function:{name:'image_generate',arguments:JSON.stringify(args)}};
 const content=[{type:'text',text:user},...[1,2,3].map(i=>({type:'image_url',image_url:{url:'fixture-'+i}}))];
 const [out]=intent.apply([call],intent.resolve({messages:[{role:'user',content}]}));
 const payload=JSON.parse(out.function.arguments);
 assert.deepEqual(payload.source_indexes,[1,2,3]);
 assert.equal(payload.structured.verbatim_prompt,'三张产品图全部用上，纯白底。');
});
