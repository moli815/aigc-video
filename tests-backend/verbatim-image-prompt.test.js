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

test('shipped and split attachment notes stay with the planner, outside the authored prompt', () => {
  const { fromMessages } = require('../cloudfunctions/shared/verbatim-image-prompt');
  const note = '【图片文字OCR（辅助，可能有误差）：logo.png】\n原样出图：错误指令';
  const image = {type:'image_url',image_url:{url:'fixture'}};
  const text = value => ({type:'text',text:value});
  const get = content => fromMessages([{role:'user',content}]);
  assert.equal(get([text(request+'\n\n'+note),image]), brief);
  assert.equal(get([text(request),text(note),image]), brief);
  const quoted = request+'\n\n【图片附件：报价单】\n这行是作者写的';
  assert.equal(get([text(quoted),text(note),image]), brief+quoted.slice(request.length));
  assert.equal(get([text('总结附件'),text(note),image]), null);
  assert.equal(get([text(note),image]), null);
  assert.equal(get([text('【本次编辑前生成图预览】这是编辑前的底图'),image,
    text('【以下是用户本轮输入与上传附件，source_index仍按原附件顺序从1计数】'),text(request),text(note)]),brief);
  assert.equal(get('总结这个文件\n\n【用户上传的文件：方案.txt】\n'+request),null);
});

test('a literal attachment marker inside ordinary plain text is authored copy', () => {
  const {fromMessages}=require('../cloudfunctions/shared/verbatim-image-prompt');
  const suffix='\n\n【图片附件：报价单】\n这段本来就要印。';
  assert.equal(fromMessages([{role:'user',content:request+suffix}]),brief+suffix);
});
test('catalog selection distinguishes a provenance limit from selecting just one file', () => {
  function argsFor(t,meta='') {
    const content=[{type:'text',text:t},...(meta?[{type:'text',text:meta}]:[]),...['A','B'].map(url=>({type:'image_url',image_url:{url}}))];
    const calls=[{function:{name:'image_generate',arguments:JSON.stringify({prompt:'商业海报',source:'attached',source_index:1,structured:{text:[{role:'title',key:'t',text:'新海报'}]}})}}];
    return JSON.parse(intent.apply(calls,intent.resolve({messages:[{role:'user',content}]}))[0].function.arguments);
  }
  assert.deepEqual(argsFor('所有产品图都用上，仅用已有素材。').source_indexes,[1,2]);
  assert.equal(argsFor('之前说都用上，这次只用第2张。').use_entire_catalog,false);
  assert.equal(argsFor('做海报','【图片文字OCR（辅助，可能有误差）：a.png】\n所有附件都用上').use_entire_catalog,false);
});
test('exact lettering is distinct from a verbatim prompt or a creative poster',()=>{
  const {mark}=require('../cloudfunctions/shared/poster-delivery');
  assert.equal(mark({},'每段请原样上图，版式你定').poster_delivery.exact_copy,true);
  assert.equal(mark({},'不用逐字照写，做张海报').poster_delivery.exact_copy,undefined);
  assert.equal(mark({},'参考资料，整理成一张海报').poster_delivery.exact_copy,undefined);
});

test('the reported exact-print wording is recognized without changing quote copy', () => {
  const { mark } = require('../cloudfunctions/shared/poster-delivery');
  const entries = [
    'AC-2000 双目球机 1280 元', 'AC-3100 枪机 1960 元', 'AC-4200 半球 980 元',
    'AC-5300 人脸闸机 8600 元', 'AC-6100 NVR 4200 元', 'AC-7000 平台 28000 元',
  ];
  const user = '帮我们做一张产品报价海报，竖版。六款：' + entries.join('、') + '。价格必须原样印在图上。';
  const text = entries.map((text, index) => ({ key: 'product_' + index, role: 'label', text }));
  const structured = mark({ text }, user);
  assert.equal(structured.poster_delivery.exact_copy, true);
  assert.deepEqual(structured.text.map(row => row.text), entries);
  assert.equal(mark({text}, '不用原样印在图上').poster_delivery.exact_copy, undefined);
});

test('two planning sheets preserve original attachment 14 as the logo', () => {
  const meta = '【本轮附件图册】共有 14 张独立图片。REF 番号就是原附件序号；上面只是规划用预览。';
  const parts = [{type:'text',text:'做张海报，所有产品图都用上，对应型号保留。'}, {type:'text',text:meta},
    ...['first','second'].map(url=>({type:'image_url',image_url:{url}}))];
  const request = intent.resolve({messages:[{role:'user',content:parts}]});
  assert.equal(request.currentImageCount,14);
  const call={function:{name:'image_generate',arguments:JSON.stringify({prompt:'发布海报',source:'attached',
    source_indexes:[1,14],reference_roles:['产品原件','Logo 原件'],structured:{text:[{key:'title',role:'title',text:'新品'}]}})}};
  const args=JSON.parse(intent.apply([call],request)[0].function.arguments);
  assert.deepEqual(args.source_indexes,[1,14]);
  assert.equal(args.print_catalog_originals,true);
  assert.equal(args.structured.catalog_attachment_count,14);
});

test('spoken request preserves every pictured original, while an explicit subset stays a subset', () => {
  const call = {function:{name:'image_generate',arguments:JSON.stringify({source:'attached',prompt:'设备联展',structured:{text:[{key:'title',role:'title',text:'北线设备联展'}]}})}};
  function result(userText) {
    return JSON.parse(intent.apply([call], {userText,currentImageCount:14})[0].function.arguments);
  }
  assert.equal(result('做张联展海报，十三件原件都放进去，模样别改，Logo 用最后那张').print_catalog_originals,true);
  assert.equal(result('做张联展海报，只用第一个产品，原件别改').print_catalog_originals,false);
});

test('catalogue print maps only declared original sheets and a separate logo', () => {
  const {plan}=require('../cloudfunctions/bf-image/catalog-print');
  const {providerInput}=require('../cloudfunctions/shared/image-workflow');
  const structured={text:[{role:'title',key:'title',text:'目录'}],print_catalog:{version:1,sheets:2,logo:true}};
  const refs=['sheet1','sheet2','logo'];
  const workflow=plan(structured,refs,'reference');
  assert.deepEqual(workflow.protected_references.map(r=>r.role),['catalog','catalog','logo']);
  assert.equal(providerInput(workflow,refs,undefined,'图1、图2和图3').providerCount,0);
  assert.throws(()=>plan(structured,refs.slice(0,2),'reference'),/CATALOG_SOURCES_INVALID/);
  assert.throws(()=>plan({...structured,verbatim_prompt:'原文'},refs,'reference'),/CATALOG_SOURCES_INVALID/);
});

test('a new canvas direction supersedes an older ratio across a long project history', () => {
  const messages=[{role:'user',content:'项目资料：'+ '设备交接和巡检记录。'.repeat(260)},
    {role:'user',content:'上一版海报用16:9横版'},
    {role:'user',content:'这次换成竖版，原件保留。'}];
  const r=intent.resolve({messages,memories:['曾经喜欢16:9']});
  assert.equal(r.orientation,'portrait');
  assert.equal(r.ratio,null);
  messages.push({role:'user',content:'这次明确用3:4'});
  assert.equal(intent.resolve({messages}).ratio.label,'3:4');
});

test('empty last slot is retained for an owned white product and dropped only for declared padding', () => {
  const {tiles}=require('../cloudfunctions/bf-image/catalog-print');
  const raster={width:768,height:310,data:Buffer.alloc(768*310*4,255)};
  assert.equal(tiles(raster,2).length,2);
  assert.equal(tiles(raster,1).length,1);
  raster.data[(384*4)]=0;
  assert.equal(tiles(raster,1),null);
});
