const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'..'),sdk=require(path.join(root,'cloudfunctions/bf-api/node_modules/@cloudbase/node-sdk'));
const c=JSON.parse(fs.readFileSync(path.join(process.env.USERPROFILE,'.config/.cloudbase/auth.json'),'utf8')).credential;
const db=sdk.init({env:'xmy-test-d5g8c0xcifcefcfd5',region:'ap-shanghai',secretId:c.tmpSecretId,secretKey:c.tmpSecretKey,sessionToken:c.tmpToken}).database();
const host='https://xmy-test-d5g8c0xcifcefcfd5-1449098021.ap-shanghai.app.tcloudbase.com';
const id='ledger-check-'+crypto.randomBytes(5).toString('hex'),password=crypto.randomBytes(24).toString('hex'),salt=crypto.randomBytes(16).toString('hex');
const account=db.collection('bf_accounts').doc(id),report={at:new Date().toISOString(),checks:[]};let token='',created=false;
async function request(route,body){const r=await fetch(host+route,{method:body===undefined?'GET':'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+token},body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(290000)});const raw=await r.text();assert.equal(r.status,200,route+' '+r.status);return raw;}
(async()=>{try{
 const now=new Date();await account.set({username:id,displayName:'调用台账临时验证',tier:'ultra',status:'active',expiresAt:new Date(Date.now()+3600000),createdAt:now,cycleAnchorAt:now,quotaOverrideCny:5,passwordHash:'scrypt$'+salt+'$'+crypto.scryptSync(password,salt,64).toString('hex'),pwv:0,sv:0,chatUsedCny:0,imageUsedCny:0,failedAttempts:0,lockUntil:null});created=true;
 token=JSON.parse(await request('/api/login',{username:id,password})).token;assert.ok(token);
 const blocked=await fetch(host+'/api/admin/model-calls',{headers:{Authorization:'Bearer '+token}});assert.ok([401,403].includes(blocked.status));report.checks.push('member cannot read financial ledger');
 for(const stream of [false,true]){const raw=await request('/api/chat',{chatMode:'standard',stream,max_tokens:40,messages:[{role:'user',content:'只回复测试通过四个字。校验码'+crypto.randomBytes(3).toString('hex')}]});if(!stream)assert.ok(JSON.parse(raw).choices);else assert.ok(raw.includes('[DONE]'));report.checks.push(stream?'SSE response intact':'JSON response intact');}
 const body={requestId:crypto.randomUUID(),task_kind:'generate',quality_tier:'fast',size:'1536x1536',prompt:'一棵绿色小树，纯米白色背景，简洁平面插画，无文字。',structured:{routing:{preference:'flash',user_quality:'auto',reason:'simple_visual'}}};
 const image=JSON.parse(await request('/img/image',body));assert.ok(image.ok);const replay=JSON.parse(await request('/img/image',body));assert.equal(replay.cached,true);assert.equal(replay.cost,0);report.checks.push('image succeeds; replay is zero charge');
 const rows=(await db.collection('bf_model_calls').where({accountId:id}).get()).data;
 const chat=rows.filter(x=>x.kind==='chat'&&['succeeded','partial'].includes(x.status));assert.ok(chat.length>=2);assert.ok(chat.every(x=>x.inputTokens>0&&x.outputTokens>0&&x.vendorRequestId&&x.priceCny!=null));
 const images=rows.filter(x=>x.kind==='image'&&x.status==='succeeded');assert.equal(images.length,1);assert.equal(images[0].priceCny,image.cost);assert.equal(images[0].supplierCostEstimateCny,0.12);assert.equal(images[0].supplierBilledCny,null);
 const cached=rows.find(x=>x.kind==='image'&&x.status==='cached');assert.ok(cached);assert.equal(cached.orderId,images[0].orderId);assert.equal(cached.priceCny,0);
 report.rows=rows.map(({_id,orderId,requestId,clientRequestId,kind,status,provider,model,inputTokens,outputTokens,cachedInputTokens,supplierCostEstimateCny,supplierBilledCny,priceCny,chargeState,durationMs,vendorRequestId})=>({_id,orderId,requestId,clientRequestId,kind,status,provider,model,inputTokens,outputTokens,cachedInputTokens,supplierCostEstimateCny,supplierBilledCny,priceCny,chargeState,durationMs,vendorRequestId}));
 report.checks.push('cloud rows match actual usage, charge, vendor ID, stable order');report.ok=true;
}catch(error){report.ok=false;report.error=String(error.message||error).replace(/https?:\/\/\S+/g,'[url]').slice(0,240);throw error;}
finally{if(created){assert.ok(id.startsWith('ledger-check-'));await account.remove();report.temporaryAccountDeleted=true;}fs.writeFileSync(path.join(root,'outputs/model-call-ledger-verification.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report));}
})().catch(error=>{console.error(error.message);process.exitCode=1;});
