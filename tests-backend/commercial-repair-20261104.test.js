"use strict";
const test=require("node:test"),assert=require("node:assert/strict");
const {sanitizeToolCall,ToolCallStreamGuard}=require("../cloudfunctions/shared/image-delivery");
const {diagnostic,repairImageCompletion}=require("../cloudfunctions/bf-api/image-tool-repair");
const {userExcerpts,restoreSyncedImageContext,payloadOf,prepareImageContext}=require("../cloudfunctions/bf-api/confirmed-image-context");
const {eligible,policyOf,layoutTree,paletteOf}=require("../cloudfunctions/bf-image/commercial-composer");
const {cases}=require("../tests-fixtures/complex-image-eval-20261104.cjs");
const {validateReview,reviewCommercialCalls,sourceContext}=require("../cloudfunctions/bf-api/commercial-copy-review");
const {createCommercialComposition}=require("../cloudfunctions/bf-image/commercial-composition-runtime");
const {partition}=require("../cloudfunctions/bf-image/commercial-composer");
const call=args=>({id:"c1",type:"function",function:{name:"image_generate",arguments:args}});
test("tool failures classify syntax and malformed copy without disclosing raw payload",()=>{
  for(const [raw,reason,field] of [['{"PRIVATE_DATA"',"JSON_SYNTAX","arguments"],["[]","ARGUMENTS_NOT_OBJECT","arguments"],[JSON.stringify({prompt:"x",structured:{text:[{text:{secret:"value"}}]}}),"TEXT_ENTRY_INVALID","structured.text[0].text"]]){
    assert.throws(()=>sanitizeToolCall(call(raw),"海报"),e=>{assert.deepEqual(diagnostic(e),{reason,field,code:"TOOL_ARGUMENTS_INVALID"});assert.equal(e.message,"TOOL_ARGUMENTS_INVALID");return true;});
  }
  assert.equal(diagnostic({reason:"PRIVATE_DATA",field:"SECRET_FIELD",code:"TOKEN"}).field,"");
});
test("repair is one format-only completion, keeps full source and sanitizes the result",async()=>{
  let count=0;const messages=[{role:"user",content:"热线400-810-2026"}];
  const out=await repairImageCompletion({error:{code:"TOOL_ARGUMENTS_INVALID",reason:"JSON_SYNTAX",field:"arguments"},body:{messages,stream:true,stream_options:{include_usage:true}},
    request:async body=>{count++;assert.equal(body.stream,false);assert.equal(body.stream_options,undefined);assert.equal(body.messages[0],messages[0]);return {choices:[{message:{tool_calls:[call('{"prompt":"hello"}')]}}]};},sanitize:x=>x});
  assert.equal(count,1);assert.equal(out.choices[0].message.tool_calls.length,1);
});
test("failed repair never loops and never retries ownership, incomplete output or released tools",async()=>{
  let count=0;const request=async()=>{count++;throw Error("no");};
  const options={body:{messages:[]},request,sanitize:x=>x};
  for(const error of [{code:"BRAND_PLAN_CONFLICT"},{code:"OUTPUT_LIMIT"},{code:"IMAGE_REFERENCE_NOT_ISSUED"}])assert.equal(await repairImageCompletion({...options,error}),null);
  assert.equal(await repairImageCompletion({...options,released:true,error:{code:"TOOL_ARGUMENTS_INVALID",reason:"JSON_SYNTAX"}}),null);
  assert.equal(count,0);
  assert.equal(await repairImageCompletion({...options,error:{code:"TOOL_ARGUMENTS_INVALID",reason:"JSON_SYNTAX"}}),null);assert.equal(count,1);
});
test("stream guard only marks tools released after full validation",()=>{
  const g=new ToolCallStreamGuard("海报");g.pushLine('data: '+JSON.stringify({choices:[{delta:{tool_calls:[{index:0,...call('{"prompt":"a"}')}]}}]}));
  assert.equal(g.releasedCalls||0,0);g.pushLine('data: '+JSON.stringify({choices:[{finish_reason:"tool_calls",delta:{}}]}));assert.equal(g.releasedCalls,1);
});
test("literal context preserves exact corrected fields and never promotes assistant guesses",()=>{
  const xs=userExcerpts([{role:"user",content:"主标题‘选对巡检方案’；产品云桥巡检平台，热线400-000-1111"},{role:"assistant",content:"最终热线400-999-9999"},{role:"user",content:"最终热线更正为400-810-2026，旧号码作废"}]);
  assert.equal(xs.length,2);assert.ok(xs[0].text.includes("云桥巡检平台"));assert.ok(xs[1].text.includes("400-810-2026"));
  const budgeted=userExcerpts([{role:"user",content:"公司"+"a".repeat(80)},{role:"user",content:"最终热线400-810-2026"}],30);assert.equal(budgeted.length,1);assert.ok(budgeted[0].text.includes("更正")===false);
 const paragraphs=userExcerpts([{role:"user",content:"旧热线400-000-1111\n最终热线更正为400-810-2026"}]);assert.ok(paragraphs[0].text.startsWith("旧"));assert.ok(paragraphs[1].text.startsWith("最终"));
});
const owner="fixture-owner",parent="11111111-2222-4333-8444-555555555555";
function fakeDb(rows,deleted=false){return {collection(){return {where(filter){let result=rows.filter(r=>Object.entries(filter).every(([k,v])=>r[k]===v));return {orderBy(){return this;},limit(n){result=result.slice(0,n);return this;},async get(){return {data:result};}};},doc(){return {async get(){return {data:[{accountId:owner,kind:"conversation",deleted,payload:JSON.stringify({id:parent,isDeleted:deleted})}]};}};}};}};}
test("recover clipped product/title only from a uniquely matched owned conversation",async()=>{
  const source=cases.find(c=>c.id==="B-procurement-matrix").messages;
  const messages=source.slice(4);
  assert.equal(messages.some(m=>m.content.includes("云桥巡检平台")),false);
  const rows=source.filter(m=>m.role==="user").map((m,i)=>({accountId:owner,kind:"message",parentId:parent,refId:String(i),revision:i,payload:JSON.stringify({conversationId:parent,role:"user",text:m.content,createdAt:i})}));
  const out=await restoreSyncedImageContext(messages,{owner,db:fakeDb(rows),enabled:true});
  assert.ok(out.at(-1).content.includes("云桥巡检平台"));assert.ok(out.at(-1).content.includes("选对巡检方案，让投入对应业务阶段"));
  const deleted=await restoreSyncedImageContext(messages,{owner,db:fakeDb(rows,true),enabled:true});assert.ok(!deleted.at(-1).content.includes("云桥巡检平台"));
  assert.equal(payloadOf({...rows[0],accountId:"someone-else"},owner),null);
  const future={accountId:owner,kind:"message",parentId:parent,revision:99,payload:JSON.stringify({conversationId:parent,role:"user",text:"未来公司FAKE_FUTURE，不应进入历史重试",createdAt:999999})};
  const noFuture=await restoreSyncedImageContext(messages,{owner,db:fakeDb([...rows,future]),enabled:true});assert.ok(!noFuture.at(-1).content.includes("FAKE_FUTURE"));
});
test("ambiguous anchor matches do not mix two conversations",async()=>{
  const text="最终公司资料应当保留，且这是同一句足够长的匹配锚点";
  const messages=Array.from({length:30},(_,i)=>({role:i%2?"assistant":"user",content:text+i}));
  const rows=[parent,"22222222-2222-4333-8444-555555555555"].flatMap(id=>messages.filter(m=>m.role==="user").slice(-4).map(m=>({accountId:owner,kind:"message",parentId:id,payload:JSON.stringify({conversationId:id,role:"user",text:m.content})})));
  const out=await restoreSyncedImageContext(messages,{owner,db:fakeDb(rows),enabled:true});assert.ok(!out.at(-1).content.includes("synced_user_same_conversation"));
});
test("restoration runs before compaction can remove the source-match anchors",async()=>{
 const source=cases.find(c=>c.id==="B-procurement-matrix").messages,messages=source.slice(4);
 const rows=source.filter(m=>m.role==="user").map((m,i)=>({accountId:owner,kind:"message",parentId:parent,revision:i,payload:JSON.stringify({conversationId:parent,role:"user",text:m.content,createdAt:i})}));
 const out=await prepareImageContext(messages,{owner,db:fakeDb(rows),enabled:true,compact:async input=>{
  const saved=input.filter(m=>m.role==="system");assert.ok(saved.some(m=>m.content.includes("云桥巡检平台")));return [...saved,...input.filter(m=>m.role==="user").slice(-1)];
 }});assert.ok(out.some(m=>m.role==="system"&&m.content.includes("选对巡检方案，让投入对应业务阶段")));
});
test("composition selection keeps edit, overlay, asset preservation and canary boundaries",()=>{
  const structured={text:Array.from({length:6},(_,i)=>({key:"k"+i,role:"body",text:"正确商业文案".repeat(30)}))};const p=policyOf({enabled:true,accountIds:[owner]});
  const input={accountId:owner,taskKind:"generate",structured};assert.equal(eligible(input,p),true);
  for(const change of [{accountId:"other"},{taskKind:"edit"},{textMode:"overlay"},{layerDecomposition:true},{renderIntent:"mockup"},{structured:{...structured,preserve_assets:[{}]}}])assert.equal(eligible({...input,...change},p),false);
});
test("layout consumes every item once and does not move internal subtitles into the main header",()=>{
  const items=[{key:"t",role:"title",text:"主标题"},{key:"s",role:"subtitle",text:"副标题"},{key:"b",role:"body",text:"第一部分\n正文"},{key:"later",role:"subtitle",text:"后面的栏目"},{key:"b2",role:"body",text:"不能丢的正文"},{key:"phone",role:"contact",text:"400-810-2026"}];
  const out=layoutTree({items,width:1584,height:2816,palette:paletteOf({},"暖色"),fontSize:28});assert.equal(out.consumed.length,items.length);assert.equal(new Set(out.consumed).size,items.length);
});
test("wide linear partition cannot strand a specification-only column",()=>{
 const sections=[31,324,356,345].map((n,i)=>({items:[{key:"s"+i,text:"字".repeat(n)}]}));
 const groups=partition(sections,3);assert.deepEqual(groups.map(g=>g.map(s=>s.items[0].key)),[["s0","s1"],["s2"],["s3"]]);
});
test("copy review cannot lose keys, invent a hotline or modify reference selection",async()=>{
 const items=[{key:"t",role:"title",text:"正式标题"},{key:"b",role:"body",text:"这是不能丢失的完整业务行动。".repeat(50)},{key:"c",role:"contact",text:"400-810-2026"}];
 assert.equal(validateReview(items,{items:[{key:"t",text:"少了一项"}]},[]),null);
 assert.equal(validateReview(items,{items:items.map(t=>({key:t.key,text:t.key==="c"?"400-999-9999":t.text}))},[]),null);
 const input=call(JSON.stringify({prompt:"海报",source:"attached",source_indexes:[2,1],structured:{text:items}}));
 const output=await reviewCommercialCalls([input],{enabled:true,messages:[{role:"user",content:"最终热线400-810-2026"}],request:async()=>({items:items.map(t=>({key:t.key,text:t.text}))})});
 const args=JSON.parse(output[0].function.arguments);assert.deepEqual(args.source_indexes,[2,1]);assert.equal(args.structured.text[2].text,"400-810-2026");
});
test("copy reviewer failure preserves the valid original contract and is observable",async()=>{
 const input=call(JSON.stringify({structured:{text:[{key:"b",role:"body",text:"用户原文".repeat(150)}]}})),events=[];
 const out=await reviewCommercialCalls([input],{enabled:true,messages:[],request:async()=>{throw Error("private upstream contents");},observe:e=>events.push(e)});
 assert.equal(out[0],input);assert.deepEqual(events,[{event:"unavailable",reason:"COPY_REVIEW_UNAVAILABLE_OR_INVALID"}]);
});
test("copy reviewer can still read recovered facts after server date appends to the system message",()=>{
 const {contextMessage}=require("../cloudfunctions/bf-api/confirmed-image-context");
 const m=contextMessage([{origin:"synced_user_same_conversation",text:"主标题：准确产品名"}]);m.content+="\n\n[当前日期：2026年11月4日]";
 assert.ok(sourceContext([m]).some(r=>r.text.includes("准确产品名")));
});
function fakeRenderer(){return {satori:async(tree,options)=>{let n=0;const walk=t=>{if(!t||typeof t!=="object")return;if(t.props?.["data-copy-key"])options.onNodeDetected({left:100,top:100+30*n++,width:300,height:25,props:t.props});for(const c of [].concat(t.props?.children||[]))walk(c);};walk(tree);return "<svg/>";},resvg:{Resvg:class{render(){return {asPng:()=>Buffer.from("fixture-png"),free(){}};}free(){}}}};}
test("font verification precedes rendering and typography fallback archives once for the same owner",async()=>{
 const crypto=require("node:crypto"),bytes=Buffer.from("fixture-font"),sha256=crypto.createHash("sha256").update(bytes).digest("hex");let writes=0;const events=[];
 const runtime=createCommercialComposition({app:{getTempFileURL:async()=>({fileList:[{tempFileURL:"https://fonts.myqcloud.com/font"}]})},
  assetStore:{archive:async(account,png)=>{assert.equal(account,owner);assert.equal(png.toString(),"fixture-png");writes++;return {id:"a".repeat(40)};},sign:async account=>{assert.equal(account,owner);return [{url:"https://result.myqcloud.com/png"}];}},
  fetcher:async url=>{if(url.includes("fonts.myqcloud.com"))return new Response(bytes);throw Error("background unavailable");},log:e=>events.push(e),engines:async()=>fakeRenderer()});
 const input={accountId:owner,taskKind:"generate",resolvedSize:"1584x2816",structured:{text:Array.from({length:5},(_,i)=>({key:"k"+i,role:i?"body":"title",text:"完整文字".repeat(25)}))}};
 const policy={enabled:true,fonts:[400,700].map(weight=>({fileId:"cloud://fixture/font"+weight,sha256,weight}))};
 await assert.rejects(runtime.prepare(input,{...policy,fonts:policy.fonts.map(f=>({...f,sha256:"0".repeat(64)}))}),{code:"COMPOSITION_FONT_HASH_MISMATCH"});
 const ready=await runtime.prepare(input,policy);const result=await runtime.finish(ready,"https://provider.volces.com/fixture",owner);
 assert.equal(writes,1);assert.equal(result.composition.typographyFallback,true);assert.ok(events.some(e=>e.event==="artwork_fallback"));
});
test("valid PNG artwork is accepted with the real media-guard w/h contract",async()=>{
 const {PNG}=require("../cloudfunctions/bf-image/node_modules/pngjs"),crypto=require("node:crypto"),font=Buffer.from("fixture-font"),sha256=crypto.createHash("sha256").update(font).digest("hex");
 const image=PNG.sync.write(new PNG({width:2,height:2}));let writes=0;const events=[];
 const runtime=createCommercialComposition({app:{getTempFileURL:async()=>({fileList:[{tempFileURL:"https://fonts.myqcloud.com/font"}]})},
  assetStore:{archive:async account=>{assert.equal(account,owner);writes++;return {id:String(writes).repeat(40)};},sign:async()=>[{url:"https://result.myqcloud.com/final"}]},
  fetcher:async url=>new Response(url.includes("fonts.myqcloud.com")?font:image),log:e=>events.push(e),engines:async()=>fakeRenderer()});
 const input={accountId:owner,taskKind:"generate",resolvedSize:"1584x2816",structured:{text:Array.from({length:5},(_,i)=>({key:"k"+i,role:i?"body":"title",text:"准确文字".repeat(25)}))}};
 const ready=await runtime.prepare(input,{enabled:true,fonts:[400,700].map(weight=>({fileId:"cloud://fixture/"+weight,sha256,weight}))});
 const out=await runtime.finish(ready,"https://image.volces.com/artwork",owner);assert.equal(out.composition.typographyFallback,false);assert.ok(out.asset.variants.background);assert.equal(writes,2);assert.ok(!events.some(e=>e.event==="artwork_fallback"));
});

test("a grouped multiline comparison becomes real aligned rows without losing its original keys",()=>{
 const {packedMatrix}=require("../cloudfunctions/bf-image/commercial-composer");
 const items=[{key:"title",role:"title",text:"采购决策"},{key:"head",role:"label",text:"八项对照指标｜启航版 · 协同版 · 旗舰版"},{key:"rows",role:"body",text:Array.from({length:8},(_,i)=>"维度"+i+"：甲"+i+"｜乙"+i+"｜丙"+i).join("\n")},{key:"next",role:"body",text:"采购问题与限制"}];
 const matrix=packedMatrix(items);assert.equal(matrix.rows.length,8);assert.deepEqual(matrix.rows[3].cells,["甲3","乙3","丙3"]);
 const layout=layoutTree({items,width:2816,height:1584,palette:paletteOf({},""),fontSize:25,background:"data:image/png;base64,fixture"});assert.deepEqual([...layout.consumed].sort(),items.map(t=>t.key).sort());
 const matrixNodes=[];function walk(n){if(!n||typeof n!=="object")return;if(n.type==="img")matrixNodes.push(n);[].concat(n.props?.children||[]).forEach(walk);}walk(layout.tree);assert.equal(matrixNodes.length,0,"a comparison should not show an irrelevant generated fake table as artwork");
});

test("quota snapshot retries a transport failure once but never retries explicit denial",async()=>{
 const {readQuotaResponse}=require("../cloudfunctions/bf-image/quota-read");let calls=0;
 const r=await readQuotaResponse("https://owned.example/me",{},async()=>{if(++calls===1)throw Error("temporary network");return new Response("ok");});assert.equal(r.status,200);assert.equal(calls,2);
 calls=0;const denied=await readQuotaResponse("https://owned.example/me",{},async()=>{calls++;return new Response("denied",{status:403});});assert.equal(denied.status,403);assert.equal(calls,1);
 calls=0;await assert.rejects(readQuotaResponse("https://owned.example/me",{},async()=>{calls++;throw Error("offline");}));assert.equal(calls,2);
});
test("exact quoted product spelling corrects inserted whitespace without replacing a different model",()=>{
 const {preserveQuotedModels}=require("../cloudfunctions/bf-api/commercial-copy-review");
 const out=preserveQuotedModels([{key:"t",text:"青禾智储 S240 与青禾智储S250，额定240kWh"}],[{role:"user",content:"产品‘青禾智储S240’，额定240kWh"}]);assert.equal(out[0].text,"青禾智储S240 与青禾智储S250，额定240kWh");
});

test("artwork provider compilation excludes visible copy and the full table layout",()=>{
 const {artworkPrompt}=require("../cloudfunctions/bf-image/commercial-artwork");const result=artworkPrompt({artwork_prompt:"园区运营团队在真实设备前协作，写实商业摄影，暖色自然光",text:[{key:"a",text:"400-810-2026"}],composition:"把九行报价表画出来"});assert.ok(result.includes("真实设备"));assert.ok(!result.includes("400-810-2026"));assert.ok(!result.includes("九行报价"));assert.ok(result.includes("不得绘制表格"));
});

test("four-cell pipe headers and separate body rows produce an aligned matrix",()=>{
 const {packedMatrix}=require("../cloudfunctions/bf-image/commercial-composer");
 const items=[{key:"t",role:"title",text:"对照"},{key:"h",role:"label",text:"对照维度 | 甲版 | 乙版 | 丙版"},...Array.from({length:8},(_,i)=>({key:"r"+i,role:"body",text:"指标"+i+" | 10元 | 20元 | 30元"})),{key:"f",role:"contact",text:"热线400-810-2026"}];
 const matrix=packedMatrix(items);assert.equal(matrix.rows.length,8);assert.deepEqual(matrix.rows[0].cells,["10元","20元","30元"]);
 const layout=layoutTree({items,width:2816,height:1584,palette:paletteOf({},""),fontSize:25});assert.deepEqual([...layout.consumed].sort(),items.map(t=>t.key).sort());
});

test("a uniquely paired heading emitted after its body is restored without reordering unrelated sections",()=>{
 const {orderSectionLabels}=require("../cloudfunctions/bf-image/commercial-composer");const items=[{key:"title",role:"title"},{key:"weeks",role:"body"},{key:"weeks_label",role:"label"},{key:"risk_label",role:"label"},{key:"risk",role:"body"},{key:"unrelated",role:"label"}];assert.deepEqual(orderSectionLabels(items).map(t=>t.key),["title","weeks_label","weeks","risk_label","risk","unrelated"]);
});
