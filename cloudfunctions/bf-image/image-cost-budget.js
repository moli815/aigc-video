'use strict';
const {documentOf}=require('./shared/document-store'),{membershipExpired}=require('./shared/member-access');
const money=n=>Number(n.toFixed(8));
async function reserve({db,accountId,key,amountCny,capCny,enabled,kind='single',now=Date.now()}){
 if(!enabled)return{state:'inactive'};
 if(!key||!accountId||!Number.isFinite(amountCny)||amountCny<=0||!Number.isFinite(capCny)||capCny<=0)return{state:'unavailable'};
 return db.runTransaction(async tx=>{
  const ref=tx.collection('bf_quota_reservations').doc(key),r=documentOf(await ref.get());
  if(r&&!(r.accountId===accountId&&r.kind==='image_budget'&&r.state==='released'&&r.releaseReason==='generation_rejected'))return r.accountId===accountId&&r.kind==='image_budget'&&r.amountCny===amountCny&&r.state==='active'?{state:'reserved',key,replayed:true}:{state:'conflict'};
  const aRef=tx.collection('bf_accounts').doc(accountId),a=documentOf(await aRef.get());
  if(!a||a.status!=='active'||membershipExpired(a.expiresAt,now))return{state:'denied'};
  const used=Number(a.chatUsedCny||0)+Number(a.imageUsedCny||0),held=Number(a.imageBudgetReservedCny||0),other=Number(a.supplierReservedCny||0)+Number(a.nativeCopyReservedCny||0);
  if(a.costBudgetPolicy?.version===1&&(!a.costBudgetPolicy.tier||a.costBudgetPolicy.tier===a.tier))capCny=Math.min(capCny,Number(a.quotaOverrideCny)>0?Number(a.quotaOverrideCny):Number(a.costBudgetPolicy.capCny||capCny));
  if(![used,held,other].every(n=>Number.isFinite(n)&&n>=0))return{state:'unavailable'};
  if(capCny-used-held-other+1e-8<amountCny)return{state:'insufficient'};
  await aRef.update({imageBudgetReservedCny:money(held+amountCny)});
  // No TTL refund after dispatch: unknown outcomes require reconciliation.
  await ref.set({accountId,kind:'image_budget',taskKind:kind,amountCny,state:'active',createdAt:now});return{state:'reserved',key};
 });
}
async function releaseInTransaction({tx,accountId,key,account,reason,now=Date.now()}){
 const ref=tx.collection('bf_quota_reservations').doc(key),r=documentOf(await ref.get());
 if(!r||r.accountId!==accountId||r.kind!=='image_budget')throw Error('IMAGE_BUDGET_CONFLICT');
 if(r.state==='released')return 0;
 const held=Number(account.imageBudgetReservedCny||0);
 if(r.state!=='active'||!Number.isFinite(held)||held+1e-8<r.amountCny)throw Error('IMAGE_BUDGET_CONFLICT');
 await ref.update({state:'released',releasedAt:now,releaseReason:reason});return r.amountCny;
}
async function release({db,accountId,key,reason,now=Date.now()}){
 return db.runTransaction(async tx=>{const ref=tx.collection('bf_accounts').doc(accountId),account=documentOf(await ref.get());if(!account)throw Error('ACCOUNT_MISSING');
  const amount=await releaseInTransaction({tx,accountId,key,account,reason,now});if(amount)await ref.update({imageBudgetReservedCny:money(Math.max(0,Number(account.imageBudgetReservedCny||0)-amount))});return true;});
}
// Move budget to a child before dispatch. Cancelling the group releases only
// unstarted work; in-flight children keep their own protected reservations.
async function child({db,accountId,key,parentKeys,amountCny,capCny,now=Date.now()}){
 const transferred=await db.runTransaction(async tx=>{
  const ref=tx.collection('bf_quota_reservations').doc(key),existing=documentOf(await ref.get());
  if(existing?.state==='active')return existing.accountId===accountId&&existing.kind==='image_budget'&&existing.amountCny===amountCny?{state:'reserved',key,replayed:true}:{state:'conflict'};
  if(existing&&!(existing.accountId===accountId&&existing.state==='released'&&existing.releaseReason==='generation_rejected'))return{state:'conflict'};
  for(const parentKey of parentKeys){const pRef=tx.collection('bf_quota_reservations').doc(parentKey),parent=documentOf(await pRef.get());
   if(!parent)continue;
   if(parent.accountId!==accountId||parent.kind!=='image_budget')return{state:'conflict'};
   if(parent.state==='released')return parent.releaseReason==='cancelled'?{state:'cancelled'}:{state:'standalone'};
   if(parent.state!=='active')return{state:'conflict'};
   if(parent.amountCny+1e-8<amountCny)return{state:'standalone'};
   await pRef.update({amountCny:money(Math.max(0,parent.amountCny-amountCny))});
   await ref.set({accountId,kind:'image_budget',taskKind:'child',parentKey,amountCny,state:'active',createdAt:now});return{state:'reserved',key};
  }return{state:'standalone'};
 });
 return transferred.state==='standalone'?reserve({db,accountId,key,amountCny,capCny,enabled:true,now}):transferred;
}
module.exports={reserve,release,releaseInTransaction,child};
