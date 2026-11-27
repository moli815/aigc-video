"use strict";
const test = require("node:test"), assert = require("node:assert/strict");
const fs = require("node:fs"), path = require("node:path"), vm = require("node:vm"), {createRequire}=require("node:module"), {EventEmitter}=require("node:events");
const {memoryDatabase}=require("./foundation-fixture");
const {ARBITRATION_BLOCK}=require("../cloudfunctions/bf-api/expert-delivery-arbitration");
async function fixture() {
  const file=path.resolve(__dirname,"../cloudfunctions/bf-api/index.js"), realRequire=createRequire(file), db=memoryDatabase(), calls=[],charges=[];
  let handler;
  const app={database:()=>db};
  const provider=async (_url,options)=>{
    calls.push(JSON.parse(options.body));
    const content=JSON.parse(options.body).response_format?.type==="json_object"?JSON.stringify({answer:"reviewed fixture reply",unsupported_claims:[]}):"fixture reply";
    const response=new Response(JSON.stringify({model:"fixture",choices:[{index:0,message:{role:"assistant",content},finish_reason:"stop"}],usage:{prompt_tokens:5,completion_tokens:2,total_tokens:7}}),{status:200});
    response.modelCallId="fixture-call-"+calls.length;return response;
  };
  const context={require:n=>n==="http"?{createServer(fn){handler=fn;return {listen(){}};}}:
    n==="@cloudbase/node-sdk"?{init:()=>app}:n==="./shared/model-call-ledger"?{createModelCallLedger:()=>({fetch:provider})}:
    n==="./log-safe"?{...realRequire(n),logSafe(){}}:realRequire(n),
    module:{exports:{}},exports:{},process:{env:{CHAT_API_KEY:"fixture-only"},on(){}},Buffer,URL,Response,AbortController,AbortSignal,TextDecoder,
    setTimeout,clearTimeout,setInterval,clearInterval,console:{log(){},error(){}},fetch:provider,__charges:charges};
  vm.createContext(context);
  vm.runInContext(fs.readFileSync(file,"utf8")+`
    requireMember=async()=>({sub:'fixture-owner',pwv:0,sv:0});readJsonBody=async(req)=>req.body;
    refreshRuntime=async()=>{};rateLimited=()=>'';ensurePeriod=async(acc)=>acc;customExpertContext=async()=>'';addChatCost=async(id,cost,meta)=>{__charges.push({id,cost,meta});};
    globalThis.__subject={runtime:RUNTIME};`,context);
  await db.collection("bf_accounts").doc("fixture-owner").set({status:"active",tier:"ultra",expiresAt:new Date(Date.now()+86400000),quotaOverrideCny:100,chatUsedCny:0,imageUsedCny:0});
  async function request(route,body) {
    const req=Object.assign(new EventEmitter(),{url:route,method:body?"POST":"GET",headers:{},body});
    let status,out,text="";
    const res=Object.assign(new EventEmitter(),{writableEnded:false,setHeader(){},writeHead(code){status=code;},write(chunk){text+=chunk;},end(chunk){text+=chunk||"";this.writableEnded=true;try{out=JSON.parse(text);}catch{}}});
    await handler(req,res);
    return {status,body:out,text};
  }
  return {request,calls,charges,rt:context.__subject.runtime,db};
}
test("real server chat handler preserves tool names across 16 experts, search modes, permissions and arbitration", async()=>{
  const f=await fixture(), experts=require("../cloudfunctions/bf-api/experts.json").experts;
  let count=0;
  for(const expert of experts)for(const native of [false,true])for(const restricted of [false,true])for(const enabled of [false,true]){
    const names=["expert_skill","recall_history"];
    if(!restricted&&expert.tools.includes("image"))names.push("image_generate","image_edit","image_series");
    if(!restricted&&expert.tools.some(t=>["word","ppt","excel","pdf"].includes(t)))names.push("create_document");
    const tools=names.map(name=>({type:"function",function:{name,parameters:{type:"object",properties:{}}}}));
    if(expert.tools.includes("search"))tools.push(native?{type:"builtin_function",function:{name:"$web_search"}}:{type:"function",function:{name:"web_search",parameters:{type:"object",properties:{query:{type:"string"}}}}});
    f.rt.CHAT_DELIVERY_ARBITRATION=JSON.stringify({enabled,audience:"accounts",accountIds:["fixture-owner"]});
    const input=[{role:"system",content:expert.role+"\n【必须遵循的工作流】\n"+expert.steps.join("\n")},
      {role:"user",content:`只回复回归编号${count++}。提到标记${ARBITRATION_BLOCK.split("\n")[0]}是普通引用。`}];
    const result=await f.request("/api/chat",{stream:false,chatMode:"standard",max_tokens:500,tools,messages:input});
    assert.equal(result.status,200,JSON.stringify(result.body));
    assert.equal(result.body.choices[0].message.content,"fixture reply");
    const sent=f.calls.at(-1);
    assert.deepEqual(Array.from(sent.tools,t=>t.function?.name),tools.map(t=>t.function?.name));
    assert.equal(sent.messages.some(m=>m.role==="system"&&m.content.includes(ARBITRATION_BLOCK)),enabled);
    assert.equal(sent.messages.find(m=>m.role==="user").content,input[1].content);
  }
  assert.equal(count,128);
  assert.equal(f.calls.length,128);
});
test("real /me handler emits disabled tools and white-label entitlement without changing the account", async()=>{
  const f=await fixture();
  f.rt.CAPABILITY_OVERRIDES='{"image_series":{"enabled":false}}'; f.rt.CAPABILITY_EXTRA="fixture boundary";
  for(const [tier,brand]of [["plus",""],["pro",""],["ultra","测试品牌"]]){
    await f.db.collection("bf_accounts").doc("fixture-owner").update({tier,brandName:"测试品牌"});
    const result=await f.request("/api/me");
    assert.equal(result.status,200);
    assert.deepEqual(result.body.capabilityOverrides,{image_series:{enabled:false}});
    assert.equal(result.body.capabilityExtra,"fixture boundary");
    assert.equal(result.body.appName,brand);
  }
});
test("v2 style actually reaches the chat handler only for its account and leaves tools and business facts intact",async()=>{
 const f=await fixture(),experts=require("../cloudfunctions/bf-api/experts.json").experts;
 const {VERSION}=require("../cloudfunctions/bf-api/response-behavior");
 for(const expert of experts)for(const selected of [false,true]){
  f.rt.CHAT_STYLE_POLICY=JSON.stringify({enabled:true,profile:"task_v2",audience:"accounts",accountIds:[selected?"fixture-owner":"other-owner"]});
  const tools=[{type:"function",function:{name:"expert_skill",parameters:{type:"object",properties:{}}}}];
  const system=expert.role+"\n【必须遵循的工作流】\n"+expert.steps.join("\n")+"\n【可执行技能契约 v1：专家】\n执行步骤：保留专业方法\n交付章节：默认章节\n边界：不得保证收益。企业事实：甲公司。";
  const result=await f.request("/api/chat",{stream:false,chatMode:"standard",max_tokens:500,tools,messages:[{role:"system",content:system},{role:"user",content:`样例${expert.id}-${selected}，只回复编号。`}]});
  assert.equal(result.status,200,JSON.stringify(result.body));
  const sent=f.calls.at(-1);assert.equal(sent.messages.some(m=>m.role==="system"&&m.content.includes(VERSION)),selected);
  const expertSystem=sent.messages.find(m=>m.role==="system"&&m.content.includes("企业事实：甲公司"));
  assert.ok(expertSystem);
  assert.equal(expertSystem.content.includes("【必须遵循的工作流】"),!selected);
  assert.match(expertSystem.content,/不得保证收益。企业事实：甲公司。/);
  assert.deepEqual(Array.from(sent.tools,t=>t.function?.name),["expert_skill"]);
 }
});
test("v2 conversation style is bypassed for internal and utility requests",async()=>{
 const f=await fixture(),{VERSION}=require("../cloudfunctions/bf-api/response-behavior");
 f.rt.CHAT_STYLE_POLICY=JSON.stringify({enabled:true,profile:"task_v2",audience:"all"});
 for(const extra of [{internal:true},{tier:"utility"}]){
  const result=await f.request("/api/chat",{stream:false,chatMode:"standard",max_tokens:500,messages:[{role:"system",content:"【必须遵循的工作流】输出内部JSON。"},{role:"user",content:JSON.stringify(extra)}],...extra});
  assert.equal(result.status,200,JSON.stringify(result.body));
  assert.equal(f.calls.at(-1).messages.some(m=>m.role==="system"&&m.content.includes(VERSION)),false);
 }
});
test("reviewed JSON and SSE use two recorded calls and release only the reviewed answer",async()=>{
 const f=await fixture();f.rt.CHAT_STYLE_POLICY=JSON.stringify({enabled:true,profile:"task_v2",audience:"all"});
 f.rt.CHAT_GROUNDED_REVIEW=JSON.stringify({enabled:true,audience:"all",includeBusinessAdvice:true});
 for(const stream of [false,true]){
  const before=f.calls.length,costBefore=f.charges.length;
  const result=await f.request("/api/chat",{stream,chatMode:"standard",max_tokens:1600,messages:[{role:"user",content:"公司提供设备联网服务，请写一段纯口播。"}]});
  assert.equal(result.status,200,JSON.stringify(result));assert.equal(f.calls.length-before,2);assert.equal(f.charges.length-costBefore,2);
  if(stream){
   const content=result.text.split("\n").filter(l=>l.startsWith("data: ")&&l!=="data: [DONE]").map(l=>JSON.parse(l.slice(6)).choices?.[0]?.delta?.content||"").join("");
   assert.equal(content,"reviewed fixture reply");assert.match(result.text,/data: \[DONE\]/);
  }else assert.equal(result.body.choices[0].message.content,"reviewed fixture reply");
  assert.notEqual(f.charges.at(-1).meta.modelCallId,f.charges.at(-2).meta.modelCallId);
 }
});
test("thinking review is used only for business advice, not routine copy",async()=>{
 const f=await fixture();f.rt.CHAT_GROUNDED_REVIEW=JSON.stringify({enabled:true,audience:"all",includeBusinessAdvice:true,reasonBusinessAdvice:true});
 for(const [text,thinking]of [["写一段设备联网业务口播。",false],["预算1000元，是否值得重做展会物料？",true]]){
  const result=await f.request("/api/chat",{stream:false,chatMode:"standard",max_tokens:1600,messages:[{role:"user",content:text}]});
  assert.equal(result.status,200,JSON.stringify(result));assert.equal(f.calls.at(-1).enable_thinking,thinking);
 }
});
test("long-form writing retains its original provider token limit with review enabled",async()=>{
 const f=await fixture(),limits=[];
 for(const enabled of [false,true]){
  f.rt.CHAT_GROUNDED_REVIEW=JSON.stringify({enabled,audience:"all",includeBusinessAdvice:true,maxGenerationTokens:1000});
  const before=f.calls.length;
  const result=await f.request("/api/chat",{stream:false,chatMode:"standard",max_tokens:6000,messages:[{role:"user",content:"写一篇2000字的公众号宣传文案，编号"+enabled}]});
  assert.equal(result.status,200);assert.equal(f.calls.length-before,1);limits.push(f.calls.at(-1).max_tokens);
 }
 assert.equal(limits[0],limits[1]);assert.ok(limits[1]>1000);
});
test("utility JSON defaults to no thinking and preserves an explicit caller choice",async()=>{
 const f=await fixture();
 for(const [extra,expected]of [[{},false],[{enable_thinking:true},true],[{enable_thinking:false},false]]){
  const result=await f.request("/api/chat",{tier:"utility",internal:true,stream:false,max_tokens:300,response_format:{type:"json_object"},messages:[{role:"user",content:'只输出JSON：{"topic":"展会"}'}],...extra});
  assert.equal(result.status,200);assert.equal(f.calls.at(-1).enable_thinking,expected);
 }
});

test("real /chat request after single image delivery cannot dispatch another image", async () => {
  const f = await fixture();
  const tools = ["image_generate", "image_edit", "create_document"].map(name => ({
    type: "function", function: {name, parameters: {type:"object", properties:{}}}
  }));
  const messages = [
    {role:"user", content:"根据今天的AI热点新闻做一个海报"},
    {role:"assistant", content:null, tool_calls:[{id:"first",type:"function",function:{
      name:"image_generate",arguments:'{"prompt":"海报"}'
    }}]},
    {role:"tool",tool_call_id:"first",content:"图片生成已完成并展示给用户。给用户的回复控制在一句话内。"},
  ];
  assert.equal((await f.request("/api/chat",{stream:false,chatMode:"standard",tools,messages})).status,200);
  assert.deepEqual(f.calls.at(-1).tools.map(t=>t.function.name), ["create_document"]);
  messages.push({role:"user",content:"换个视觉风格再做一张海报"});
  assert.equal((await f.request("/api/chat",{stream:false,chatMode:"standard",tools,messages})).status,200);
  assert.equal(f.calls.at(-1).tools[0].function.name,"image_generate");
});
