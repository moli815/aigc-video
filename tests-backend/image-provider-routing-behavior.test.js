const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const {createRequire}=require('node:module');
const file=path.resolve(__dirname,'../cloudfunctions/bf-image/index.js');
function harness(responses, policy) {
 const source=fs.readFileSync(file,'utf8'),localRequire=createRequire(file),calls=[];
 const context={require:name=>name==='http'?{createServer:()=>({listen(){}})}:name==='@cloudbase/node-sdk'?{}:localRequire(name),module:{exports:{}},exports:{},process:{env:{}},Buffer,URL,AbortController,setTimeout,clearTimeout,console:{log(){}},fetch:async(url,opts)=>{
  calls.push(JSON.parse(opts.body));const response=responses.shift();if(response instanceof Error)throw response;return {ok:response.status===200,status:response.status,json:async()=>response.body};
 }};
 vm.createContext(context);vm.runInContext(source+'\nglobalThis.subject={generate,selectImageRoute,RT};',context);
 Object.assign(context.subject.RT,{IMAGE_API_KEY:'test-placeholder',IMAGE_MODEL_FAST:'doubao-seedream-5-0-flash-260915',IMAGE_MODEL_PRO:'doubao-seedream-5-0-pro-260628',IMAGE_ROUTING_MODE:'auto'});
 if (policy) context.subject.RT.IMAGE_AUTO_POLICY=JSON.stringify(policy);
 return {subject:context.subject,calls};
}
const success=()=>({status:200,body:{data:[{url:'https://example.com/result.png'}]}});

test('balanced policy actually compiles user quality to Pro without changing size or text mode',async()=>{
 const h=harness([success()],require('../config/image-auto-quality-balanced.json'));
 const out=await h.subject.generate({prompt:'消防主题专业海报',qualityTier:'high',taskKind:'generate',size:'1536x1536',structured:{routing:{user_quality:'high'}},textMode:'overlay'});
 assert.equal(out.ok,true);assert.match(h.calls[0].model,/-pro-/);assert.equal(h.calls[0].size,'1536x1536');assert.match(out.routeReason,/user-quality/);
});
test('balanced policy keeps simple reference edits Flash while detailed layouts go Pro',async()=>{
 const h=harness([success(),success()],require('../config/image-auto-quality-balanced.json'));
 await h.subject.generate({prompt:'只改颜色',image:['https://example.com/base.png'],qualityTier:'high',taskKind:'edit',size:'1536x1536',structured:{routing:{user_quality:'auto',reason:'simple_edit'}}});
 await h.subject.generate({prompt:'复杂信息布局',qualityTier:'high',taskKind:'generate',size:'1536x1536',structured:{routing:{user_quality:'auto',reason:'detailed_layout'}}});
 assert.match(h.calls[0].model,/flash/);assert.match(h.calls[1].model,/-pro-/);
});
test('real provider compilation uses Flash despite legacy high, preserves explicit copy, removes system notes',async()=>{
 const h=harness([success()]);const out=await h.subject.generate({prompt:'新品发布\n数据来源：公开报道',qualityTier:'high',taskKind:'generate',size:'1536x1536',structured:{text:[{text:'截至2026年10月28日报名'},{text:'未核实项：内部数据'}]}});
 assert.equal(out.ok,true);assert.match(out.model,/flash/);assert.equal(h.calls.length,1);assert.ok(h.calls[0].prompt.includes('新品发布'));assert.ok(h.calls[0].prompt.includes('截至2026年10月28日报名'));assert.ok(!h.calls[0].prompt.includes('数据来源'));assert.ok(!h.calls[0].prompt.includes('未核实'));
});
test('plain natural language without structured fields remains the provider prompt',async()=>{
 const h=harness([success()]);const prompt='红色消防车，浅米白色背景，现代平面插画';
 await h.subject.generate({prompt,size:'1536x1536'});assert.equal(h.calls[0].prompt,prompt);
});
test('provider structured fallback never restores removed notes',async()=>{
 const h=harness([success()]);await h.subject.generate({prompt:'数据来源：公开报道',size:'1536x1536',structured:{subject:'城市海报',text:[{text:'未核实项：内部数据'}]}});
 assert.ok(h.calls[0].prompt.includes('城市海报'));assert.ok(!h.calls[0].prompt.includes('未核实'));
});
test('definite capability failure upgrades once and reports actual model',async()=>{
 const h=harness([{status:400,body:{error:{code:'ModelNotSupport'}}},success()]);const out=await h.subject.generate({prompt:'城市插画',size:'1536x1536'});
 assert.equal(out.ok,true);assert.equal(h.calls.length,2);assert.match(h.calls[0].model,/flash/);assert.match(h.calls[1].model,/-pro-/);assert.equal(out.model,h.calls[1].model);
});
for(const status of [429,500,504]) test('uncertain or rate-limited provider outcome never triggers Pro: '+status,async()=>{
 const h=harness([{status,body:{error:{code:'ModelNotSupport'}}}]);const out=await h.subject.generate({prompt:'城市插画',size:'1536x1536'});assert.equal(out.ok,false);assert.equal(h.calls.length,1);
});
test('multi-reference redesign retains all images without contradicting local-edit constraints',async()=>{
 const h=harness([success()]);await h.subject.generate({prompt:'重新设计，改成暖色动漫风',image:['https://example.com/base.png','https://example.com/style.png'],referenceRoles:['底图','风格参考'],taskKind:'reference',size:'1536x1536'});
 assert.equal(h.calls[0].image.length,2);assert.ok(h.calls[0].prompt.includes('必须重新设计整张作品'));assert.ok(!h.calls[0].prompt.includes('不重绘整张'));
});
