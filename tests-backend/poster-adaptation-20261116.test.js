"use strict";
const test=require('node:test'),assert=require('node:assert/strict');
const {adaptPosterCanvasCalls}=require('../cloudfunctions/bf-api/poster-canvas-calls');
const {compileDesignBrief}=require('../cloudfunctions/shared/image-design-brief');
const call=(chars,ratio='9:16')=>({id:'unchanged',function:{name:'image_generate',arguments:JSON.stringify({source:'none',aspect_ratio:ratio,structured:{text:Array.from({length:5},(_,i)=>({key:'k'+i,role:i?'body':'title',text:'字'.repeat(chars/5)}))}})}});
const ratio=(c,opts)=>JSON.parse(adaptPosterCanvasCalls([c],{enabled:true,...opts})[0].function.arguments).aspect_ratio;
test('canvas capacity is recalculated after copy review adds required explanation, retaining the tool contract',async()=>{
 const {reviewAndAdaptPosterCalls}=require('../cloudfunctions/bf-api/poster-canvas-calls');let reviewCalls=0;
 const original=call(700,'9:21');assert.equal(ratio(original,{userText:'给伙伴做张海报，比例你定'}),'9:21');
 const actual=await reviewAndAdaptPosterCalls([original],{enabled:true,userText:'给伙伴做张海报，比例你定',review:async calls=>{reviewCalls++;const a=JSON.parse(calls[0].function.arguments);a.structured.text=a.structured.text.map(t=>({...t,text:t.text+'补充说明'.repeat(12)}));return[{...calls[0],function:{...calls[0].function,arguments:JSON.stringify(a)}}];}});
 assert.equal(reviewCalls,1);assert.equal(actual[0].id,original.id);assert.equal(JSON.parse(actual[0].function.arguments).aspect_ratio,'9:32');
 assert.equal(JSON.parse(actual[0].function.arguments).structured.text.length,5);
});
test('post-review sizing never overrules a user-fixed ratio or activates an unrelated account',async()=>{
 const {reviewAndAdaptPosterCalls}=require('../cloudfunctions/bf-api/poster-canvas-calls'),source=[call(1000,'9:16')],review=async x=>x;
 assert.equal((await reviewAndAdaptPosterCalls(source,{review,enabled:false,userText:'做张海报'}))[0],source[0]);
 const a=await reviewAndAdaptPosterCalls(source,{review,enabled:true,userText:'做比例9:16的海报'});assert.equal(JSON.parse(a[0].function.arguments).aspect_ratio,'9:16');
});
test('vague dense poster requests no longer treat every 9:16 as adequate',()=>{
 assert.equal(ratio(call(1000),{userText:'按这些资料做产品长图'}),'9:32');
 assert.equal(ratio(call(650),{userText:'给渠道伙伴做张海报'}),'9:21');
 assert.equal(ratio(call(220),{userText:'给渠道伙伴做张海报'}),'9:16');
 assert.equal(ratio(call(650,'16:9'),{userText:'做横版宣传图'}),'21:9');
 assert.equal(ratio(call(650,'9:21'),{userText:'做张宣传图'}),'9:21');
});
test('explicit, previously established and local-edit canvas choices take precedence',()=>{
 const c=call(1000);
 assert.equal(ratio(c,{userText:'比例9:16的产品长图'}),'9:16');
 assert.equal(ratio(c,{userText:'做16:9的产品长图'}),'16:9');
 assert.equal(ratio(c,{userText:'按之前的做产品长图',messages:[{role:'user',content:'这张海报比例9:16'}]}),'9:16');
 assert.equal(ratio(c,{userText:'做产品长图，比例你定',messages:[{role:'user',content:'以前这张海报比例9:16'}]}),'9:32');
 assert.equal(ratio(c,{userText:'这张海报只改联系方式'}),'9:16');
 for(const name of ['image_edit','image_series']){const x={...c,function:{...c.function,name}};assert.equal(adaptPosterCanvasCalls([x],{enabled:true,userText:'做产品长图'})[0],x);}
 const next=adaptPosterCanvasCalls([c],{enabled:true,userText:'做产品长图'});assert.deepEqual(adaptPosterCanvasCalls(next,{enabled:true,userText:'做产品长图'}),next);
 const a=JSON.parse(c.function.arguments),b=JSON.parse(next[0].function.arguments);delete a.aspect_ratio;delete b.aspect_ratio;assert.deepEqual(a,b);
});
test('selected visual direction survives native visual-map compilation without becoming copy',()=>{
 const items=[{key:'a',role:'title',text:'原始品牌标题'},{key:'b',role:'body',text:'完整能力说明'}];
 const make=visual=>({purpose:'advertisement',audience:'合作商',goal:'说明真实产品',visual_approach:visual,information_density:'balanced',density_source:'context',visual_map:[{form:'主视觉',text_keys:['a'],expression:'标题与产品形成主次'},{form:'文字',text_keys:['b'],expression:'保留能力解释'}]});
 const warm=compileDesignBrief(make('暖红银灰，真实工业摄影、金属材质，常规正文'),{taskKind:'reference',visualExecution:true,items});
 const monochrome=compileDesignBrief(make('黑白杂志摄影，克制用色，充分解释内容'),{taskKind:'reference',visualExecution:true,items});
 assert.match(warm,/暖红银灰/);assert.match(monochrome,/黑白杂志摄影/);assert.doesNotMatch(monochrome,/暖红银灰/);
 for(const p of [warm,monochrome]){assert.match(p,/制作要求，不是画面文字/);for(const i of items)assert.equal(p.split(JSON.stringify(i.text)).length-1,1);}
});

test('legacy JSON and SSE preserve misplaced design metadata, with conflicts rejected',()=>{
 const {sanitizeCompletion,ToolCallStreamGuard}=require('../cloudfunctions/shared/image-delivery');
 const brief={purpose:'advertisement',goal:'解释真实用途',visual_approach:'黑白杂志摄影'};
 const args={prompt:'产品海报',structured:{text:[]},design_brief:brief};
 const call={id:'same-id',function:{name:'image_generate',arguments:JSON.stringify(args)}};
 const data={choices:[{message:{tool_calls:[call]}}]},clean=sanitizeCompletion(data,'做海报'),actual=JSON.parse(clean.choices[0].message.tool_calls[0].function.arguments);
 assert.equal(actual.design_brief,undefined);assert.deepEqual(actual.structured.design_brief,brief);assert.deepEqual(sanitizeCompletion(clean,'做海报'),clean);
 const guard=new ToolCallStreamGuard('做海报');guard.pushLine('data: '+JSON.stringify({choices:[{index:0,delta:{tool_calls:[{...call,index:0}]}}]}));
 const done=guard.pushLine('data: [DONE]');assert.match(done,/黑白杂志摄影/);
 const conflict=structured=>({choices:[{message:{tool_calls:[{...call,function:{...call.function,arguments:JSON.stringify({...args,structured})}}]}}]});
 assert.throws(()=>sanitizeCompletion(conflict({text:[],design_brief:{...brief,visual_approach:'旧红银风格'}}),'做海报'),e=>e.reason==='DESIGN_PATH_CONFLICT');
 assert.doesNotThrow(()=>sanitizeCompletion(conflict({text:[],design_brief:{visual_approach:brief.visual_approach,goal:brief.goal,purpose:brief.purpose}}),'做海报'));
});

test('native image planning can actually read owned account memory without enabling unrelated chat',()=>{
 const {imageAccountContextEnabled}=require('../cloudfunctions/bf-api/account-context');
 const p={nativeCommercial:true,nativeCommercialAccounts:['A']},opts={messages:[],userText:'按之前资料做张产品长图',tools:[{function:{name:'image_generate'}}]};
 assert.equal(imageAccountContextEnabled(p,'A',opts),true);assert.equal(imageAccountContextEnabled(p,'B',opts),true); // explicit recall is account-owned, independent of native canary
 assert.equal(imageAccountContextEnabled(p,'A',{...opts,userText:'写一段广告文案'}),false);
 assert.equal(imageAccountContextEnabled(p,'A',{...opts,tools:[]}),true);
 assert.equal(imageAccountContextEnabled(p,'A',{...opts,tools:{}}),true);
 const {isCommercialTask}=require('../cloudfunctions/bf-api/commercial-image-guidance');
 assert.equal(isCommercialTask([],'重新制作一张黑白摄影的杂志广告'),true);assert.equal(isCommercialTask([],'写一段品牌广告文案'),false);
});
