"use strict";
// Durable POST-GENERATION typography task. This module never generates a draft,
// debits a member, or retries a paid decomposition whose outcome is unknown.
// A host must separately reserve the bounded total and settle only a done task.
const crypto=require('node:crypto'),{documentOf}=require('./shared/document-store');
const COLLECTION='bf_image_jobs',hash=s=>crypto.createHash('sha256').update(s).digest('hex');
const fail=code=>{throw Object.assign(Error(code),{code});};
const keyOf=(owner,rid)=>'copy_'+hash(owner+'\0'+rid).slice(0,48);
const money=n=>Number(n.toFixed(4));
function aggregateCosts(calls){
 if(!Array.isArray(calls)||!calls.length||calls.length>4)fail('COPY_COST_INVALID');
 const seen=new Map();for(const c of calls){
  if(!c||!/^call_[A-Za-z0-9_-]{1,100}$/.test(c.modelCallId||'')||typeof c.model!=='string'||!c.model||c.model.length>120||!Number.isFinite(c.supplierCostEstimateCny)||c.supplierCostEstimateCny<0)fail('COPY_COST_INVALID');
  const value={modelCallId:c.modelCallId,model:c.model,supplierCostEstimateCny:money(c.supplierCostEstimateCny)};
  if(seen.has(value.modelCallId)&&JSON.stringify(seen.get(value.modelCallId))!==JSON.stringify(value))fail('COPY_COST_CONFLICT');seen.set(value.modelCallId,value);
 }
 const unique=[...seen.values()];return{calls:unique,supplierCostEstimateCny:money(unique.reduce((n,c)=>n+c.supplierCostEstimateCny,0)),costBasis:'configured_provider_usage_estimate_not_invoice'};
}
function allocateCharge(costs,chargeCny){
 const total=aggregateCosts(costs.calls);if(total.supplierCostEstimateCny!==costs.supplierCostEstimateCny||!Number.isFinite(chargeCny)||chargeCny<0||chargeCny<total.supplierCostEstimateCny)fail('COPY_CHARGE_INVALID');
 const cents=Math.round(chargeCny*10000);let assigned=0;
 return total.calls.map((c,index)=>{const units=index===total.calls.length-1?cents-assigned:Math.floor(cents*(total.supplierCostEstimateCny?c.supplierCostEstimateCny/total.supplierCostEstimateCny:1/total.calls.length));assigned+=units;return{...c,priceCny:units/10000};});
}
function descriptor(raw){
 if(!raw||!/^[a-f0-9]{40}$/.test(raw.id||'')||!/^[a-f0-9]{64}$/.test(raw.sha256||'')||!Number.isSafeInteger(raw.byteCount)||raw.byteCount<1||raw.byteCount>24*1024*1024||raw.mime!=='image/png')fail('COPY_ASSET_INVALID');
 return{id:raw.id,sha256:raw.sha256,byteCount:raw.byteCount,mime:raw.mime};
}
function requestOf({owner,requestId,draft,items,model,policyRevision,primaryCall,maxOutputs=3}){
 if(typeof owner!=='string'||!owner||owner.length>160||typeof requestId!=='string'||!requestId||requestId.length>64||!Array.isArray(items)||!items.length||items.length>64||new Set(items.map(t=>t?.key)).size!==items.length||items.some(t=>!t||typeof t.key!=='string'||!t.key||t.key.length>80||!['title','subtitle','body','label','contact','footer'].includes(t.role)||typeof t.text!=='string'||!t.text||t.text.length>1000)||items.reduce((n,t)=>n+t.text.length,0)>8000||typeof model!=='string'||!/^doubao-seedream-5-5-[0-9]+$/.test(model)||typeof policyRevision!=='string'||!policyRevision||policyRevision.length>160)fail('COPY_TASK_INVALID');
 if(!require('./shared/native-copy-policy').validOutputCount(maxOutputs))fail('COPY_TASK_INVALID');
 const input={draft:descriptor(draft),items:items.map(({key,role,text})=>({key,role,text})),model,policyRevision,maxOutputs,primaryCall:aggregateCosts([primaryCall]).calls[0]};
 return{key:keyOf(owner,requestId),fingerprint:hash(JSON.stringify(input)),input};
}
function layerRows(raw){
 if(!Array.isArray(raw)||raw.length<2||raw.length>require('./shared/native-copy-policy').MAX_OUTPUTS)fail('COPY_LAYER_LIMIT');
 const indexes=new Set();return raw.map(r=>{
  if(!r||!Number.isInteger(r.index)||r.index<0||indexes.has(r.index))fail('COPY_LAYER_INVALID');indexes.add(r.index);
  const out={index:r.index,asset:descriptor(r.asset)};
  // Only geometry and recognised style leave the provider adapter. In
  // particular, URLs/base64/HTTP metadata never enter the checkpoint.
  if(r.bounding_box){const b=r.bounding_box.absolute;if(!Array.isArray(b)||b.length!==4||b.some(n=>!Number.isInteger(n)||n<0||n>8192))fail('COPY_LAYER_INVALID');out.bounding_box={absolute:[...b]};}
  if(r.text_recognition){const lines=r.text_recognition.lines;if(!Array.isArray(lines)||lines.length>150)fail('COPY_LAYER_INVALID');
   out.text_recognition={lines:lines.map(l=>{
    const b=l?.bounding_box?.absolute;if(!Array.isArray(b)||b.length!==4||b.some(n=>!Number.isInteger(n)||n<0||n>8192)||!Array.isArray(l.runs)||!l.runs.length||l.runs.length>32)fail('COPY_LAYER_INVALID');
    return{bounding_box:{absolute:[...b]},runs:l.runs.map(s=>{if(typeof s?.text!=='string'||s.text.length>1000||!/^#[A-Fa-f0-9]{6}$/.test(s.style?.foreground_color||''))fail('COPY_LAYER_INVALID');return{text:s.text,style:{foreground_color:s.style.foreground_color,bold:s.style.bold===true}};})};
   })};
  }
  return out;
 });
}
function reviewPlanOf(raw,layers){
 if(!raw||raw.version!==1||!Array.isArray(raw.regions)||!raw.regions.length||raw.regions.length>32)fail('NATIVE_TEXT_SUPPLEMENT_INVALID');
 const ids=new Set(),allowed=new Set(layers.filter(l=>l.index>0).map(l=>l.index));
 const regions=raw.regions.map(r=>{
  if(!r||!/^r\d+$/.test(r.id||'')||ids.has(r.id)||!allowed.has(r.layerIndex)||!Array.isArray(r.box)||r.box.length!==4||r.box.some(n=>!Number.isInteger(n)||n<0||n>8192)||r.box[2]<=r.box[0]||r.box[3]<=r.box[1])fail('NATIVE_TEXT_SUPPLEMENT_INVALID');
  ids.add(r.id);return{id:r.id,layerIndex:r.layerIndex,box:[...r.box]};
 });return{version:1,regions,contact:descriptor(raw.contact)};
}
function transcriptionOf(raw,plan){
 const regions=raw?.regions;if(!Array.isArray(regions)||regions.length!==plan.regions.length)fail('NATIVE_TEXT_SUPPLEMENT_INVALID');
 const allowed=new Set(plan.regions.map(r=>r.id)),seen=new Set();return{regions:regions.map(r=>{
  if(!r||Object.keys(r).some(k=>!['id','text'].includes(k))||!allowed.has(r.id)||seen.has(r.id)||typeof r.text!=='string'||!r.text.trim()||r.text.length>120)fail('NATIVE_TEXT_SUPPLEMENT_INVALID');seen.add(r.id);return{id:r.id,text:r.text};
 })};
}
function createTask({db,verifyAssets,decompose,render,review,supplement,now=Date.now,leaseMs=90000}){
 if(!db?.runTransaction||![verifyAssets,decompose,render].every(fn=>typeof fn==='function')||!Number.isFinite(leaseMs)||leaseMs<1000||leaseMs>240000)fail('COPY_TASK_DEPENDENCIES');
 async function transact(key,work){return db.runTransaction(async tx=>{const ref=tx.collection(COLLECTION).doc(key);return work(ref,documentOf(await ref.get()));});}
 return{async run(request){
  const {key,fingerprint,input}=requestOf(request),owner=request.owner,token=crypto.randomUUID();
  // Ownership is verified even for cached/checkpointed inputs, never inferred
  // from a descriptor or from the fact that another account has the same bytes.
  await verifyAssets(owner,[input.draft]);
  const claimed=await transact(key,async(ref,row)=>{
   if(row&&(row.accountId!==owner||row.copyFingerprint!==fingerprint))return{state:'conflict'};
   if(['done','rejected','needs_review'].includes(row?.copyPhase))return{state:row.copyPhase,row};
   if(['dispatched','supplement_dispatched','uncertain'].includes(row?.copyPhase))return{state:'confirming',row};
   if(row&&row.leaseUntil>now())return{state:'busy'};
   const actions={ready:'render',review_ready:'review',supplement_ready:'supplement',decompose_ready:'decompose'};
   if(row&&!actions[row.copyPhase])return{state:'confirming',row};
   if(row){await ref.update({leaseToken:token,leaseUntil:now()+leaseMs});return{state:actions[row.copyPhase],row};}
   const fresh={accountId:owner,clientRequestId:request.requestId,kind:'native_copy_stage',state:'copy_stage',copyPhase:'dispatched',copyFingerprint:fingerprint,input,costCommitted:true,leaseToken:token,leaseUntil:now()+leaseMs,createdAt:now(),updatedAt:now(),calls:[input.primaryCall]};
   await ref.set(fresh);return{state:'decompose',row:fresh};
  });
  if(!['decompose','render','review','supplement'].includes(claimed.state))return{state:claimed.state,key,...(claimed.row?.costs?{costs:claimed.row.costs}:{}),...(claimed.state==='done'?{asset:claimed.row.asset}:{}),...(claimed.state==='rejected'?{diagnostic:claimed.row.diagnostic}:{})};
  const update=async patch=>transact(key,async(ref,row)=>{
   if(!row||row.accountId!==owner||row.copyFingerprint!==fingerprint||row.leaseToken!==token)fail('COPY_LEASE_CHANGED');
   await ref.update({...patch,updatedAt:now()});return{...row,...patch};
  });
  let row=claimed.row;
  if(claimed.state==='decompose'){
   try{
    // Adapter MUST ledger-track this ONE request and archive each output to the
    // owner before returning. A transport/archive failure is uncertain, not a
    // license to issue another paid request after lease expiry.
    row=await update({copyPhase:'dispatched'});
    const response=await decompose({owner,draft:input.draft,items:input.items,model:input.model,maxOutputs:input.maxOutputs,requestId:request.requestId});
    const additional=Array.isArray(response.calls)?response.calls:[response.call];
    if(additional.some(c=>c?.modelCallId===input.primaryCall.modelCallId))fail('COPY_COST_CONFLICT');
    const calls=aggregateCosts([input.primaryCall,...additional]);
    // Keep known paid-call costs even when returned layer metadata, ownership
    // or archiving is invalid. The independent provider ledger remains primary.
    row=await update({costs:calls,calls:calls.calls});
    const layers=layerRows(response.layers);
    if(layers.length>input.maxOutputs)fail('COPY_LAYER_LIMIT');
    await verifyAssets(owner,layers.map(r=>r.asset));
    row=await update({copyPhase:review?'review_ready':'ready',layers,costs:calls,calls:calls.calls});
   }catch(e){
    if(e?.code==='COPY_NOT_DISPATCHED'){await update({copyPhase:'decompose_ready',leaseUntil:0});return{state:'retry_local',key};}
    if(e?.code==='NATIVE_TEXT_PROVIDER_REJECTED'){
     const costs=aggregateCosts(row.calls);await update({copyPhase:'rejected',leaseUntil:0,diagnostic:e.code,costs});
     return{state:'rejected',key,diagnostic:e.code,costs};
    }
    await update({copyPhase:'uncertain',leaseUntil:0,diagnostic:'COPY_DECOMPOSITION_UNCONFIRMED'});
    return{state:'confirming',key,diagnostic:'COPY_DECOMPOSITION_UNCONFIRMED',...(row.costs?{costs:row.costs}:{})};
   }
  }
  if(row.copyPhase==='review_ready'){
   try{
    row=await update({reviewAttempts:Number(row.reviewAttempts||0)+1});
    await verifyAssets(owner,row.layers.map(l=>l.asset));
    const decision=await review({owner,draft:row.input.draft,items:row.input.items,layers:row.layers});
    if(decision.needsSupplement){
     if(typeof supplement!=='function')fail('NATIVE_TEXT_RECOGNITION_INCOMPLETE');
     const reviewPlan=reviewPlanOf(decision.plan,row.layers);await verifyAssets(owner,[reviewPlan.contact]);
     row=await update({copyPhase:'supplement_ready',reviewPlan});
    }else row=await update({copyPhase:'ready'});
   }catch(e){
    const code=e?.code||'',quality=/^NATIVE_TEXT_[A-Z_]+$/.test(code),state=quality?'rejected':row.reviewAttempts>=3?'needs_review':'retry_local';
    await update({copyPhase:state==='retry_local'?'review_ready':state,leaseUntil:0,diagnostic:quality?code:'COPY_REVIEW_RETRY_REQUIRED'});return{state,key,costs:row.costs};
   }
  }
  if(row.copyPhase==='supplement_ready'){
   try{
    await verifyAssets(owner,[row.reviewPlan.contact]);row=await update({copyPhase:'supplement_dispatched'});
    const response=await supplement({owner,plan:row.reviewPlan,requestId:request.requestId});
    if(row.calls.some(c=>c.modelCallId===response.call?.modelCallId))fail('COPY_COST_CONFLICT');
    const costs=aggregateCosts([...row.calls,response.call]);row=await update({costs,calls:costs.calls});
    const transcript=transcriptionOf(response.transcription,row.reviewPlan);
    row=await update({copyPhase:'ready',transcript});
   }catch(e){
    if(e?.code==='COPY_NOT_DISPATCHED'){await update({copyPhase:'supplement_ready',leaseUntil:0});return{state:'retry_local',key,costs:row.costs};}
    const quality=/^NATIVE_TEXT_[A-Z_]+$/.test(e?.code||'');
    await update({copyPhase:quality?'rejected':'uncertain',leaseUntil:0,diagnostic:quality?e.code:'COPY_SUPPLEMENT_UNCONFIRMED'});
    return{state:quality?'rejected':'confirming',key,costs:row.costs};
   }
  }
  try{
   row=await update({localAttempts:Number(row.localAttempts||0)+1});
   await verifyAssets(owner,[row.input.draft,...row.layers.map(l=>l.asset)]);
   // Renderer reads only owned immutable originals and all required fields.
   const result=await render({owner,draft:row.input.draft,items:row.input.items,layers:row.layers,policyRevision:row.input.policyRevision,reviewPlan:row.reviewPlan,transcript:row.transcript});
   const asset=descriptor(result.asset);await verifyAssets(owner,[asset]);
   row=await update({copyPhase:'done',asset,leaseUntil:0});return{state:'done',key,asset,costs:row.costs};
  }catch(e){
   const glyphInvalid=/^GLYPH_(FONT_INVALID|MISSING|EMPTY|LAYOUT_INVALID|SHAPING_UNSUPPORTED|WIDTH_OVERFLOW|HEIGHT_OVERFLOW|COPY_LOSS|OUTLINE_CLIPPED|COLOR_INVALID|WORKER_INPUT)$/.test(e?.code||'');
   const diagnostic=glyphInvalid?'NATIVE_TEXT_GLYPH_LAYOUT_UNSAFE':/^(NATIVE_TEXT_|SURFACE_)[A-Z_]+$/.test(e?.code||'')?e.code:'COPY_LOCAL_RETRY_REQUIRED';
   if(diagnostic!=='COPY_LOCAL_RETRY_REQUIRED'){await update({copyPhase:'rejected',diagnostic,leaseUntil:0});return{state:'rejected',key,diagnostic,costs:row.costs};}
   const exhausted=row.localAttempts>=3;
   await update({copyPhase:exhausted?'needs_review':'ready',diagnostic,leaseUntil:0});return{state:exhausted?'needs_review':'retry_local',key,costs:row.costs};
  }
 }};
}
module.exports={createTask,aggregateCosts,allocateCharge,keyOf,requestOf,reviewPlanOf,transcriptionOf};
