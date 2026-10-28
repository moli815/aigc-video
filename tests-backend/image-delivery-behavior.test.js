const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const d=require('../cloudfunctions/shared/image-delivery');
const p=require('../cloudfunctions/bf-image/image-routing');
const root=path.resolve(__dirname,'..');
const call=args=>({id:'call_a',type:'function',function:{name:'image_generate',arguments:JSON.stringify(args)}});
const argsOf=c=>JSON.parse(c.function.arguments);
const frame=(delta,finish=null)=>'data: '+JSON.stringify({choices:[{index:0,delta,finish_reason:finish}]});
const event=line=>JSON.parse(line.slice(6));
test('legacy client META_RULE cannot suppress new delivery policy',()=>{
 const expert=fs.readFileSync(path.join(root,'BossAI/Models/Expert.swift'),'utf8');
 const input=[{role:'system',content:expert.slice(expert.indexOf('static let metaRule'))}];
 const out=d.injectDeliveryRule(input);assert.equal(out.length,2);assert.ok(out[1].content.includes(d.BOUNDARY_VERSION));assert.equal(d.injectDeliveryRule(out).length,2);
});
test('multiline copy and layout references are cleaned together before local overlay',()=>{
 const out=d.cleanImageRequest({prompt:'新品发布\n数据来源：公开报道',structured:{text:[{key:'title',role:'title',text:'新品发布\n未核实项：内部数据'},{key:'meta',role:'footer',text:'1. 数据来源：公开报道'}],layout:{blocks:[{key:'title'},{key:'meta'}]}}},'做海报');
 assert.equal(out.prompt,'新品发布');assert.deepEqual(out.structured.text,[{key:'title',role:'title',text:'新品发布'}]);assert.deepEqual(out.structured.layout.blocks,[{key:'title'}]);assert.equal(out.removed,3);
});
test('deadlines, disclaimers, product names and explicit provenance remain visible',()=>{
 const text='截至2026年10月28日报名，欢迎参展\n免责声明：投资有风险\n数据来源展示系统\n仅供参考';
 assert.equal(d.cleanImageRequest({prompt:text},'做海报').prompt,text);
 const args=argsOf(d.sanitizeToolCall(call({prompt:'研究海报',structured:{text:[{key:'source',role:'footer',text:'数据来源：用户提供'}]}}),'页脚保留数据来源'));
 assert.equal(d.cleanImageRequest(args).structured.text[0].text,'数据来源：用户提供');
 assert.equal(d.cleanImageRequest({prompt:'新品发布\n数据来源：公开报道'},'不要加数据来源').prompt,'新品发布');
});
test('empty prompt fallback cannot reintroduce structured verification notes',()=>{
 const out=d.cleanImageRequest({prompt:'数据来源：公开报道',structured:{subject:'城市海报',text:[{key:'meta',text:'【未核实项】内部数据'}]}});
 assert.equal(out.prompt,'');assert.equal(out.structured.subject,'城市海报');assert.deepEqual(out.structured.text,[]);
});
test('chat and document tool content is not sanitized',()=>{
 const tool={id:'doc',function:{name:'create_document',arguments:'{"body":"数据来源：公开报道"}'}};
 assert.equal(d.sanitizeToolCall(tool,'生成文档'),tool);
 const data={choices:[{message:{content:'数据来源：公开报道',tool_calls:[tool]}}]};assert.deepEqual(d.sanitizeCompletion(data,'生成文档'),data);
});
test('reversed reference order uses roles instead of ambiguous user numbering',()=>{
 const out=argsOf(d.sanitizeToolCall(call({prompt:'把第一张的人放到第二张图里',source_indexes:[2,1],reference_roles:['底图','人物素材']}),'把第一张的人放到第二张'));
 assert.equal(out.prompt,'把人物素材的人放到底图里');assert.deepEqual(out.source_indexes,[2,1]);
});
test('fragmented SSE tool args are sanitized only after complete JSON',()=>{
 const guard=new d.ToolCallStreamGuard('做海报');
 const args=JSON.stringify({prompt:'新品发布',structured:{text:[{key:'meta',role:'footer',text:'数据来源：公开报道'}]}}),cut=Math.floor(args.length/2);
 const a=guard.pushLine(frame({tool_calls:[{index:0,id:'call_a',function:{name:'image_generate',arguments:args.slice(0,cut)}}]}));assert.ok(!a.includes('数据来源'));
 const b=guard.pushLine(frame({tool_calls:[{index:0,function:{arguments:args.slice(cut)}}]}));assert.ok(!b.includes('数据来源'));
 const c=event(guard.pushLine(frame({},'tool_calls'))).choices[0].delta.tool_calls[0];assert.equal(c.id,'call_a');assert.deepEqual(argsOf(c).structured.text,[]);guard.end();
});
test('interleaved tool indexes and document arguments survive buffering',()=>{
 const guard=new d.ToolCallStreamGuard('做海报和文档');
 guard.pushLine(frame({tool_calls:[{index:1,id:'doc',function:{name:'create_document',arguments:'{"body":"数据来源：公开报道"}'}},{index:0,id:'img',function:{name:'image_generate',arguments:'{"prompt":"新品发布"}'}}]}));
 const calls=event(guard.pushLine(frame({},'tool_calls'))).choices[0].delta.tool_calls;
 assert.equal(calls.find(x=>x.index===1).function.arguments,'{"body":"数据来源：公开报道"}');assert.equal(calls.find(x=>x.index===0).id,'img');
});
test('truncated and malformed image JSON never reaches execution',()=>{
 const guard=new d.ToolCallStreamGuard('做海报');guard.pushLine(frame({tool_calls:[{index:0,function:{name:'image_generate',arguments:'{"prompt":'}}]}));
 assert.throws(()=>guard.end(),/INCOMPLETE/);assert.throws(()=>guard.pushLine(frame({},'tool_calls')));
});
test('natural language streams immediately and DONE flushes complete calls',()=>{
 const guard=new d.ToolCallStreamGuard('做海报');assert.equal(event(guard.pushLine(frame({content:'正在准备'}))).choices[0].delta.content,'正在准备');
 guard.pushLine(frame({tool_calls:[{index:0,id:'a',function:{name:'image_generate',arguments:'{"prompt":"新品发布"}'}}]}));assert.ok(guard.pushLine('data: [DONE]').includes('新品发布'));guard.end();
});
test('ordinary final posters and simple two-image composites stay Flash',()=>{
 for(const taskKind of ['generate','edit','reference']) assert.equal(p.autoDecision({taskKind,qualityTier:'high',prompt:'品牌Logo海报最终稿'}).tier,'fast');
 assert.equal(p.autoDecision({image:['a','b'],structured:{routing:{reason:'simple_edit'}}}).tier,'fast');
});
test('explicit quality, complex editing and quality retry can upgrade to Pro',()=>{
 for(const input of [{prompt:'请使用Pro生成海报'},{structured:{routing:{preference:'pro'}}},{prompt:'上一次结果未通过画质检查'},{image:['a','b'],structured:{routing:{reason:'identity_sensitive'}}},{image:['a','b','c']}]) assert.equal(p.autoDecision(input).tier,'high');
});
test('text overlay avoids unnecessary dense-text Pro upgrade',()=>{
 const structured={text:[{text:'字'.repeat(200)}]};assert.equal(p.autoDecision({structured}).tier,'high');assert.equal(p.autoDecision({structured,textMode:'overlay'}).tier,'fast');
});
test('user dissatisfaction upgrades the next image request without changing the App',()=>{
 const args=argsOf(d.sanitizeToolCall(call({prompt:'重做一版海报'}),'上一张排版不好，重新做'));
 assert.equal(p.autoDecision(args).tier,'high');
 assert.equal(p.autoDecision(args,{retryQualityToPro:false}).tier,'fast');
});
test('runtime JSON changes decisions without rebuilding the App',()=>{
 assert.equal(p.autoDecision({qualityTier:'high'},{honorClientHigh:true}).tier,'high');assert.equal(p.autoDecision({taskKind:'reference'},{proTaskKinds:['reference']}).tier,'high');
 assert.equal(p.autoDecision({}, {defaultTier:'high'}).tier,'high');assert.equal(p.autoDecision({image:['a','b'],structured:{routing:{reason:'identity_sensitive'}}},{proReasons:[]}).tier,'fast');
 assert.equal(p.parseAutoPolicy('{broken').defaultTier,'fast');assert.equal(p.parseAutoPolicy({minReferencesForPro:0}).minReferencesForPro,3);
});
test('only definite capability rejection allows Pro fallback',()=>{
 const input={mode:'auto',selected:'flash',pro:'pro',status:400,body:{error:{code:'ModelNotSupport'}}};assert.equal(p.canFallbackToPro(input),true);
 for(const status of [200,401,403,408,429,500,502,504]) assert.equal(p.canFallbackToPro({...input,status}),false);
 for(const code of ['ContentPolicyViolation','InvalidParameter','UnknownError']) assert.equal(p.canFallbackToPro({...input,body:{error:{code}}}),false);
 assert.equal(p.canFallbackToPro({...input,policy:{capabilityFallback:false}}),false);assert.equal(p.canFallbackToPro({...input,selected:'pro'}),false);
});
test('reference redesign and edit receive compatible multi-image constraints',()=>{
 const src=fs.readFileSync(path.join(root,'cloudfunctions/bf-image/index.js'),'utf8');
 const a=src.indexOf('function multiImageContract'),b=src.indexOf('const REFERENCE_CONSTRAINTS',a);
 const fn=new Function(src.slice(a,b)+';return multiImageContract;')();
 assert.ok(fn(['base','style'],['底图','风格参考'],'reference').includes('必须按新风格重构版式'));
 assert.ok(!fn(['base','style'],['底图','风格参考'],'reference').includes('不重绘整张'));
 assert.ok(fn(['base','person'],['底图','人物素材'],'edit').includes('只修改用户指定区域'));
});
