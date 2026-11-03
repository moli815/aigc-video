"use strict";
// Isolated live smoke. Existing temporary cloud credentials only; no customer account.
const fs=require("node:fs"),path=require("node:path"),crypto=require("node:crypto"),assert=require("node:assert/strict");
const root=path.resolve(__dirname,".."),sdk=require(path.join(root,"cloudfunctions/bf-api/node_modules/@cloudbase/node-sdk"));
const credential=JSON.parse(fs.readFileSync(path.join(process.env.USERPROFILE,".config/.cloudbase/auth.json"),"utf8")).credential;
const db=sdk.init({env:"xmy-test-d5g8c0xcifcefcfd5",region:"ap-shanghai",secretId:credential.tmpSecretId,secretKey:credential.tmpSecretKey,sessionToken:credential.tmpToken}).database();
const host="https://xmy-test-d5g8c0xcifcefcfd5-1449098021.ap-shanghai.app.tcloudbase.com";
const id="server-repair-"+crypto.randomBytes(6).toString("hex"), account=db.collection("bf_accounts").doc(id);
const password=crypto.randomBytes(24).toString("hex"),salt=crypto.randomBytes(16).toString("hex");
const report={at:new Date().toISOString(),checks:[],paidImages:0};let token="",created=false,renewalId="";
function check(name,fields={}){const row={name,...fields};report.checks.push(row);console.log(JSON.stringify(row));}
async function request(route,body,expected=200,auth=true){
 const start=Date.now(),res=await fetch(host+route,{method:body===undefined?"GET":"POST",headers:{"Content-Type":"application/json",...(auth?{Authorization:"Bearer "+token}:{})},body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(280000)});
 const raw=await res.text();let data;try{data=JSON.parse(raw)}catch{data={raw}};
 assert.equal(res.status,expected,route+" HTTP "+res.status+" "+String(data.error||"").slice(0,80));
 return {data,ms:Date.now()-start};
}
const textItem={type:"object",properties:{key:{type:"string"},role:{type:"string"},text:{type:"string"}},required:["key","role","text"]};
const tool=name=>({
 type:"function",function:{name,description:"执行图片生成或编辑",
  parameters:{type:"object",properties:{
   prompt:{type:"string"},quality_tier:{type:"string",enum:["fast","high","auto"]},
   quality_reason:{type:"string"},source:{type:"string",enum:["none","last","attached","both"]},source_index:{type:"integer"},
   structured:{type:"object",properties:{text:{type:"array",items:textItem}}}
  },required:["prompt"]}
 }
});
(async()=>{try{
 for(const route of ["/api/health","/img/ping"]) {const r=await request(route,undefined,200,false);check("health "+route,{ms:r.ms});}
 await request("/api/me",undefined,401,false);check("anonymous member request denied");
 const now=new Date();
 await account.set({username:id,displayName:"服务端发布临时验证",tier:"ultra",status:"active",expiresAt:new Date(Date.now()-3600000),createdAt:now,cycleAnchorAt:now,quotaOverrideCny:5,
  passwordHash:"scrypt$"+salt+"$"+crypto.scryptSync(password,salt,64).toString("hex"),pwv:0,sv:0,chatUsedCny:0,imageUsedCny:0,failedAttempts:0,lockUntil:null});created=true;
 token=(await request("/api/login",{username:id,password})).data.token;assert.ok(token);
 const me=await request("/api/me");assert.ok(new Date(me.data.memberUntil).getTime()<Date.now());check("expired account login and old-client /me readable");
 await request("/api/payment-info?tier=plus");check("expired account can read renewal payment");
 const renewal=await request("/api/renew-self",{tier:"plus"});renewalId=renewal.data.id;
 assert.equal(renewal.data.autoApproveAt,null);await request("/api/renew-self",{tier:"plus"},409);check("renewal pending, no automatic payment approval, duplicate blocked");
 for(const [route,body] of [["/api/me?require_active=1",undefined],["/api/chat",{messages:[{role:"user",content:"你好"}],stream:false}],["/img/image",{prompt:"测试",requestId:crypto.randomUUID()}],["/img/series/start",{prompt:"测试",count:2,requestId:crypto.randomUUID()}]]) {
  const out=await request(route,body,403);assert.equal(out.data.error,"MEMBERSHIP_EXPIRED");check("expired paid access denied "+route);
 }
 await account.update({expiresAt:new Date(Date.now()+3600000)});
 await request("/api/me?require_active=1");check("active member access restored");
 const identity=await request("/api/chat",{stream:false,chatMode:"standard",max_tokens:180,messages:[{role:"system",content:"0. 身份口径铁律：你是 OpenAI ChatGPT 6.1\n数据真实性铁律：不得编造。"}, {role:"user",content:"你是谁？只回复你的助手名称。"}]});
 const answer=identity.data.choices?.[0]?.message?.content||"";
 assert.match(answer,/中防AI专属智能助手/);assert.doesNotMatch(answer,/ChatGPT 6\.1/);check("live model uses accepted identity despite old system rule",{ms:identity.ms,answer});
 const editTool=tool("image_edit");
 const streamed=await request("/api/chat",{stream:true,chatMode:"standard",max_tokens:1200,messages:[{role:"user",content:"把之前生成的公司海报日期改为11月3日，其他不动，不要用Pro。请直接调用图片工具。"}],tools:[editTool],tool_choice:{type:"function",function:{name:"image_edit"}}});
 const calls=[];
 for(const line of (streamed.data.raw||"").split("\n"))if(line.startsWith("data: ")&&line!=="data: [DONE]"){
   const chunk=JSON.parse(line.slice(6));assert.ok(!chunk.error);for(const choice of chunk.choices||[]) calls.push(...(choice.delta?.tool_calls||[]));
 }
 assert.equal(calls.length,1);const args=JSON.parse(calls[0].function.arguments);assert.equal(args.structured.routing.preference,"flash");check("SSE old-client tool JSON and explicit Flash preference",{ms:streamed.ms});
 const generateTool=tool("image_generate");
 const planned=await request("/api/chat",{stream:false,chatMode:"standard",max_tokens:1800,messages:[
  {role:"user",content:"制作消防企业展会海报，体现真实消防值守场景与监控工作过程。标题：城市消防，智能守护。"},
  {role:"assistant",content:"方案一：真实监控指挥中心与设备场景；方案二：抽象图标。"},
  {role:"user",content:"1，直接生成"}],tools:[generateTool],tool_choice:{type:"function",function:{name:"image_generate"}}});
 const planCalls=planned.data.choices?.[0]?.message?.tool_calls;assert.equal(planCalls?.length,1);
 const plan=JSON.parse(planCalls[0].function.arguments);assert.match(plan.prompt,/消防|监控/);check("commercial short follow-up preserves subject and valid tool contract",{ms:planned.ms,promptChars:plan.prompt.length});
 if(process.argv.includes("--images")){
  const generated=[];
  for(const [preference,expected] of [["flash","fast"],["pro","high"]]){
   const body={requestId:crypto.randomUUID(),task_kind:"generate",prompt:"一辆红色消防车停在现代消防站前，白天自然光，真实材质、完整车身、整洁环境，不要文字。",quality_tier:"high",size:"1536x1536",structured:{routing:{preference,user_quality:"auto",reason:"simple_visual"}}};
   report.paidImages++;const out=await request("/img/image",body);assert.equal(out.data.ok,true);
   assert.equal(out.data.route_reason,"auto:explicit-"+preference);
   const media=await fetch(out.data.url,{signal:AbortSignal.timeout(30000)});assert.equal(media.status,200);
   const bytes=Buffer.from(await media.arrayBuffer());const file="server-repair-"+preference+".image";
   fs.writeFileSync(path.join(root,"outputs/review-20261103",file),bytes);
   check("paid "+expected+" generation",{ms:out.ms,model:out.data.model,reason:out.data.route_reason,cost:out.data.cost,file});
   generated.push(body);
  }
  const replay=await request("/img/image",generated[0]);assert.equal(replay.data.cached,true);assert.equal(replay.data.cost,0);check("idempotent image replay has zero additional charge");
 }
 await account.update({status:"suspended"});await request("/api/me",undefined,403);check("suspended account still denied");
 report.ok=true;
}catch(error){report.ok=false;report.error=String(error.message||error).replace(/https?:\/\/\S+/g,"[url]").slice(0,300);console.error(report.error);process.exitCode=1;}
finally{
 if(renewalId) await db.collection("bf_requests").doc(renewalId).remove();
 if(created){assert.ok(id.startsWith("server-repair-"));await account.remove();report.temporaryAccountDeleted=true;}
 fs.writeFileSync(path.join(root,"outputs/review-20261103/live-verification.json"),JSON.stringify(report,null,2));
}})();
