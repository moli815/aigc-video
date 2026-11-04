"use strict";
// Synthetic confirmed copy, real design planning + Pro artwork. No customer data.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const sdk=require('../cloudfunctions/bf-api/node_modules/@cloudbase/node-sdk');
const credential=JSON.parse(fs.readFileSync(path.join(process.env.USERPROFILE,'.config/.cloudbase/auth.json'),'utf8')).credential;
const app=sdk.init({env:'xmy-test-d5g8c0xcifcefcfd5',region:'ap-shanghai',secretId:credential.tmpSecretId,secretKey:credential.tmpSecretKey,sessionToken:credential.tmpToken}),db=app.database();
const host='https://xmy-test-d5g8c0xcifcefcfd5-1449098021.ap-shanghai.app.tcloudbase.com';
const root=path.resolve('outputs/poster-design-20261104'),folder=path.join(root,'live-'+Date.now());fs.mkdirSync(folder,{recursive:true});fs.writeFileSync(path.join(root,'latest-run.json'),JSON.stringify({folder}));
const id='poster-design-'+crypto.randomBytes(6).toString('hex'),report={startedAt:new Date().toISOString(),scope:'Synthetic fixed confirmed copy; real front-model design planning and Pro artwork. Copy pinned for same-content visual comparison, not a full client memory/copywriting test.',cases:[],status:'running'};
const doc=r=>Array.isArray(r.data)?r.data[0]:r.data;
let token='',created=false,priorDesign=null;
const save=()=>fs.writeFileSync(path.join(folder,'report.json'),JSON.stringify(report,null,2));
async function request(route,body,status=200){const started=Date.now();const r=await fetch(host+route,{method:body===undefined?'GET':'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+token,'X-Request-Id':crypto.randomUUID()},body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(360000)});const raw=await r.text();let data;try{data=JSON.parse(raw);}catch{data={error:'NON_JSON'};}assert.equal(r.status,status,route+' HTTP '+r.status+' '+String(data.error||'').slice(0,80));return {data,ms:Date.now()-started};}
const textItem={type:'object',properties:{key:{type:'string'},role:{type:'string',enum:['title','subtitle','body','label','contact','footer']},text:{type:'string'}},required:['key','role','text']};
const tools=[{type:'function',function:{name:'image_generate',description:'生成商业海报；准确文字在structured.text，完整设计结构在structured。',parameters:{type:'object',properties:{prompt:{type:'string'},source:{type:'string',enum:['none']},aspect_ratio:{type:'string'},quality_tier:{type:'string',enum:['fast','high']},render_intent:{type:'string',enum:['flat_artwork']},structured:{type:'object',properties:{text:{type:'array',items:textItem}},additionalProperties:true}},required:['prompt','structured']}}}];
async function run(entry){const row={id:entry.id,name:entry.name,status:'planning',sourceCopyPinned:true};report.cases.push(row);save();try{
 const messages=[{role:'system',content:'你是中防AI专属智能助手。为已确认定稿的商业海报做专业设计，文案不得新增、删除或改写。仅调用image_generate。此次是真实设计元数据验收，不需检索现实企业。输出合法JSON。'},
 {role:'user',content:entry.instruction+'\n画布：'+entry.ratio+'，明确使用Pro高质量。请按'+entry.style+'风格、'+entry.layout+'构图做设计规划，提供具体独立无字artwork_prompt与design_brief、可执行design_plan。不要沿用普通报告或模板条块堆砌。以下全部为我确认的合成公司资料，逐字保留，联系方式不能改：\n'+JSON.stringify(entry.text)}];
 const planned=await request('/api/chat',{messages,tools,stream:false,chatMode:'standard',max_tokens:11000});row.planMs=planned.ms;row.frontModel=planned.data.model;
 const call=planned.data.choices?.[0]?.message?.tool_calls?.find(t=>t.function?.name==='image_generate');assert.ok(call,'No design tool returned');const args=JSON.parse(call.function.arguments);
 row.agentDesign=args.structured?.design_plan;row.artworkPrompt=args.structured?.artwork_prompt;assert.ok(row.artworkPrompt,'Missing artwork brief');assert.ok(row.agentDesign,'Missing design_plan');
 fs.writeFileSync(path.join(folder,entry.id+'-agent-plan.json'),JSON.stringify(args,null,2));
 const structured={...args.structured,text:entry.text};row.copyChars=entry.text.reduce((n,t)=>n+t.text.length,0);row.textItems=entry.text.length;
 const payload={requestId:crypto.randomUUID(),task_kind:'generate',prompt:args.prompt,structured,aspect_ratio:entry.ratio,size:entry.size,quality_tier:'high',render_intent:'flat_artwork'};
 row.imageRequestId=payload.requestId;fs.writeFileSync(path.join(folder,entry.id+'-request.json'),JSON.stringify(payload,null,2));row.status='generating';save();
 const made=await request('/img/image',payload);assert.equal(made.data.ok,true);row.imageMs=made.ms;row.imageModel=made.data.model;row.route=made.data.route_reason;row.cost=made.data.cost;row.composition=made.data.composition;
 const image=await fetch(made.data.url,{signal:AbortSignal.timeout(45000)});assert.equal(image.status,200);const bytes=Buffer.from(await image.arrayBuffer());row.imageFile=entry.id+(bytes[0]===137?'.png':'.jpg');fs.writeFileSync(path.join(folder,row.imageFile),bytes);
 const replay=await request('/img/image',payload);assert.equal(replay.data.cached,true);assert.equal(replay.data.cost,0);row.replay={cached:true,cost:0};row.status='generated_pending_visual_review';
 console.log(JSON.stringify({id:row.id,planMs:row.planMs,imageMs:row.imageMs,composition:row.composition,model:row.imageModel}));
 }catch(e){row.status='failed';row.error=String(e.message).replace(/https?:\/\/\S+/g,'[url]').slice(0,250);console.log(JSON.stringify({id:row.id,error:row.error}));}finally{save();}}
(async()=>{try{
 const salt=crypto.randomBytes(16).toString('hex'),password=crypto.randomBytes(24).toString('hex'),now=new Date();
 await db.collection('bf_accounts').doc(id).set({username:id,displayName:'海报设计隔离验收',status:'active',tier:'ultra',expiresAt:new Date(Date.now()+7200000),createdAt:now,cycleAnchorAt:now,quotaOverrideCny:120,pwv:0,sv:0,chatUsedCny:0,imageUsedCny:0,passwordHash:'scrypt$'+salt+'$'+crypto.scryptSync(password,salt,64).toString('hex')});created=true;
 const data=doc(await db.collection('bf_config').doc('runtime').get()).data,policy=JSON.parse(data.IMAGE_COMPOSITION_POLICY||'{}');assert.equal(policy.enabled,true);assert.ok(!Array.isArray(policy.accountIds),'Unexpected composition account rollout');assert.ok(!policy.designAccountIds?.length,'Another design rollout active');
 priorDesign={engine:policy.designEngine,accounts:policy.designAccountIds};await db.collection('bf_config').doc('runtime').update({'data.IMAGE_COMPOSITION_POLICY':JSON.stringify({...policy,designEngine:'poster',designAccountIds:[id]})});save();
 await new Promise(r=>setTimeout(r,32000));token=(await request('/api/login',{username:id,password})).data.token;
 const only=process.argv.find(a=>a.startsWith('--only='))?.slice(7);
 for(const entry of require('../tests-fixtures/poster-design-copy-20261104.json').cases.filter(c=>!only||c.id===only))await run(entry);
 const before=(await db.collection('bf_model_calls').where({accountId:id}).count()).total;
 await db.collection('bf_accounts').doc(id).update({expiresAt:new Date(Date.now()-1000)});await request('/api/me');await request('/api/chat',{messages:[{role:'user',content:'你好'}],stream:false},403);await request('/img/image',{prompt:'树',requestId:crypto.randomUUID()},403);
 await db.collection('bf_accounts').doc(id).update({expiresAt:new Date(Date.now()+7200000),quotaOverrideCny:.01,chatUsedCny:1});await request('/api/chat',{messages:[{role:'user',content:'你好'}],stream:false},429);await request('/img/image',{prompt:'树',requestId:crypto.randomUUID()},429);
 const after=(await db.collection('bf_model_calls').where({accountId:id}).count()).total;assert.equal(after,before);report.membership={expiry:[200,403,403],quota:[429,429],additionalProviderCalls:after-before};report.status='completed_pending_visual_review';
 }catch(e){report.status='runner_failed';report.error=String(e.message).replace(/https?:\/\/\S+/g,'[url]').slice(0,220);process.exitCode=1;}
 finally{if(created)try{
  const jobs=(await db.collection('bf_image_jobs').where({accountId:id}).limit(30).get()).data||[];report.jobs=[];
  for(const job of jobs){const row=report.cases.find(r=>r.imageRequestId===job.clientRequestId);const bg=job.asset?.variants?.background?.id;report.jobs.push({requestId:job.clientRequestId,state:job.state,background:!!bg});
   if(bg&&row){const asset=doc(await db.collection('bf_assets').doc(bg).get());assert.equal(asset.accountId,id);const signed=await app.getTempFileURL({fileList:[asset.fileID]});const r=await fetch(signed.fileList[0].tempFileURL);assert.equal(r.status,200);const bytes=Buffer.from(await r.arrayBuffer());row.artworkFile=row.id+'-artwork.'+(bytes[0]===137?'png':'jpg');fs.writeFileSync(path.join(folder,row.artworkFile),bytes);}}
  report.ledger=((await db.collection('bf_model_calls').where({accountId:id}).limit(100).get()).data||[]).map(r=>Object.fromEntries(['kind','model','status','clientRequestId','supplierCostEstimateCny','priceCny'].filter(k=>r[k]!==undefined).map(k=>[k,r[k]])));
  if(jobs.some(j=>['processing','uncertain'].includes(j.state)||(j.state==='done'&&!j.costCommitted))){report.cleanupDeferred=true;report.deferredAccountId=id;}else{
   for(const asset of (await db.collection('bf_assets').where({accountId:id}).limit(100).get()).data||[]){assert.equal(asset.accountId,id);if(asset.fileID)await app.deleteFile({fileList:[asset.fileID]});await db.collection('bf_assets').doc(asset._id).remove();}
   await db.collection('bf_accounts').doc(id).remove();report.temporaryAccountAndAssetsDeleted=true;}
 }catch(e){report.cleanupError=String(e.message).slice(0,180);}
 if(priorDesign)try{const data=doc(await db.collection('bf_config').doc('runtime').get()).data,policy=JSON.parse(data.IMAGE_COMPOSITION_POLICY||'{}');if(policy.designAccountIds?.length===1&&policy.designAccountIds[0]===id){delete policy.designEngine;delete policy.designAccountIds;if(priorDesign.engine!==undefined)policy.designEngine=priorDesign.engine;if(priorDesign.accounts!==undefined)policy.designAccountIds=priorDesign.accounts;await db.collection('bf_config').doc('runtime').update({'data.IMAGE_COMPOSITION_POLICY':JSON.stringify(policy)});report.canaryRestored=true;}else report.restoreSkipped='Concurrent settings changed';}catch{report.restoreFailed=true;process.exitCode=1;}
 save();console.log(JSON.stringify({folder,status:report.status,images:report.cases.filter(r=>r.imageFile).length,cleanupDeferred:!!report.cleanupDeferred}));}
})();
