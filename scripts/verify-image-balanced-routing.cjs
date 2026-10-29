// Old-client JSON/SSE and paid image canary. Synthetic assets, isolated temporary account.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'..'), sdk=require(path.join(root,'cloudfunctions/bf-api/node_modules/@cloudbase/node-sdk'));
const credential=JSON.parse(fs.readFileSync(path.join(process.env.USERPROFILE,'.config/.cloudbase/auth.json'),'utf8')).credential;
const db=sdk.init({env:'xmy-test-d5g8c0xcifcefcfd5',region:'ap-shanghai',secretId:credential.tmpSecretId,secretKey:credential.tmpSecretKey,sessionToken:credential.tmpToken}).database();
const host='https://xmy-test-d5g8c0xcifcefcfd5-1449098021.ap-shanghai.app.tcloudbase.com';
const id='balanced-route-'+crypto.randomBytes(5).toString('hex'), account=db.collection('bf_accounts').doc(id);
const password=crypto.randomBytes(24).toString('hex'),salt=crypto.randomBytes(16).toString('hex');
const report={at:new Date().toISOString(),checks:[],paidImageCalls:0};let token='',created=false;
function check(name,fields={}) {const row={name,...fields};report.checks.push(row);console.log(JSON.stringify(row));}
async function request(route,body) {
 const start=Date.now(),response=await fetch(host+route,{method:body===undefined?'GET':'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+token},body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(290000)});
 const raw=await response.text();let value;try{value=JSON.parse(raw);}catch{value={raw};}
 assert.equal(response.status,200,route+' '+response.status+' '+String(value.error||value.msg||'').slice(0,100));return {value,ms:Date.now()-start};
}
const textItem={type:'object',properties:{key:{type:'string'},role:{type:'string'},text:{type:'string'}},required:['key','role','text']};
const tool={type:'function',function:{name:'image_generate',description:'生成一张图片',parameters:{
 type:'object',properties:{prompt:{type:'string'},quality_tier:{type:'string',enum:['fast','high','auto']},
 quality_reason:{type:'string',enum:['simple_visual','detailed_layout','complex_edit']},
 structured:{type:'object',properties:{text:{type:'array',items:textItem}}}},required:['prompt']}}};
async function plan(user,stream) {
 const r=await request('/api/chat',{chatMode:'standard',max_tokens:1500,stream,messages:[{role:'user',content:user}],tools:[tool],tool_choice:{type:'function',function:{name:'image_generate'}}});
 let calls;if(!stream)calls=r.value.choices?.[0]?.message?.tool_calls;
 else {calls=[];for(const line of String(r.value.raw||'').split('\n')){if(!line.startsWith('data: ')||line==='data: [DONE]')continue;const part=JSON.parse(line.slice(6));assert.ok(!part.error);for(const c of part.choices||[])calls.push(...(c.delta?.tool_calls||[]));}}
 assert.equal(calls?.length,1);return {args:JSON.parse(calls[0].function.arguments),ms:r.ms};
}
(async()=>{try{
 const info=await request('/img/models');assert.equal(info.value.routingMode,'auto');assert.equal(info.value.autoPolicy.honorUserQuality,true);assert.equal(info.value.autoPolicy.honorClientHigh,false);assert.ok(info.value.autoPolicy.proReasons.includes('detailed_layout'));check('live balanced runtime policy');
 const now=new Date();await account.set({username:id,displayName:'混合路由临时验证',tier:'ultra',status:'active',expiresAt:new Date(Date.now()+3600000),createdAt:now,cycleAnchorAt:now,quotaOverrideCny:20,passwordHash:'scrypt$'+salt+'$'+crypto.scryptSync(password,salt,64).toString('hex'),pwv:0,sv:0,chatUsedCny:0,imageUsedCny:0,failedAttempts:0,lockUntil:null});created=true;
 token=(await request('/api/login',{username:id,password})).value.token;assert.ok(token);check('old member login');
 await request('/api/me');check('membership endpoint');
 for(const stream of [false,true]){
  for(const [user,quality] of [['直接画一只简单小猫，浅米白背景，不要文字','auto'],['直接制作一张高质量专业级消防海报，标题只有城市消防四个字','high']]){
   const result=await plan(user,stream);assert.equal(result.args.structured?.routing?.user_quality,quality);check((stream?'SSE':'JSON')+' user intent '+quality,{ms:result.ms});
  }
 }
 const base={requestId:crypto.randomUUID(),prompt:'一辆红色消防车，浅米白色背景，简洁现代平面插画，无文字。',task_kind:'generate',quality_tier:'high',size:'1536x1536',structured:{routing:{user_quality:'auto',reason:'simple_visual'}}};
 let bytes;
 const scenarios=[
  {name:'ordinary image',body:base,model:/flash/,reason:'auto:default-fast'},
  {name:'high quality poster',body:{...base,requestId:crypto.randomUUID(),prompt:'专业级城市消防宣传海报，红色消防车，清晰的视觉焦点与精致留白，无文字。',structured:{routing:{user_quality:'high'}}},model:/-pro-/,reason:'auto:user-quality'},
  {name:'simple color edit',body:()=>({...base,requestId:crypto.randomUUID(),task_kind:'edit',image:'data:image/jpeg;base64,'+bytes.toString('base64'),prompt:'只把消防车的车身从红色改成深蓝色，保留车轮、梯子、背景和画布，不裁切。',structured:{routing:{user_quality:'auto',reason:'simple_edit'}}}),model:/flash/,reason:'auto:default-fast'},
  {name:'complex reference edit',body:()=>({...base,requestId:crypto.randomUUID(),task_kind:'edit',image:'data:image/jpeg;base64,'+bytes.toString('base64'),prompt:'保留消防车的结构和轮廓，精细调整车身金属反光，统一光照和接触阴影，保持原图背景与画布完整，无文字。',structured:{routing:{user_quality:'auto',reason:'complex_edit'}}}),model:/-pro-/,reason:'auto:complex_edit'},
 ];
 for(const [index,s] of scenarios.entries()){
  const body=typeof s.body==='function'?s.body():s.body;report.paidImageCalls++;
  const out=await request('/img/image',body);assert.equal(out.value.ok,true);assert.match(out.value.model,s.model);assert.equal(out.value.route_reason,s.reason);
  const media=await fetch(out.value.url,{signal:AbortSignal.timeout(30000)});assert.equal(media.status,200);const image=Buffer.from(await media.arrayBuffer());if(index===0)bytes=image;
  const file='balanced-route-'+index+'.image';fs.writeFileSync(path.join(root,'outputs',file),image);check(s.name,{model:out.value.model,reason:out.value.route_reason,ms:out.ms,cost:out.value.cost,requestId:body.requestId,file});
 }
 const replay=await request('/img/image',base);assert.equal(replay.value.cached,true);assert.equal(replay.value.cost,0);check('same requestId replay is cached, no additional charge',{ms:replay.ms});
 report.ok=true;
}catch(error){report.ok=false;report.error=String(error.message||error).replace(/https?:\/\/\S+/g,'[url]').slice(0,250);throw error;}
finally{if(created){assert.ok(id.startsWith('balanced-route-'));await account.remove();report.temporaryAccountDeleted=true;}const text=JSON.stringify(report,null,2);fs.writeFileSync(path.join(root,'outputs/image-balanced-routing-verification.json'),text);fs.writeFileSync(path.join(root,'outputs/image-balanced-routing-verification-'+report.at.replace(/[:.]/g,'-')+'.json'),text);}
})().catch(error=>{console.error(String(error.message||error).replace(/https?:\/\/\S+/g,'[url]').slice(0,250));process.exitCode=1;});
