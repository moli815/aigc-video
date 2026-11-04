"use strict";
// Recover only this test's supplier-call metadata after an expired operator login.
// Does not charge any customer or repeat a provider request.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {orderIdOf}=require('../cloudfunctions/shared/model-call-ledger');
const c=JSON.parse(fs.readFileSync(path.join(process.env.USERPROFILE,'.config/.cloudbase/auth.json'),'utf8')).credential;
const app=require('../cloudfunctions/bf-api/node_modules/@cloudbase/node-sdk').init({env:'xmy-test-d5g8c0xcifcefcfd5',region:'ap-shanghai',secretId:c.tmpSecretId,secretKey:c.tmpSecretKey,sessionToken:c.tmpToken}),db=app.database();
const root=path.resolve('outputs/qwen-image-migration-20261105'),report=JSON.parse(fs.readFileSync(path.join(root,'report.json'),'utf8'));
const doc=r=>Array.isArray(r.data)?r.data[0]:r.data;
(async()=>{
 const accounts=(await db.collection('bf_accounts').where({displayName:'千问迁移隔离验收'}).get()).data.filter(x=>/^qwen-migration-[a-f0-9]{12}$/.test(x._id));
 const evidence=[];
 for(const row of report.cases.filter(x=>x.imageFile&&x.modelCallId&&x.http===200)){
  assert.ok(fs.existsSync(path.join(root,row.imageFile)));assert.ok(row.vendorRequestId);assert.ok(row.usage);assert.ok(row.supplierEstimateCny>=0);
  const col=db.collection('bf_model_calls');const old=doc(await col.doc(row.modelCallId).get());
  if(old){assert.equal(old.source,'qwen-migration-eval');if(old.status==='succeeded'&&old.evaluationOnly)continue;assert.ok(String(old.accountId).startsWith('qwen-migration-'));}
  if(!old)assert.equal(accounts.length,1,'Cannot infer owner of test audit');
  const accountId=old?.accountId||accounts[0]._id;
  const record={...(old||{}),schemaVersion:1,accountId,source:'qwen-migration-eval',provider:row.model.startsWith('qwen-')?'aliyun-bailian':'volcengine',kind:'image',model:row.model,status:'succeeded',httpStatus:200,
   requestId:row.requestId,orderId:old?.orderId||orderIdOf(accountId,row.requestId),vendorRequestId:row.vendorRequestId,providerResponseId:row.vendorRequestId,
   inputImages:row.inputImages,outputImages:1,requestedSize:row.requestedSize.replace('*','x'),durationMs:row.ms,endedAt:new Date(),startedAt:old?.startedAt||new Date(Date.now()-row.ms),
   currency:'CNY',supplierCostEstimateCny:row.supplierEstimateCny,supplierBilledCny:null,reconciliationState:'pending_vendor_bill',evaluationOnly:true,chargeState:'not_charged',priceCny:null,
   inputTokens:null,outputTokens:null,cachedInputTokens:null,reasoningTokens:null,totalTokens:null,usageSource:'provider_response',costBasis:'official_public_image_rate_estimate',
   auditRecoveredAt:new Date(),auditRecoveryReason:'operator_temporary_credential_expired; local supplier response and generated image retained'};
  delete record._id;await col.doc(row.modelCallId).set(record);evidence.push({callId:row.modelCallId,restored:!old,inputImages:record.inputImages,costEstimate:record.supplierCostEstimateCny});
 }
 const result={at:new Date().toISOString(),recovered:evidence,noNewSupplierCalls:true};fs.writeFileSync(path.join(root,'audit-recovery.json'),JSON.stringify(result,null,2));console.log(JSON.stringify(result));
})().catch(e=>{console.error(e.code||e.name,String(e.message).slice(0,150));process.exitCode=1;});
