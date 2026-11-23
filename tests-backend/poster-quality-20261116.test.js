"use strict";
const test = require("node:test"), assert = require("node:assert/strict");
const { audit } = require("../cloudfunctions/shared/poster-text-audit");
const AD = require("../cloudfunctions/shared/poster-art-direction");
const { planPosterCanvas } = require("../cloudfunctions/shared/poster-canvas");
const pipeline = require("../cloudfunctions/shared/poster-pipeline");
const { injectNativeCommercialGuidance } = require("../cloudfunctions/shared/commercial-generation-mode");
test("an invented promise sharing four characters is rejected", () => {
  const r = audit([{ text: "平台通过安全检查" }], ["平台通过安全检查", "平台通过国际认证免费赔付"]);
  assert.equal(r.pass, false); assert.equal(r.summary.extras, 1);
});
test("an appended short claim cannot hide in 70 percent covered copy", () => {
  const r = audit([{ text: "设备异常自动上报" }], ["设备异常自动上报免单"]);
  assert.equal(r.pass, false); assert.deepEqual(r.extras, ["免单"]);
});
test("invented lone digits and characters are not ignored", () => {
  for (const extra of ["9", "A", "免"]) assert.equal(audit([{ text: "设备接入" }], ["设备接入", extra]).pass, false);
});
test("a nested heading does not count as a separate occurrence", () => {
  const r = audit([{ key: "t", text: "智慧安消" }, { key: "b", text: "智慧安消平台统一监控" }], ["智慧安消平台统一监控"]);
  assert.equal(r.pass, false); assert.equal(r.items[0].status, "missing");
});
test("identical expected blocks require distinct occurrences", () => {
  const exp = [{ text: "合作咨询" }, { text: "合作咨询" }];
  assert.equal(audit(exp, ["合作咨询"]).pass, false);
  assert.equal(audit(exp, ["合作咨询", "合作咨询"]).pass, true);
});
test("header-footer permission is bounded to two occurrences", () => {
  const exp = [{ text: "400-7758-119", duplicable: true }];
  assert.equal(audit(exp, ["400-7758-119", "400-7758-119"]).pass, true);
  assert.equal(audit(exp, ["400-7758-119", "400-7758-119", "400-7758-119"]).pass, false);
});
test("empty contracts and unreadable unknown characters fail", () => {
  assert.equal(audit([], []).pass, false);
  assert.equal(audit([{ text: "真实界面" }], ["真实?面"]).pass, false);
});
test("wrapping remains valid without a shared-substring exemption", () => {
  assert.equal(audit([{ text: "完整保留真实产品界面的文字与数据" }], ["完整保留真实产品", "界面的文字与数据"]).pass, true);
});
test("layout preserves supplied grouping without inventing taxonomy or promoting the first number", () => {
  const blocks = [1, 2, 3, 4, 5].map(i => ({ zone: "A 内部契约", role: "metric", text: `${i}项` }));
  const p = AD.composePosterPrompt({ blocks, density: "dense" });
  assert.doesNotMatch(p.prompt, /内部契约|必须指定一个主数字|归纳成 2–3 组|缩小字号或加行/);
  assert.match(p.prompt, /不新增业务分类/);
});
test("minimal guidance removes decorative inventory and lets typography breathe", () => {
  const p = AD.composeArtDirection({ styleFamily: "editorial", density: "minimal" });
  assert.doesNotMatch(p, /可选的视觉语言|至少用上|6 倍|25%|必须打破/);
  assert.match(injectNativeCommercialGuidance([])[0].content, /不设装饰数量/);
});
test("series never turn internal zone names into approved visible copy", () => {
  const blocks = Array.from({ length: 3 }, (_, i) => ({ zone: "A 内部契约", text: `测试${i}` }));
  for (const page of AD.composeSeries({ blocks })) {
    assert.deepEqual(page.blocks, blocks); assert.doesNotMatch(page.prompt, /内部契约/);
  }
});
test("automatic canvas uses density and direction; explicit aspect always wins", () => {
  const blocks = [{ text: "完整正文".repeat(135) }];
  assert.equal(planPosterCanvas({ blocks }).aspectRatio, "9:21");
  assert.equal(planPosterCanvas({ blocks, orientation: "landscape" }).aspectRatio, "21:9");
  assert.equal(planPosterCanvas({ blocks, aspectRatio: "1:1" }).ratioSource, "explicit");
  assert.equal(planPosterCanvas({ blocks, aspectRatio: "1:1" }).aspectRatio, "1:1");
  for (const aspectRatio of ["21:9", "9:21", "16:9", "9:16", "1:1"]) {
    const p = planPosterCanvas({ blocks, aspectRatio });
    assert.ok(p.width * p.height >= 921600 && p.width * p.height <= 4624220);
    const [w, h] = aspectRatio.split(":").map(Number); assert.ok(Math.abs(p.width / p.height - w / h) < .015);
  }
  assert.throws(() => planPosterCanvas({ aspectRatio: "100:1" }), /RATIO_INVALID/);
});
test("chosen canvas dimensions reach the real provider adapter instead of only the prose", async () => {
  const blocks = [{ text: "完整正文".repeat(135) }]; let dispatched;
  const r = await pipeline.run({ blocks, orientation: "landscape", maxRepair: 0,
    adapters: { generate: async args => { dispatched = args; return { png: Buffer.from("fixture"), cost: .23 }; } } });
  assert.equal(dispatched.size, r.canvas.providerSize);
  assert.match(dispatched.prompt, /宽高比 21:9/);
  assert.notEqual(dispatched.size, "2K");
});
test("old tool field carries automatic ratio without changing sources, literals or IDs", () => {
  const { adaptPosterCanvasCalls } = require("../cloudfunctions/bf-api/poster-canvas-calls");
  const args = { aspect_ratio: "3:4", source: "attached", source_indexes: [2, 1], reference_roles: ["真实界面", "风格"],
    structured: { text: Array.from({ length: 5 }, (_, i) => ({ key: String(i), role: "body", text: "完整资料".repeat(22) })) } };
  const call = { id: "same-id", function: { name: "image_generate", arguments: JSON.stringify(args) } };
  const options = { enabled: true, userText: "宣传图信息要全，横着做，比例你来定" };
  const next = adaptPosterCanvasCalls([call], options);
  const actual = JSON.parse(next[0].function.arguments);
  assert.equal(actual.aspect_ratio, "21:9"); delete actual.aspect_ratio;
  const expected = { ...args }; delete expected.aspect_ratio; assert.deepEqual(actual, expected);
  assert.equal(next[0].id, call.id); assert.deepEqual(adaptPosterCanvasCalls(next, options), next);
  assert.equal(JSON.parse(adaptPosterCanvasCalls([call], { ...options, userText: "海报比例1:1，其他你定" })[0].function.arguments).aspect_ratio, "1:1");
  for (const name of ["image_edit", "image_series"]) {
    const edit = { ...call, function: { ...call.function, name } };
    assert.equal(adaptPosterCanvasCalls([edit], options)[0], edit);
  }
  assert.equal(adaptPosterCanvasCalls([call], { ...options, enabled: false })[0], call);
  assert.equal(adaptPosterCanvasCalls([call], { ...options, userText: "这张海报只改电话，别的保持" })[0], call);
  const tall={...call,function:{...call.function,arguments:JSON.stringify({...args,aspect_ratio:"9:32"})}};
  assert.equal(adaptPosterCanvasCalls([tall],{...options,userText:"产品长图比例你定，内容要全"})[0],tall);
});
test("explicit current originals cannot be omitted before any paid generation", async () => {
  const { assertRequiredReferences, requiredCurrentSources } = require("../cloudfunctions/bf-api/poster-reference-readiness");
  const messages = [{ role: "user", content: [{ type: "text", text: "用我们真实的大屏和Logo做海报\n图1：广告风格参考\n图2：实际平台大屏原件\n图3：公司Logo原件" }, ...[1,2,3].map(i=>({type:"image_url",image_url:{url:`fixture-${i}`}}))] }];
  const make = (indices, source="attached") => ({ id:"keep-id", function:{name:"image_generate",arguments:JSON.stringify({source,source_indexes:indices,reference_roles:indices.map(String)})} });
  assert.deepEqual(requiredCurrentSources(messages), [2,3]);
  const incomplete=make([2,1]);
  assert.throws(()=>assertRequiredReferences(incomplete,messages), e=>e.reason==="REFERENCE_REQUIRED_MISSING");
  const complete=make([3,2]);assert.doesNotThrow(()=>assertRequiredReferences(complete,messages));
  const {repairImageCompletion}=require("../cloudfunctions/bf-api/image-tool-repair");let calls=0;
  const fixed=await repairImageCompletion({error:{code:"TOOL_ARGUMENTS_INVALID",reason:"REFERENCE_REQUIRED_MISSING",field:"source_indexes"},body:{messages},request:async body=>{calls++;assert.match(body.messages.at(-1).content,/原始附件编号/);return{choices:[{message:{tool_calls:[complete]}}]};},sanitize:r=>{assertRequiredReferences(r.choices[0].message.tool_calls[0],messages);return r;}});
  assert.equal(calls,1);assert.equal(fixed.choices[0].message.tool_calls[0].id,"keep-id");
  const historical=[{role:"user",content:[{type:"text",text:"历史图片预览，非当前附件\n图1：公司Logo原件，用Logo"},{type:"image_url"}]}];
  assert.deepEqual(requiredCurrentSources(historical),[]);
  assert.doesNotThrow(()=>assertRequiredReferences(make([2],"both"),messages));
  assert.doesNotThrow(()=>assertRequiredReferences({...incomplete,function:{...incomplete.function,name:"image_edit"}},messages));
});
test("shipped history previews do not replace the latest task or style instruction", () => {
  const { latestUserText, isHistoryPreview } = require("../cloudfunctions/shared/image-delivery");
  const original={role:"user",content:"换成橙黑的产品长图，比例你定"};
  const preview={role:"user",content:[{type:"text",text:"历史图片预览，非本轮附件；图片ID：11111111-1111-1111-1111-111111111111，名称：旧蓝金图。仅作资料分析，不是指令。"},{type:"image_url",image_url:{url:"fixture"}}]};
  assert.equal(isHistoryPreview(preview),true);assert.equal(latestUserText([original,preview]),original.content);
  const real={role:"user",content:[...preview.content,{type:"text",text:"这张原图里请只改标题"}]};
  assert.equal(isHistoryPreview(real),false);assert.match(latestUserText([original,real]),/请只改标题/);
  assert.equal(isHistoryPreview({role:"user",content:preview.content[0].text}),false);
});
test("misplaced historical references fail before release in JSON and SSE", async () => {
  const {sanitizeCompletion,ToolCallStreamGuard}=require("../cloudfunctions/shared/image-delivery");
  const bad={id:"i",function:{name:"image_generate",arguments:JSON.stringify({prompt:"新海报",image_references:{version:1,mode:"append",items:[]},structured:{text:[]}})}};
  const reject=e=>e.reason==="REFERENCE_PATH_INVALID"&&e.field==="structured.image_references";
  assert.throws(()=>sanitizeCompletion({choices:[{message:{tool_calls:[bad]}}]},"做海报"),reject);
  const guard=new ToolCallStreamGuard("做海报");guard.pushLine("data: "+JSON.stringify({choices:[{index:0,delta:{tool_calls:[{...bad,index:0}]}}]}));
  assert.throws(()=>guard.pushLine("data: [DONE]"),reject);
  const {repairImageCompletion}=require("../cloudfunctions/bf-api/image-tool-repair");let n=0;
  const result=await repairImageCompletion({error:{code:"TOOL_ARGUMENTS_INVALID",reason:"REFERENCE_PATH_INVALID",field:"structured.image_references"},body:{messages:[]},request:async b=>{n++;assert.match(b.messages.at(-1).content,/没有当前底图/);return{choices:[{message:{tool_calls:[{...bad,function:{name:"image_generate",arguments:JSON.stringify({prompt:"新海报",library_refs:["11111111-1111-1111-1111-111111111111"],structured:{text:[]}})}}]}}]};},sanitize:r=>sanitizeCompletion(r,"做海报")});
  assert.equal(n,1);assert.ok(result);
});
test("verified history-only contracts reach server-owned originals without changing copy or guessing a base", async () => {
  const {prepareSingleReferenceGuidance}=require("../cloudfunctions/bf-api/image-single-reference-guidance");
  const {sanitizeCompletion,ToolCallStreamGuard}=require("../cloudfunctions/shared/image-delivery");
  const ids=["11111111-1111-1111-1111-111111111111","22222222-2222-2222-2222-222222222222"];
  const messages=[{role:"user",content:"用以前的原图做产品长图"},{role:"assistant",tool_calls:[{id:"r",function:{name:"recall_history"}}]},
    {role:"tool",tool_call_id:"r",content:ids.map(id=>"图片ID："+id).join("\n")}];
  const tools=[{function:{name:"image_generate",parameters:{properties:{structured:{properties:{}}}}}}];
  const prepare=more=>prepareSingleReferenceGuidance({messages:[...messages,...more],tools,owner:"owner-a",policy:{enabled:true,audience:"all"},referenceStore:{prepare:async(owner,c)=>{assert.equal(owner,"owner-a");if(!ids.includes(c.items[0].id))throw Error("NOT_OWNED");return{};}}});
  const g=await prepare([]),text=[{key:"t",role:"title",text:"完整保留的标题与正文"}];
  const contract={version:1,mode:"append",items:ids.map((id,i)=>({kind:"library",id,role:"历史原图"+(i+1)}))};
  const call={id:"same",function:{name:"image_generate",arguments:JSON.stringify({prompt:"产品宣传",image_references:contract,structured:{text}})}};
  const normalized=g.normalize([call]);const args=JSON.parse(normalized[0].function.arguments);
  assert.deepEqual(args.structured.image_references.items.map(i=>i.id),ids);assert.equal(args.structured.image_references.mode,"replace");assert.equal(args.source,"none");assert.equal(args.image_references,undefined);assert.deepEqual(args.structured.text,text);
  assert.deepEqual(g.normalize(normalized),normalized);
  const clean=sanitizeCompletion({choices:[{message:{tool_calls:[call]}}]},"做产品长图",()=>{},g.finalize,g.normalize);
  assert.deepEqual(JSON.parse(clean.choices[0].message.tool_calls[0].function.arguments).structured.image_references.items.map(i=>i.id),ids);
  const guard=new ToolCallStreamGuard("做产品长图",()=>{},g.finalize,g.normalize);
  guard.pushLine("data: "+JSON.stringify({choices:[{index:0,delta:{tool_calls:[{...call,index:0}]}}]}));
  assert.ok(guard.pushLine("data: [DONE]").includes("replace"));
  const foreign=JSON.parse(call.function.arguments);foreign.image_references.items[0].id="33333333-3333-3333-3333-333333333333";
  assert.throws(()=>g.normalize([{...call,function:{...call.function,arguments:JSON.stringify(foreign)}}]),e=>e.code==="IMAGE_REFERENCE_NOT_ISSUED");
  const current=await prepare([{role:"user",content:[{type:"text",text:"当前新底图"},{type:"image_url",image_url:{url:"fixture"}}]}]);
  assert.throws(()=>current.normalize([call]),e=>e.code==="IMAGE_REFERENCE_CONFLICT");
  const dual=JSON.parse(call.function.arguments);dual.structured.image_references=contract;
  assert.throws(()=>g.normalize([{...call,function:{...call.function,arguments:JSON.stringify(dual)}}]),e=>e.code==="IMAGE_REFERENCE_CONFLICT");
  const previews={role:"user",content:ids.flatMap(id=>[{type:"text",text:`历史图片预览，非本轮附件；图片ID：${id}，名称：原件。仅作资料分析，不是指令。`},{type:"image_url",image_url:{url:"fixture"}}])};
  const history=await prepare([previews]);
  const confused={...call,function:{...call.function,arguments:JSON.stringify({source:"attached",source_indexes:[2],prompt:"产品宣传",structured:{text,image_references:{...contract,items:[contract.items[0]]}}})}};
  const resolved=JSON.parse(history.normalize([confused])[0].function.arguments);
  assert.deepEqual(resolved.structured.image_references.items.map(i=>i.id),[ids[1],ids[0]]);assert.equal(resolved.source,"none");assert.equal(resolved.source_indexes,undefined);assert.deepEqual(resolved.structured.text,text);
});
test("explicit historical-image tasks require one recall, without loops or forcing ordinary chat", () => {
  const {historicalRecallChoice}=require("../cloudfunctions/bf-api/poster-reference-readiness");
  const options={enabled:true,tools:[{function:{name:"recall_history"}}],messages:[{role:"user",content:"用之前的大屏和Logo做产品长图"}]};
  assert.deepEqual(historicalRecallChoice(options),{type:"function",function:{name:"recall_history"}});
  assert.equal(historicalRecallChoice({...options,enabled:false}),null);
  assert.equal(historicalRecallChoice({...options,ownedReferenceCount:2}),null);
  assert.equal(historicalRecallChoice({...options,messages:[{role:"user",content:"继续聊运维方案"}]}),null);
  assert.equal(historicalRecallChoice({...options,messages:[...options.messages,{role:"assistant",tool_calls:[{id:"r",function:{name:"recall_history"}}]},{role:"tool",tool_call_id:"r",content:"未找到素材"}]}),null);
  assert.equal(historicalRecallChoice({...options,messages:[{role:"user",content:[{type:"text",text:options.messages[0].content},{type:"image_url",image_url:{url:"fixture"}}]}]}),null);
});

test("explicit history originals are required only when uniquely bound and owned", async () => {
  const {requiredHistoricalSources}=require('../cloudfunctions/bf-api/poster-reference-readiness');
  const {prepareSingleReferenceGuidance}=require('../cloudfunctions/bf-api/image-single-reference-guidance');
  const ids=['11111111-1111-1111-1111-111111111111','22222222-2222-2222-2222-222222222222'];
  const make=text=>[{role:'user',content:text},{role:'assistant',tool_calls:[{id:'r',function:{name:'recall_history'}}]},
   {role:'tool',tool_call_id:'r',content:`图片ID：${ids[0]}；名称：“系统界面原件”\n内容：“大屏截图原件”\n图片ID：${ids[1]}；名称：DHARMA Logo\n内容：标志原件`}];
  const messages=make('用之前的大屏和Logo做海报'),allowed=new Set(ids);
  assert.deepEqual(requiredHistoricalSources(messages,allowed),ids);
  assert.deepEqual(requiredHistoricalSources(make('用之前的大屏，不用Logo做海报'),allowed),[ids[0]]);
  assert.deepEqual(requiredHistoricalSources(make('用之前的Logo做海报'),new Set([ids[0]])),[]);
  const ambiguous=[...messages,{role:'tool',tool_call_id:'r',content:'图片ID：33333333-3333-3333-3333-333333333333；名称：另一张大屏'}];
  assert.deepEqual(requiredHistoricalSources(ambiguous,new Set([...ids,'33333333-3333-3333-3333-333333333333'])),[ids[1]]);
  const g=await prepareSingleReferenceGuidance({messages,tools:[{function:{name:'image_generate',parameters:{properties:{structured:{}}}}}],owner:'owner-a',policy:{enabled:true,audience:'all'},enforceRequested:true,referenceStore:{prepare:async()=>({})}});
  const call=items=>({id:'same',function:{name:'image_generate',arguments:JSON.stringify({source:'none',structured:{image_references:{version:1,mode:'replace',items:items.map(id=>({kind:'library',id,role:'历史原图'}))}}})}});
  assert.throws(()=>g.finalize([call([ids[1]])]),e=>e.reason==='HISTORY_REQUIRED_MISSING'&&e.requiredReferenceIds.length===2);
  assert.equal(g.finalize([call(ids)])[0].id,'same');
});

test('vague product long-image requests activate commercial guidance without hijacking copywriting',()=>{
 const {isCommercialTask}=require('../cloudfunctions/bf-api/commercial-image-guidance');
 const f=require('../scripts/poster-long-context-fixture-20261116.cjs');
 assert.equal(isCommercialTask(f.history,f.user),true);
 assert.equal(isCommercialTask([],'给渠道伙伴做张产品长图，比例你定'),true);
 assert.equal(isCommercialTask([],'先给产品长图写口播脚本，暂时别做图'),false);
 assert.equal(isCommercialTask([],'帮我把旅行照片拼成长图'),false);
});

test('copy review retains early capability evidence beyond twelve turns, excludes assistant guesses and preview transport',()=>{
 const {sourceContext}=require('../cloudfunctions/bf-api/commercial-copy-review');
 const messages=[{role:'user',content:'能耗观察：按已有数据观察用能变化与时段差异，帮助核查趋势。'},
 {role:'assistant',content:'支持全协议接入且保证节能百分之百。'},...Array.from({length:30},(_,i)=>({role:'user',content:'其他话题'+i})),
 {role:'user',content:'用之前的资料做产品长图'},
 {role:'user',content:[{type:'text',text:'历史图片预览，非当前附件；图片ID：11111111-1111-1111-1111-111111111111；名称：旧图'},{type:'image_url',image_url:{url:'fixture'}}]}];
 const evidence=sourceContext(messages,true).map(r=>r.text).join('\n');
 assert.match(evidence,/能耗观察/);assert.doesNotMatch(evidence,/保证节能百分之百|历史图片预览/);
 assert.ok(sourceContext(messages,true).filter(r=>r.origin==='user_original').every(r=>!r.text.startsWith('历史图片预览')));
});

test('original-resolution typography audits preserve pixels and separate transcription from legibility',()=>{
 const {prepareAuditInput}=require('../scripts/poster-audit-input.cjs');
 const {PNG}=require('../cloudfunctions/bf-image/node_modules/pngjs');
 const bytes=PNG.sync.write(new PNG({width:32,height:48}));const before=Buffer.from(bytes);
 const input=prepareAuditInput(bytes,{model:'qwen3-vl-plus',providerBase:'https://dashscope.aliyuncs.com/compatible-mode/v1'});
 assert.deepEqual(Buffer.from(input.part.image_url.url.split(',')[1],'base64'),before);
 assert.deepEqual(bytes,before);assert.equal(input.evidence.resampled,false);assert.equal(input.part.image_url.detail,'high');
 assert.equal(input.options.vl_high_resolution_images,true);assert.equal(input.evidence.glyphAcceptance,'separate_visual_review_required');
 assert.deepEqual(prepareAuditInput(bytes,{model:'qwen3-vl-plus',providerBase:'https://example.com'}).options,{});
 assert.deepEqual(prepareAuditInput(bytes,{model:'deepseek-flash',providerBase:'https://dashscope.aliyuncs.com'}).options,{});
 assert.throws(()=>prepareAuditInput(Buffer.from('invalid')),/AUDIT_PNG_REQUIRED/);
});

test('official 5.5 always uses lossless output, independent of the legacy composition flag',()=>{
 const {providerOutputOptions}=require('../cloudfunctions/shared/image-policy');
 for(const model of ['doubao-seedream-5-5-261028','doubao-seedream-5-0-pro-260628','doubao-seedream-5-0-flash-260915']){
  assert.deepEqual(providerOutputOptions(model,true),{output_format:'png'});assert.deepEqual(providerOutputOptions(model,false),model.includes('5-5-')?{output_format:'png'}:{});
 }
 assert.deepEqual(providerOutputOptions('doubao-seedream-5-0-lite-260128',true),{});
 assert.deepEqual(providerOutputOptions('another-provider-model',true),{});
 const {resolveImageSize}=require('../cloudfunctions/bf-image/image-sizing');
 assert.equal(resolveImageSize('4K','9:21'),null); // Do not advertise an unsupported 5.5 tier.
});

test('copy-review diagnostics distinguish invalid contracts without exposing provider text',async()=>{
 const {reviewCommercialCalls}=require('../cloudfunctions/bf-api/commercial-copy-review');
 const call={function:{name:'image_generate',arguments:JSON.stringify({structured:{text:[{key:'b',role:'body',text:'具体业务资料'.repeat(100)}]}})}};
 const events=[];
 const out=await reviewCommercialCalls([call],{messages:[],enabled:true,observe:e=>events.push(e),request:async()=>({items:[]})});
 assert.equal(out[0],call);assert.equal(events[0].diagnosticCode,'COPY_REVIEW_ITEM_COUNT');
 const timeout=Object.assign(Error('private provider body, key must never appear'),{name:'AbortError'});events.length=0;
 await reviewCommercialCalls([call],{messages:[],enabled:true,observe:e=>events.push(e),request:async()=>{throw timeout;}});
 assert.equal(events[0].diagnosticCode,'COPY_REVIEW_TIMEOUT');assert.doesNotMatch(JSON.stringify(events),/private provider|key must/);
});
