// Live canary: one temporary account, existing management session, no permanent key.
// No production account or credentials are copied into this report.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'..');
const sdk=require(path.join(root,'cloudfunctions/bf-api/node_modules/@cloudbase/node-sdk'));
const credential=JSON.parse(fs.readFileSync(path.join(process.env.USERPROFILE,'.config/.cloudbase/auth.json'),'utf8')).credential;
const app=sdk.init({env:'xmy-test-d5g8c0xcifcefcfd5',region:'ap-shanghai',secretId:credential.tmpSecretId,secretKey:credential.tmpSecretKey,sessionToken:credential.tmpToken});
const db=app.database(),host='https://xmy-test-d5g8c0xcifcefcfd5-1449098021.ap-shanghai.app.tcloudbase.com';
const suffix=crypto.randomBytes(5).toString('hex'),id='image-audit-v2-'+suffix,username='image_audit_'+suffix;
const password=crypto.randomBytes(24).toString('hex'),salt=crypto.randomBytes(16).toString('hex');
const doc=db.collection('bf_accounts').doc(id),checks=[],report={at:new Date().toISOString(),checks};let token='',created=false;
async function request(route,body,expected=200) {
 const started=Date.now();
 const r=await fetch(host+route,{method:body===undefined?'GET':'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+token},body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(290000)});
 const text=await r.text();let value;try{value=JSON.parse(text);}catch{value={raw:text};}
 assert.equal(r.status,expected,route+': '+r.status+' '+String(value.error||value.message||'').slice(0,100));
 return {value,ms:Date.now()-started};
}
function check(name,detail={}) {checks.push({name,...detail});console.log(JSON.stringify({check:name,...detail}));}
(async()=>{
 try {
  const initial=await request('/img/models');assert.equal(initial.value.routingMode,'auto');assert.equal(initial.value.autoPolicy.defaultTier,'fast');assert.match(initial.value.routes.generate_auto.model,/flash/);check('live auto policy defaults to Flash');
  const now=new Date();await doc.set({username,displayName:'服务端链路临时验证',tier:'ultra',status:'active',expiresAt:new Date(Date.now()+3600000),createdAt:now,cycleAnchorAt:now,quotaOverrideCny:20,passwordHash:'scrypt$'+salt+'$'+crypto.scryptSync(password,salt,64).toString('hex'),pwv:0,sv:0,chatUsedCny:0,imageUsedCny:0,failedAttempts:0,lockUntil:null});created=true;
  token=(await request('/api/login',{username,password})).value.token;assert.ok(token);check('temporary member login and authorization');
  const legacySystem='【数据真实性铁律】外部事实必须标明数据来源，未核实必须写未核实。只使用提供的工具。';
  const tool={type:'function',function:{name:'image_generate',description:'生成一张图片',parameters:{type:'object',properties:{prompt:{type:'string'},quality_tier:{type:'string'},source:{type:'string'},structured:{type:'object',properties:{text:{type:'array',items:{type:'object',properties:{key:{type:'string'},role:{type:'string'},text:{type:'string'}},required:['key','role','text']}}}}},required:['prompt']}}};
  const chat={chatMode:'standard',max_tokens:1800,messages:[{role:'system',content:legacySystem},{role:'user',content:'请直接调用工具，制作一张城市消防远程监控系统宣传海报。标题：城市消防远程监控系统。副标题：让城市更安全。不要显示检索出处和核对说明。'}],tools:[tool],tool_choice:{type:'function',function:{name:'image_generate'}}};
  for(const stream of (process.argv.includes('--images-only') ? [] : [false,true])) {
   const answer=await request('/api/chat',{...chat,stream});
   let calls;
   if(!stream)calls=answer.value.choices?.[0]?.message?.tool_calls;
   else {calls=[];for(const line of String(answer.value.raw||'').split('\n')){if(!line.startsWith('data: ')||line==='data: [DONE]')continue;let part;try{part=JSON.parse(line.slice(6));}catch{continue;}assert.ok(!part.error);for(const choice of part.choices||[])if(choice.delta?.tool_calls)calls.push(...choice.delta.tool_calls);}}
   assert.ok(calls?.length,'real frontend model did not call image tool');
   const args=JSON.parse(calls[0].function.arguments);assert.equal(args.structured.delivery_policy.version,'IMAGE_DELIVERY_V2');assert.ok(!JSON.stringify(args.structured.text||[]).includes('未核实项'));check(stream?'real SSE tool parameters are prepared before the phone':'real non-stream tool parameters are prepared before the phone',{ms:answer.ms,tool:calls[0].function.name});
  }
  const requestId=crypto.randomUUID();
  const basic={requestId,prompt:'一张简洁的城市消防主题插画，浅米白色背景，单一红色消防车为视觉主体，柔和阴影，现代平面插画，不要文字。',task_kind:'generate',quality_tier:'high',size:'1536x1536',render_intent:'flat'};
  let firstUrl='',firstBytes;
  const scenarios=[['Flash default',{...basic}],['Pro explicit',{...basic,requestId:crypto.randomUUID(),structured:{routing:{preference:'pro'}}}]];
  for(const [label,body] of (process.argv.includes('--flash-only') ? scenarios.slice(0,1) : scenarios)) {
   const output=await request('/img/image',body);assert.equal(output.value.ok,true);assert.match(output.value.model,label.startsWith('Flash')?/flash/:/-pro-/);
   const image=await fetch(output.value.url,{signal:AbortSignal.timeout(30000)});assert.equal(image.status,200);const bytes=Buffer.from(await image.arrayBuffer());
   if(label.startsWith('Flash')){firstUrl=output.value.url;firstBytes=bytes;}
   const file='image-server-v2-'+(label.startsWith('Flash')?'flash':'pro')+'.image';fs.writeFileSync(path.join(root,'outputs',file),bytes);
   check(label,{model:output.value.model,route:output.value.route_reason,ms:output.ms,requestId:body.requestId,bytes:bytes.length,file});
  }
  const replay=await request('/img/image',basic);assert.equal(replay.value.ok,true);assert.equal(replay.value.url,firstUrl);assert.equal(replay.value.cached,true);assert.equal(replay.value.cost,0);check('same requestId replay reuses generation',{ms:replay.ms,cost:0,cached:true});
  if(process.argv.includes('--edit')) {
   const type=firstBytes[0]===0x89?'image/png':'image/jpeg';
   const edited=await request('/img/image',{...basic,requestId:crypto.randomUUID(),task_kind:'edit',image:'data:'+type+';base64,'+firstBytes.toString('base64'),prompt:'只把消防车的红色车身改成深蓝色，保留车型、车轮、梯子、背景、阴影和整个画布，不裁切。'});
   assert.equal(edited.value.ok,true);assert.match(edited.value.model,/flash/);
   const media=await fetch(edited.value.url);assert.equal(media.status,200);fs.writeFileSync(path.join(root,'outputs/image-server-v2-flash-edit.image'),Buffer.from(await media.arrayBuffer()));
   check('Flash reference edit',{model:edited.value.model,ms:edited.ms,route:edited.value.route_reason});
  }
  report.ok=true;
 } catch(error) {report.ok=false;report.error=String(error.message||error).replace(/https?:\/\/\S+/g,'[url]').slice(0,300);throw error;}
 finally {
  if(created){assert.ok(id.startsWith('image-audit-v2-'));await doc.remove();report.temporaryAccountDeleted=true;}
  fs.writeFileSync(path.join(root,'outputs/image-server-v2-verification.json'),JSON.stringify(report,null,2));
  fs.writeFileSync(path.join(root,'outputs/image-server-v2-verification-'+report.at.replace(/[:.]/g,'-')+'.json'),JSON.stringify(report,null,2));
 }
})().catch(error=>{console.error(String(error.message||error).replace(/https?:\/\/\S+/g,'[url]').slice(0,300));process.exitCode=1;});
