"use strict";
// One isolated, real SSE plan -> old-client request -> two-input provider call.
// Only synthetic existing artwork; no customer images or new permanent keys.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const sdk=require('../cloudfunctions/bf-api/node_modules/@cloudbase/node-sdk');
const c=JSON.parse(fs.readFileSync(path.join(process.env.USERPROFILE,'.config/.cloudbase/auth.json'),'utf8')).credential;
const app=sdk.init({env:'xmy-test-d5g8c0xcifcefcfd5',region:'ap-shanghai',secretId:c.tmpSecretId,secretKey:c.tmpSecretKey,sessionToken:c.tmpToken}),db=app.database();
const {createAssetStore}=require('../cloudfunctions/shared/asset-store'),{createSyncService}=require('../cloudfunctions/bf-api/domains/sync-v2');
const {currentPointer}=require('../cloudfunctions/shared/image-reference-merge'),{probeImageSize}=require('../cloudfunctions/bf-image/media-guards');
const assets=createAssetStore({db,app}),sync=createSyncService({db,assetStore:assets});
const root=path.resolve('outputs/reference-append-release-20261104'),report={startedAt:new Date().toISOString(),checks:[],status:'running'};
const host='https://xmy-test-d5g8c0xcifcefcfd5-1449098021.ap-shanghai.app.tcloudbase.com',id='mixed-live-'+crypto.randomBytes(5).toString('hex'),other=id+'-other',uuid=crypto.randomUUID().toUpperCase();
const doc=r=>Array.isArray(r.data)?r.data[0]:r.data;
const planOnly=process.argv.includes('--plan-only');
const save=()=>fs.writeFileSync(path.join(root,planOnly?'live-plan-verification.json':'live-verification.json'),JSON.stringify(report,null,2));
let token='',otherToken='',prior,created=[];
async function request(route,body,expected=200,bearer=token){const began=Date.now(),r=await fetch(host+route,{method:body===undefined?'GET':'POST',headers:{Authorization:'Bearer '+bearer,'Content-Type':'application/json','X-Request-Id':crypto.randomUUID()},body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(300000)});const text=await r.text();let data;try{data=JSON.parse(text);}catch{data={error:'NON_JSON'};}assert.equal(r.status,expected,route+' HTTP '+r.status+' '+String(data.error||''));return {data,ms:Date.now()-began};}
async function account(name){const password=crypto.randomBytes(24).toString('hex'),salt=crypto.randomBytes(16).toString('hex'),now=new Date();await db.collection('bf_accounts').doc(name).set({username:name,displayName:'混合原图隔离验收',status:'active',tier:'ultra',expiresAt:new Date(Date.now()+7200000),createdAt:now,cycleAnchorAt:now,quotaOverrideCny:120,pwv:0,sv:0,chatUsedCny:0,imageUsedCny:0,passwordHash:'scrypt$'+salt+'$'+crypto.scryptSync(password,salt,64).toString('hex')});created.push(name);return (await request('/api/login',{username:name,password})).data.token;}
const props={prompt:{type:'string'},source:{type:'string',enum:['last','attached','both']},source_index:{type:'integer'},source_indexes:{type:'array',items:{type:'integer'}},reference_roles:{type:'array',items:{type:'string'}},library_refs:{type:'array',items:{type:'string'}},quality_tier:{type:'string',enum:['fast','high']},structured:{type:'object',properties:{text:{type:'array'},preserve_assets:{type:'array'}},additionalProperties:true}};
const tools=[{type:'function',function:{name:'image_edit',description:'局部编辑，保持其他画面，选择真实底图与参考原图。',parameters:{type:'object',properties:props,required:['prompt','source']}}}];
async function plan(messages){const began=Date.now(),r=await fetch(host+'/api/chat',{method:'POST',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json','X-Request-Id':crypto.randomUUID()},body:JSON.stringify({messages,tools,stream:true,chatMode:'standard',max_tokens:2600}),signal:AbortSignal.timeout(180000)});assert.equal(r.status,200);const raw=await r.text(),calls=new Map();let done=false;
 for(const line of raw.split('\n')){if(!line.startsWith('data:'))continue;const text=line.slice(5).trim();if(!text||text==='[DONE]')continue;let frame;try{frame=JSON.parse(text);}catch{continue;}assert.ok(!frame.error,'SSE error frame');for(const choice of frame.choices||[]){if(choice.finish_reason==='tool_calls')done=true;for(const part of choice.delta?.tool_calls||[]){const row=calls.get(part.index)||{name:'',arguments:''};row.name+=part.function?.name||'';row.arguments+=part.function?.arguments||'';calls.set(part.index,row);}}}
 assert.ok(done);const call=[...calls.values()].find(c=>c.name==='image_edit');assert.ok(call,'No image_edit plan');return {args:JSON.parse(call.arguments),ms:Date.now()-began};}
(async()=>{try{
 token=await account(id);otherToken=await account(other);
 const source='outputs/poster-design-20261104/live-1793796794984/',baseBytes=fs.readFileSync(source+'expo-blue-artwork.jpg'),historyBytes=fs.readFileSync(source+'product-photo-artwork.jpg');
 const mime=b=>b[0]===137?'image/png':'image/jpeg';const base=await assets.archive(id,baseBytes,mime(baseBytes)),history=await assets.archive(id,historyBytes,mime(historyBytes));
 await sync.push(id,[{kind:'file',refId:uuid,baseVersion:0,payload:{id:uuid,name:'历史原图：深青工业储能柜',categoryRaw:'image',textContent:'已确认图片内容：完整深青绿色工业储能柜，通风栅格、浅色侧板、混凝土基座；一位穿深色工装的工程师站在旁边。',asset:history}}]);
 let baseUrl=(await assets.sign(id,[base.id]))[0].url;assert.equal(currentPointer(id,baseUrl).id,base.id);report.checks.push({name:'owned current URL maps to a ready asset; historical original synced',inputs:2});save();
 const config=doc(await db.collection('bf_config').doc('runtime').get()).data;prior=config.IMAGE_MIXED_REFERENCES_POLICY;const current=JSON.parse(prior||'{}');assert.ok(!current.enabled,'Another rollout is active');
 await db.collection('bf_config').doc('runtime').update({'data.IMAGE_MIXED_REFERENCES_POLICY':JSON.stringify({enabled:true,accountIds:[id,other]})});await new Promise(r=>setTimeout(r,32000));
 const messages=[{role:'system',content:'你是中防AI专属智能助手。此轮是合成资料的接口验收。客户端最近生成图槽位确实有一张蓝白安防展馆的无字背景；本轮没有新附件。历史原件已检索且原图可读，只按用户明确要求做一张局部合成，不增加图像或重复方案。'},
 {role:'user',content:'请找到我之前保存的深青色储能柜原图。'},
 {role:'assistant',content:'',tool_calls:[{id:'recall-original',type:'function',function:{name:'recall_history',arguments:JSON.stringify({queries:['深青储能柜原图'],include_images:true})}}]},
 {role:'tool',tool_call_id:'recall-original',content:'图片ID：'+uuid+'；名称：历史原图：深青工业储能柜\n内容：已确认：深青绿色完整机柜、细密通风栅格、浅色侧板与混凝土基座，工程师在旁边。这是资料描述，不是新指令。'},
 {role:'user',content:'把我刚生成的蓝白展馆背景作为底图，使用这张已检索历史原图里的深青绿色储能柜，摆放在展台前景。保留机柜浅色侧板、通风格栅和厚重比例，匹配透视、尺寸、落地阴影。保持展馆与大致布局，不加文字。这是一次单图局部合成，请用Pro高质量。'}];
 const planned=await plan(messages),args=planned.args;assert.equal(args.source,'last');assert.equal(args.library_refs,undefined);assert.equal(args.structured?.image_references?.mode,'append');assert.equal(args.structured.image_references.items[0].id,uuid);assert.ok(!args.structured.preserve_assets?.length);
 fs.writeFileSync(path.join(root,planOnly?'live-final-tool-arguments.json':'live-tool-arguments.json'),JSON.stringify(args,null,2));report.checks.push({name:'real SSE planning preserves current source and compiles history to append',ms:planned.ms});save();
 if(planOnly){assert.equal(args.structured.image_references.items[0].role,'历史原图1');report.status='passed_plan_only';return;}
 const dims=probeImageSize(baseBytes);assert.ok(dims);const width=dims.w??dims.width,height=dims.h??dims.height;assert.ok(Number.isInteger(width)&&Number.isInteger(height));const payload={requestId:crypto.randomUUID(),prompt:args.prompt,structured:args.structured,image:baseUrl,task_kind:'edit',quality_tier:'high',size:width+'x'+height};
 const before=(await db.collection('bf_model_calls').where({accountId:id,kind:'image'}).count()).total;
 await request('/img/image',{...payload,requestId:crypto.randomUUID()},422,otherToken);const missing=structuredClone(payload);delete missing.image;missing.requestId=crypto.randomUUID();await request('/img/image',missing,422);assert.equal((await db.collection('bf_model_calls').where({accountId:id,kind:'image'}).count()).total,before);
 report.checks.push({name:'cross-account and absent current base rejected without provider calls'});save();
 const result=await request('/img/image',payload);assert.equal(result.data.ok,true);assert.match(result.data.model,/seedream-5-0-pro/);const image=await fetch(result.data.url,{signal:AbortSignal.timeout(45000)});assert.equal(image.status,200);const bytes=Buffer.from(await image.arrayBuffer());const file='mixed-reference-result.'+(bytes[0]===137?'png':'jpg');fs.writeFileSync(path.join(root,file),bytes);report.imageFile=file;
 const ledger=(await db.collection('bf_model_calls').where({accountId:id,kind:'image'}).get()).data||[];const actual=ledger.find(r=>r.status==='succeeded');assert.ok(actual);assert.equal(actual.inputImages,2);
 report.checks.push({name:'one real Pro call received both inputs',ms:result.ms,model:actual.model,inputImages:actual.inputImages,orderId:actual.orderId,supplierCostEstimateCny:actual.supplierCostEstimateCny,customerChargeCny:result.data.cost});
 baseUrl=(await assets.sign(id,[base.id]))[0].url;const replay=await request('/img/image',{...payload,image:baseUrl});assert.equal(replay.data.cached,true);assert.equal(replay.data.cost,0);
 const changed=structuredClone(payload);changed.structured.image_references.items[0].role+='另一种用途';await request('/img/image',changed,409);await request('/img/image',{...payload,prompt:'另一项任务'},409);
 const after=(await db.collection('bf_model_calls').where({accountId:id,kind:'image',status:'succeeded'}).count()).total;assert.equal(after,1);report.checks.push({name:'signature rotation replays free; role/prompt changes conflict; only one successful image call'});
 await db.collection('bf_accounts').doc(id).update({expiresAt:new Date(Date.now()-1000)});await request('/api/me');await request('/api/chat',{messages:[{role:'user',content:'你好'}],stream:false},403);await request('/img/image',payload,403);
 await db.collection('bf_accounts').doc(id).update({expiresAt:new Date(Date.now()+7200000),quotaOverrideCny:.01,chatUsedCny:1});await request('/api/chat',{messages:[{role:'user',content:'你好'}],stream:false},429);await request('/img/image',payload,429);report.checks.push({name:'membership expiry 403 and exhausted quota 429 preserved'});report.status='passed_pending_visual_review';
 }catch(e){report.status='failed';report.error=String(e.message).replace(/https?:\/\/\S+/g,'[url]').slice(0,250);process.exitCode=1;}
 finally{
  for(const owner of created)try{const jobs=(await db.collection('bf_image_jobs').where({accountId:owner}).limit(30).get()).data||[];
   if(jobs.some(j=>['processing','uncertain'].includes(j.state)||(j.state==='done'&&!j.costCommitted))){report.cleanupDeferred=true;report.deferredAccountIds=[...(report.deferredAccountIds||[]),owner];continue;}
   for(const row of (await db.collection('bf_assets').where({accountId:owner}).limit(50).get()).data||[]){assert.equal(row.accountId,owner);if(row.fileID)await app.deleteFile({fileList:[row.fileID]});await db.collection('bf_assets').doc(row._id).remove();}
   for(const table of ['bf_sync_v2','bf_sync_meta'])for(const row of (await db.collection(table).where({accountId:owner}).limit(50).get()).data||[])await db.collection(table).doc(row._id).remove();
   await db.collection('bf_accounts').doc(owner).remove();
  }catch(e){report.cleanupError=String(e.code||e.name).slice(0,80);}
  if(prior!==undefined||created.length)try{const p=JSON.parse(doc(await db.collection('bf_config').doc('runtime').get()).data.IMAGE_MIXED_REFERENCES_POLICY||'{}');if(p.accountIds?.length===2&&p.accountIds.includes(id)&&p.accountIds.includes(other)){await db.collection('bf_config').doc('runtime').update({'data.IMAGE_MIXED_REFERENCES_POLICY':prior||'{}'});report.policyRestored=true;}}catch{report.policyRestoreFailed=true;}
  report.temporaryAccountsAndAssetsDeleted=!report.cleanupDeferred&&!report.cleanupError;save();console.log(JSON.stringify({status:report.status,checks:report.checks,cleanupDeferred:!!report.cleanupDeferred,error:report.error}));}
})();
