"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const { compactConversation, compactionPlan, summaryContent } = require("../cloudfunctions/bf-api/context-compaction");
const { injectAssistantGuidance } = require("../cloudfunctions/bf-api/assistant-guidance");
const { membershipExpired } = require("../cloudfunctions/shared/member-access");
const { modelPreference } = require("../cloudfunctions/shared/image-quality-intent");
const { sanitizeToolCall } = require("../cloudfunctions/shared/image-delivery");
const { autoDecision } = require("../cloudfunctions/bf-image/image-routing");
const { injectCommercialImageGuidance } = require("../cloudfunctions/bf-api/commercial-image-guidance");
const API = fs.readFileSync(require.resolve("../cloudfunctions/bf-api/index.js"), "utf8");
const IMAGE = fs.readFileSync(require.resolve("../cloudfunctions/bf-image/index.js"), "utf8");
function productionFunction(source, name) {
  const start = source.indexOf("async function " + name + "(");
  assert.ok(start >= 0);
  return source.slice(start, source.indexOf("\n}", start) + 2);
}
function history() {
  return [{role:"system",content:"原始规则"}, ...Array.from({length:10}, (_,i) =>
    ({role:i%2?"assistant":"user",content:"历史事实"+i})),
    {role:"assistant",content:null,tool_calls:[{id:"image-call",function:{name:"image_generate",arguments:'{"prompt":"海报"}'}}]},
    {role:"tool",tool_call_id:"image-call",content:"已生成"},
    ...Array.from({length:5},(_,i)=>({role:i%2?"assistant":"user",content:"新任务"+i}))];
}
const options = { threshold:1,keepCount:6,scope:"test-account",cacheGet:async()=>null,cachePut:async()=>{},
  summarize:async()=> "摘要：用户已确认展会海报方向；此前生成了一张，保留准确文案和引用，不编造。" };
test("compaction actually compresses and preserves complete tool turns", async () => {
  const original=history(), saved=JSON.stringify(original);
  const result=await compactConversation(original, options);
  assert.ok(result.length < original.length);
  const calls=new Set(result.flatMap(m=>(m.tool_calls||[]).map(t=>t.id)));
  assert.ok(result.filter(m=>m.role==="tool").every(m=>calls.has(m.tool_call_id)));
  assert.equal(JSON.stringify(original),saved);
  assert.equal(result.at(-1),original.at(-1));
});
test("multimodal text and latest corrections enter summary; pixels do not", () => {
  const content=summaryContent({role:"user",content:[{type:"text",text:"电话更正为139，请保留我的Logo"}, {type:"image_url",image_url:{url:"data:image/png;base64,PRIVATE_PIXELS"}}]});
  assert.match(content,/电话更正为139/);
  assert.doesNotMatch(content,/PRIVATE_PIXELS/);
});
test("summary sees all old text, not a 24000-character prefix", async () => {
  const messages=history(); messages[1].content="头部".repeat(14000); messages[8].content="尾部关键更正标记";
  const plan=compactionPlan(messages,options);
  assert.ok(plan.chunks.join("").includes("尾部关键更正标记"));
  const seen=[];
  await compactConversation(messages,{...options,summarize:async t=>{seen.push(t);return options.summarize();}});
  assert.ok(seen.some(t=>t.includes("尾部关键更正标记")));
});
test("summary failure retains history and is observable; caches are account scoped", async () => {
  const original=history(), events=[],keys=[];
  const result=await compactConversation(original,{...options,summarize:async()=>{throw Error("SECRET")},observe:e=>events.push(e)});
  assert.equal(result,original); assert.equal(events.at(-1).event,"failed");
  assert.doesNotMatch(JSON.stringify(events),/SECRET/);
  for(const scope of ["a","b"]) await compactConversation(original,{...options,scope,cacheGet:async k=>{keys.push(k);return options.summarize();}});
  assert.notEqual(keys[0],keys[1]);
});
test("brand identity replaces only known legacy system paragraphs", () => {
  const old="0. 身份口径铁律：底层由 OpenAI ChatGPT 6.1 驱动";
  const user={role:"user",content:old};
  const messages=[{role:"system",content:old+"\n数据真实性铁律：不得编造"},{role:"system",content:"【身份与表达】底层由 OpenAI 的模型。"},user];
  const out=injectAssistantGuidance(messages);
  assert.ok(out.includes(user));
  assert.ok(out.some(m=>m.content.includes("中防AI专属智能助手")));
  assert.doesNotMatch(out.filter(m=>m.role==="system").map(m=>m.content).join("\n"),/ChatGPT 6\.1|底层由 OpenAI/);
  assert.match(out[0].content,/不得编造/);
  const again=injectAssistantGuidance(out);
  assert.equal(again.filter(m=>m.content.includes("【ASSISTANT_IDENTITY_V2】")).length,1);
});
function authHarness(account) {
  const errors=[];
  const ctx={ensureSecretsForAuth:async()=>true,verifyToken:()=>({t:"member",sub:"test",pwv:0,sv:0}),bearer:()=>"",
    C:{accounts:"accounts"},db:{collection:()=>({doc:()=>({get:async()=>({data:account?[account]:[]})})})},
    membershipExpired,reqStore:{getStore:()=>({})},sendError:(_,status,code)=>{errors.push({status,code});},logSafe:()=>{}};
  return {errors,fn:vm.runInNewContext(productionFunction(API,"requireMember")+"\nrequireMember",ctx)};
}
test("expired members can renew but default paid authentication stays denied",async()=>{
  const h=authHarness({status:"active",expiresAt:"2000-01-01",sv:0,pwv:0});
  assert.equal(await h.fn({},{}),null);
  assert.equal(h.errors[0].code,"MEMBERSHIP_EXPIRED");
  assert.equal((await h.fn({},{},{allowExpired:true})).sub,"test");
  for(const name of ["handlePaymentInfo","handleSelfRenew","handleMe"]) assert.match(productionFunction(API,name),/allowExpired:/);
  for(const name of ["handleChat","handleImage"]) assert.match(productionFunction(API,name),/requireMember\(req, res\)/);
  assert.match(API,/handleMe\(req, res, url.searchParams.get\("require_active"\) === "1"\)/);
});
test("renewal exception does not bypass suspended accounts, password or session versions",async()=>{
  for(const [extra,code] of [[{status:"suspended"},"ACCOUNT_SUSPENDED"],[{sv:1},"SESSION_REPLACED"],[{pwv:1},"UNAUTHORIZED"]]) {
    const h=authHarness({status:"active",expiresAt:"2000-01-01",sv:0,pwv:0,...extra});
    assert.equal(await h.fn({},{},{allowExpired:true}),null);
    assert.equal(h.errors[0].code,code);
  }
});
test("image quota denies expired or missing dates even if old /me returns 200",async()=>{
  for(const memberUntil of ["2000-01-01",null,undefined]) {
    let target;
    const ctx={BF_API_BASE:"https://example.test/api",AbortController,setTimeout,clearTimeout,bearer:()=>"",logStage:()=>{},require:p=> {
      assert.equal(p,"./shared/member-access"); return {membershipExpired};
    },fetch:async url=>{target=url;return {ok:true,json:async()=>({ok:true,memberUntil})};}};
    const fn=vm.runInNewContext(productionFunction(IMAGE,"quotaExhausted")+"\nquotaExhausted",ctx);
    const result=await fn({});
    assert.equal(result.denied,403); assert.equal(result.code,"MEMBERSHIP_EXPIRED");
    assert.match(target,/require_active=1$/);
  }
});
test("image quota still permits active accounts and fails closed on upstream refusal",async()=>{
  for(const status of [200,401,403,503]) {
    const ctx={BF_API_BASE:"https://example.test/api",AbortController,setTimeout,clearTimeout,bearer:()=>"",logStage:()=>{},authSubOf:()=>"test",activeReservedCny:async()=>0,
      require:()=>({membershipExpired}),fetch:async()=>({ok:status===200,status,json:async()=> status===200 ? {ok:true,memberUntil:"2099-01-01",limits:{month:{enabled:true,remainingPct:50}},usage:{pool:{usedCny:5,capCny:10}}}:{error:status===403?"ACCOUNT_SUSPENDED":"UNAUTHORIZED"}})};
    const fn=vm.runInNewContext(productionFunction(IMAGE,"quotaExhausted")+"\nquotaExhausted",ctx);
    const out=await fn({});
    assert.equal(out.exhausted,status!==200);
    if(status===401||status===403) assert.equal(out.denied,status);
    if(status===503) assert.equal(out.unavailable,true);
  }
});
test("expired login succeeds, self-renew remains pending and no automatic grant date when disabled",async()=>{
  const account={_id:"test",status:"active",expiresAt:"2000-01-01",displayName:"test",sv:0,pwv:0};
  const rows=[],responses=[];
  const collection=()=>({where:()=>({limit:()=>({get:async()=>({data:[account]})}),count:async()=>({total:0})}),
    doc:()=>({get:async()=>({data:[account]}),update:async()=>{}}),add:async row=>{rows.push(row);return {id:"request-test"};}});
  const ctx={db:{collection},C:{accounts:"accounts",requests:"requests"},readJsonBody:async()=>({username:"test",password:"test"}),loginLocked:()=>0,verifyPassword:()=>true,
    signToken:()=>"TEST_TOKEN",sendJson:(_,status,body)=>responses.push({status,body}),sendError:()=>{throw Error("unexpected refusal")},
    requireMember:async(_,__,options)=>{assert.equal(options.allowExpired,true);return {sub:"test",sv:0}},TIERS:{},tierDefOf:()=>({key:"plus",priceCny:68}),autoApproveEnabled:()=>false};
  const login=vm.runInNewContext(productionFunction(API,"handleMemberLogin")+"\nhandleMemberLogin",ctx);
  await login({},{});
  assert.equal(responses[0].status,200);
  const renew=vm.runInNewContext(productionFunction(API,"handleSelfRenew")+"\nhandleSelfRenew",ctx);
  await renew({},{});
  assert.equal(rows[0].status,"pending"); assert.equal(rows[0].expiresAt,null);
  assert.equal(responses[1].body.autoApproveAt,null);
});
const policy={honorUserQuality:true,proReasons:["complex_edit","identity_sensitive","detailed_layout"],commercialFinalToPro:true};
function decide(user,prompt,reason="simple_edit") {
  const call={function:{name:"image_edit",arguments:JSON.stringify({prompt,quality_reason:reason})}};
  const args=JSON.parse(sanitizeToolCall(call,user).function.arguments);
  return autoDecision({...args,taskKind:"edit",image:["base","material"]},policy);
}
test("explicit model choice respects negatives, last instruction and user preference over Agent text",()=>{
  assert.equal(modelPreference("不要用Pro，修改海报"),"flash");
  assert.equal(modelPreference("不要Flash"),"pro");
  assert.equal(modelPreference("使用Pro，算了改用Flash"),"flash");
  assert.equal(decide("不要用Pro，改公司海报日期","必须使用Pro修改公司海报").tier,"fast");
  assert.equal(decide("使用Pro，算了改用Flash","精美公司海报").tier,"fast");
});
test("simple date edits stay Flash; identity and poor-quality retries upgrade",()=>{
  assert.equal(decide("只改公司海报日期，其他不动","只改公司海报日期，其他不动").tier,"fast");
  assert.equal(decide("保持我的长相，把第一张的人放到第二张","人物合入底图").tier,"high");
  assert.equal(decide("这张图片太简单，重新设计","重做图片").reason,"auto:quality-retry");
  assert.equal(decide("这张不够真实","重做图片").tier,"high");
  assert.equal(autoDecision({prompt:"公司展会海报用于正式发布",taskKind:"generate"},policy).tier,"high");
});
test("commercial follow-ups retain guidance but unrelated topic resets it",()=>{
  const tools=[{function:{name:"image_generate"}}];
  const base=[{role:"user",content:"制作企业展会海报"},{role:"assistant",content:"请选择方案一或二"}];
  const follow=[...base,{role:"user",content:"1"}];
  assert.notEqual(injectCommercialImageGuidance(follow,tools,"1"),follow);
  const changed=[...base,{role:"user",content:"帮我分析合同"},{role:"assistant",content:"好的"},{role:"user",content:"继续"}];
  assert.equal(injectCommercialImageGuidance(changed,tools,"继续"),changed);
});
