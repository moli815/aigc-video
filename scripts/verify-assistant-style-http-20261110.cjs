"use strict";
const fs=require('fs'),path=require('path'),crypto=require('crypto'),assert=require('assert/strict');
const c=JSON.parse(fs.readFileSync(path.join(process.env.USERPROFILE,'.config/.cloudbase/auth.json'),'utf8')).credential;
const db=require('../cloudfunctions/bf-api/node_modules/@cloudbase/node-sdk').init({env:'xmy-test-d5g8c0xcifcefcfd5',region:'ap-shanghai',secretId:c.tmpSecretId,secretKey:c.tmpSecretKey,sessionToken:c.tmpToken}).database();
const base='https://xmy-test-d5g8c0xcifcefcfd5-1449098021.ap-shanghai.app.tcloudbase.com',id='style_http_'+crypto.randomBytes(8).toString('hex');
const report={at:new Date(),checks:[],customerQuotaChanged:false,imagesGenerated:0};let created=false,token='';
const metadataOnly=process.argv.includes('--metadata-only');
async function request(route,body){const r=await fetch(base+route,{method:body?'POST':'GET',headers:{'Content-Type':'application/json',...(token?{Authorization:'Bearer '+token}:{})},...(body?{body:JSON.stringify(body)}:{}),signal:AbortSignal.timeout(90000)});const text=await r.text();let json;try{json=JSON.parse(text);}catch{}return{status:r.status,text,json};}
(async()=>{try{
 const health=await request('/api/health');assert.equal(health.status,200);report.checks.push('health 200');
 const anonymousCatalog=await request('/api/experts');assert.equal(anonymousCatalog.status,401);report.checks.push('anonymous catalog 401');
 const rt=(await db.collection('bf_config').doc('runtime').get()).data[0].data;assert.equal(JSON.parse(rt.CHAT_STYLE_POLICY).enabled,false);report.checks.push('unaccepted style prompt disabled');
 const password=crypto.randomBytes(24).toString('hex'),salt=crypto.randomBytes(16).toString('hex'),now=new Date();
 await db.collection('bf_accounts').doc(id).set({username:id,displayName:'临时对话风格兼容检查',status:'active',tier:'ultra',expiresAt:new Date(Date.now()+1800000),createdAt:now,cycleAnchorAt:now,quotaOverrideCny:5,pwv:0,sv:0,chatUsedCny:0,imageUsedCny:0,passwordHash:'scrypt$'+salt+'$'+crypto.scryptSync(password,salt,64).toString('hex')});created=true;
 const login=await request('/api/login',{username:id,password});assert.equal(login.status,200);token=login.json.token;assert.ok(token);
 const catalog=await request('/api/experts');assert.equal(catalog.status,200);assert.ok(!catalog.json.experts.find(e=>e.id==='short_video').steps.some(s=>s.startsWith('给 3 个')));report.expertVersion=catalog.json.version;
 const expert=catalog.json.experts.find(e=>e.id==='general'),system=expert.role+'\n【必须遵循的工作流】\n'+expert.steps.join('\n');
 if(!metadataOnly){
 const plain=await request('/api/chat',{chatMode:'standard',stream:false,max_tokens:1000,messages:[{role:'system',content:system},{role:'user',content:'营业额1万元，毛利率25%，毛利多少？一句话回答。'}]});assert.equal(plain.status,200);assert.match(plain.json.choices[0].message.content,/2500/);report.checks.push('old non-stream chat JSON');
 const streamed=await request('/api/chat',{chatMode:'standard',stream:true,max_tokens:1000,messages:[{role:'system',content:system},{role:'user',content:'我们是一家软件公司。只把这句话写得自然一点，仅返回改写后的一句。'}]});assert.equal(streamed.status,200);assert.match(streamed.text,/data: \[DONE\]/);let output='';for(const line of streamed.text.split('\n'))if(line.startsWith('data: ')&&line!=='data: [DONE]'){const j=JSON.parse(line.slice(6));assert.ok(!j.error);output+=j.choices?.[0]?.delta?.content||'';}assert.ok(output.trim());report.checks.push('old SSE JSON frames and DONE');
 }
 await db.collection('bf_accounts').doc(id).update({expiresAt:new Date(Date.now()-1000)});
 const expired=await request('/api/chat',{stream:false,messages:[{role:'user',content:'测试'}]});assert.equal(expired.status,403);report.checks.push('expired membership 403');
 await db.collection('bf_accounts').doc(id).update({expiresAt:new Date(Date.now()+1800000),quotaOverrideCny:.01,chatUsedCny:1});
 const quota=await request('/api/chat',{stream:false,messages:[{role:'user',content:'测试'}]});assert.equal(quota.status,429);report.checks.push('exhausted quota 429');report.ok=true;
 }finally{if(created){await db.collection('bf_accounts').doc(id).remove();report.temporaryAccountDeleted=true;}fs.writeFileSync('outputs/assistant-style-20261110/'+(metadataOnly?'metadata-verification.json':'http-verification.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report));}
})().catch(e=>{console.error(e.code||e.name);process.exitCode=1;});
