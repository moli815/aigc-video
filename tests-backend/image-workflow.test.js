"use strict";
const test=require("node:test"),assert=require("node:assert/strict");
const w=require("../cloudfunctions/shared/image-workflow");
const policy={workflowVersion:2,workflowAccountIds:["a"]};
const plan=(patch={})=>({version:2,intent:"product_reference",typography:"native",visual_style:"commercial_launch",reference_count:1,protected_references:[{index:1,role:"ui"}],...patch});
const input=(p=plan(),extra={})=>({structured:{image_plan:p},image:["owned-reference"],taskKind:"reference",policy,owner:"a",...extra});
test("workflow rollout is account scoped and never enables malformed scope",()=>{
 for(const p of [null,"bad",{},[],{workflowVersion:1},{workflowVersion:2,workflowAccountIds:null},{workflowVersion:2,workflowAccountIds:["b"]}])assert.equal(w.enabled(p,"a"),false);
 assert.equal(w.enabled(policy,"a"),true);assert.equal(w.enabled({workflowVersion:2},"a"),true);assert.equal(w.enabled({workflowVersion:2},""),false);
 // A canary must never scope off the existing accurate-text renderer.
 const old={enabled:true,minChars:420,accountIds:["customer"],workflowVersion:2,workflowAccountIds:["a"]};
 assert.equal(w.enabled(old,"customer"),false);assert.equal(require("../cloudfunctions/bf-image/commercial-composer").policyOf(old).accountIds[0],"customer");
});
test("legacy requests and unselected accounts retain old pipeline",()=>{
 assert.equal(w.compile(input(undefined,{structured:{}})),null);assert.equal(w.compile(input(plan(),{owner:"b"})),null);
});
test("UI reference protects actual slots without ordering a complete redesign",()=>{
 const p=w.compile(input());assert.equal(p.protectUI,true);assert.equal(p.native,true);
 const c=w.constraints(p);assert.match(c,/图1=ui/);assert.match(c,/导航/);assert.doesNotMatch(c,/必须重新设计整张作品|不得绘制.*界面/);
});
test("missing, duplicated or out-of-range references fail before provider",()=>{
 for(const p of [plan({reference_count:2}),plan({reference_count:0}),plan({protected_references:[]}),plan({protected_references:[{index:2,role:"ui"}]}),plan({protected_references:[{index:1,role:"ui"},{index:1,role:"logo"}]})])assert.throws(()=>w.compile(input(p)),/IMAGE_PLAN_/);
});
test("no arbitrary code, unknown schema field or opaque plan can be executed",()=>{
 for(const p of [null,[],"foo",plan({script:"fetch(secret)"}),plan({visual_style:"javascript"}),plan({protected_references:[{index:1,role:"ui",url:"https://other-account"}]})])assert.throws(()=>w.compile(input(p)),/IMAGE_PLAN_/);
});
test("existing client exact logo compositor is never run twice",()=>{
 const p=plan({intent:"local_edit",protected_references:[{index:1,role:"logo"}]});
 assert.equal(w.compile(input(p,{taskKind:"edit",structured:{image_plan:p,preserve_assets:[{reference_index:2}]}})),null);
});
test("native and client overlay conflicts are rejected; local edit requires image",()=>{
 assert.throws(()=>w.compile(input(plan(),{textMode:"overlay"})),/TEXT_CONFLICT/);
 assert.throws(()=>w.compile(input(plan({intent:"local_edit"}))),/IMAGE_PLAN_INVALID/);
});
test("workflow guidance is idempotent and leaves user/tool materials untouched",()=>{
 const m=[{role:"user",content:"逐字原文"},{role:"tool",content:"asset-owner-evidence"}],t=[{function:{name:"image_generate"}}];
 const injected=w.inject(m,t,policy,"a");assert.equal(injected[0],m[0]);assert.equal(injected[1],m[1]);assert.equal(m.length,2);assert.equal(w.inject(injected,t,policy,"a"),injected);
});
test("workflow schema adds one structured plan without requiring independent photography",()=>{
 const {withImageToolSchema}=require("../cloudfunctions/bf-api/image-tool-schema");
 const t=[{function:{name:"image_generate",parameters:{properties:{structured:{type:"object",properties:{}}}}}}];
 const s=withImageToolSchema(t,{commercial:true,workflow:true})[0].function.parameters.properties.structured;
 assert.ok(s.properties.image_plan);assert.ok(s.required.includes("image_plan"));assert.ok(!s.properties.design_plan);assert.ok(!s.required.includes("artwork_prompt"));assert.ok(s.properties.text);
 const legacy=withImageToolSchema(t,{commercial:true})[0].function.parameters.properties.structured;
 assert.ok(legacy.required.includes("artwork_prompt"));
});
test("exact server logos are excluded intentionally, other source slots are rebound without being dropped",()=>{
 const p=plan({reference_count:3,protected_references:[{index:1,role:"logo"},{index:2,role:"ui"}]}),input=w.providerInput({...p,native:true},["logo","screen","person"],["Logo","界面","人物"],"图1Logo、图2大屏、图3人物、图12无关数字");
 assert.deepEqual(input.image,["screen","person"]);assert.deepEqual(input.referenceRoles,["界面","人物"]);assert.equal(input.originalCount,3);assert.equal(input.providerCount,2);assert.match(input.prompt,/服务器保管的Logo原件Logo、图1大屏、图2人物、图12/);assert.doesNotMatch(w.constraints({...p,native:true},input),/图1=logo/);
});
test("portrait visual contract does not impose a commercial title or contact",()=>{
 const p=w.compile(input(plan({intent:"visual",reference_count:0,protected_references:[]}),{image:[],taskKind:"generate"}));
 assert.match(w.constraints(p),/不添加任何标题、姓名/);assert.doesNotMatch(w.constraints(p),/设计完整商业成品/);
});
test("workflow canary configuration cannot turn off customers' existing typography scope",()=>{
 const {validateValue}=require("../cloudfunctions/bf-api/settings-schema"),spec={type:"json",label:"test"};
 assert.equal(validateValue("IMAGE_COMPOSITION_POLICY",{enabled:true,workflowVersion:2,workflowAccountIds:["test"]},spec).ok,true);
 for(const v of [null,"a",[null],Array(101).fill("a")])assert.equal(validateValue("IMAGE_COMPOSITION_POLICY",{workflowVersion:2,workflowAccountIds:v},spec).ok,false);
 assert.equal(validateValue("IMAGE_COMPOSITION_POLICY",{enabled:true},spec).ok,true);
});
test("real generate compiles native UI without legacy redesign, strips no assets and bypasses fixed typography",async()=>{
 const fs=require("fs"),vm=require("vm"),source=fs.readFileSync(require.resolve("../cloudfunctions/bf-image/index.js"),"utf8");
 const constants=source.slice(source.indexOf("const REFERENCE_CONSTRAINTS"),source.indexOf("function readBody"));
 const fn=source.slice(source.indexOf("async function generate("),source.indexOf("// ── HTTP 服务"));
 let sent,prepareCount=0,protectedPrepare=0,protectedFinish=0;
 const ctx={require:n=>n==="./shared/image-workflow"?w:n==="./shared/image-design-brief"?{compileDesignBrief:()=>"",compileNativeCopy:()=>""}:require("module").createRequire(require.resolve("../cloudfunctions/bf-image/index.js"))(n),
 RT:{IMAGE_API_KEY:"test",IMAGE_COMPOSITION_POLICY:policy,IMAGE_ROUTING_MODE:"pro_only"},normalizeTier:x=>x||"auto",selectImageRoute:()=>({model:"pro",reason:"test"}),capsOf:()=>({edit:true,fastPromptMode:true}),logStage:()=>{},cleanImageRequest:x=>({...x,removed:0}),
 reqStore:{getStore:()=>({memberAuthorization:"Bearer test"})},protectedAssetCompositionOf:()=>({prepare:async()=>{protectedPrepare++;return {test:true};},finish:async()=>{protectedFinish++;return {url:"https://test.invalid/final.png",protection:{version:1}};}}),
 commercialCompositionOf:()=>({prepare:async()=>{prepareCount++;return null;}}),assembleStructured:()=>"",visibleCopyValues:()=>[],RENDER_INTENT_RULES:{},EDIT_CONSTRAINTS:"EDIT",resolveSize:()=>"1536x1536",providerPromptOptions:()=>({mode:"standard"}),multiImageContract:()=>"",
 IMAGE_BASE:"https://test.invalid",modelLedger:{fetch:async(url,opts)=>{sent=JSON.parse(opts.body);return{ok:true,status:200,json:async()=>({data:[{url:"https://test.invalid/out.png"}]})}}},fetch:()=>{},AbortController,setTimeout,clearTimeout};
 vm.createContext(ctx);vm.runInContext(constants+fn+";this.run=generate",ctx);
 const result=await ctx.run({prompt:"制作真实产品海报",image:["original-ui"],structured:{image_plan:plan()},taskKind:"reference",accountId:"a"});
 assert.equal(result.ok,true);assert.equal(prepareCount,0);assert.equal(protectedPrepare,1);assert.equal(protectedFinish,1);assert.equal(result.url,"https://test.invalid/final.png");assert.deepEqual(sent.image,["original-ui"]);assert.match(sent.prompt,/真实UI/);assert.doesNotMatch(sent.prompt,/必须重新设计整张作品|画面内不得出现任何文字|仅绘制物理场景/);
 const rejected=await ctx.run({prompt:"test",image:[],structured:{image_plan:plan()},taskKind:"reference",accountId:"a"});assert.equal(rejected.code,422);
});
