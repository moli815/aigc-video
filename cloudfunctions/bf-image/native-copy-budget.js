"use strict";
const crypto=require('node:crypto'),{documentOf}=require('./shared/document-store'),{membershipExpired}=require('./shared/member-access');
const money=n=>Number(Number(n).toFixed(4));
const keyOf=(owner,rid)=>'native_copy_'+crypto.createHash('sha256').update(owner+'\0'+rid).digest('hex').slice(0,48);
async function reserve({db,owner,rid,fingerprint,amountCny,quota,now=Date.now()}){
 if(!owner||!rid||!/^[a-f0-9]{64}$/.test(fingerprint||'')||!Number.isFinite(amountCny)||amountCny<=0||!Number.isFinite(quota?.capCny)||quota.capCny<=0||!Number.isFinite(quota.remainingCny)||!Number.isFinite(quota.nonNativeReservedCny))return{state:'unavailable'};
 const key=keyOf(owner,rid),amount=money(amountCny);
 return db.runTransaction(async tx=>{
  const ref=tx.collection('bf_quota_reservations').doc(key),row=documentOf(await ref.get());
  if(row&&(row.accountId!==owner||row.fingerprint!==fingerprint||row.amountCny!==amount||row.kind!=='native_copy'))return{state:'conflict'};
  if(row?.state==='active')return{state:'reserved',key,replayed:true};
  if(row&&!(row.state==='released'&&['primary_rejected','preflight_failed'].includes(row.releaseReason)))return{state:'conflict'};
  const accountRef=tx.collection('bf_accounts').doc(owner),account=documentOf(await accountRef.get());
  if(!account||account.status!=='active'||membershipExpired(account.expiresAt,now))return{state:'denied'};
  const used=Number(account.chatUsedCny||0)+Number(account.imageUsedCny||0),held=Number(account.nativeCopyReservedCny||0);
  if(!Number.isFinite(used)||used<0||!Number.isFinite(held)||held<0)return{state:'unavailable'};
  const concurrent=Number(account.supplierReservedCny||0)+Number(account.imageBudgetReservedCny||0);
  if(!Number.isFinite(concurrent)||concurrent<0)return{state:'unavailable'};
  if(Math.min(quota.remainingCny,quota.capCny-used-held-Math.max(quota.nonNativeReservedCny,concurrent))+1e-6<amount)return{state:'insufficient'};
  await accountRef.update({nativeCopyReservedCny:money(held+amount)});
  await ref.set({accountId:owner,kind:'native_copy',fingerprint,amountCny:amount,state:'active',createdAt:now,expiresAt:now+3600000});
  return{state:'reserved',key,replayed:false};
 });
}
async function release({db,owner,key,reason,now=Date.now()}){
 return db.runTransaction(async tx=>{
  const ref=tx.collection('bf_quota_reservations').doc(key),row=documentOf(await ref.get());
  if(!row||row.accountId!==owner||row.kind!=='native_copy')return false;
  if(row.state==='released')return true;if(row.state!=='active')return false;
  const accountRef=tx.collection('bf_accounts').doc(owner),account=documentOf(await accountRef.get()),held=Number(account?.nativeCopyReservedCny||0);
  if(!account||!Number.isFinite(held)||held+1e-6<row.amountCny)return false;
  await accountRef.update({nativeCopyReservedCny:money(held-row.amountCny)});
  await ref.update({state:'released',releasedAt:now,releaseReason:String(reason||'quality_rejected').slice(0,40)});return true;
 });
}
module.exports={reserve,release,keyOf};
