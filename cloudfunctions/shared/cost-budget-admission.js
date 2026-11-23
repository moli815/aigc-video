'use strict';
const {documentOf}=require('./document-store');
const {membershipExpired}=require('./member-access');
const money=n=>Number(n.toFixed(8));
function failure(code){return Object.assign(Error(code),{code});}
// 每张输入图按 1500 token 预估（覆盖常见 1024 级图片的视觉 token 上限）。
// 之前遇到 inputImages>0 直接返回 null，导致**所有带图对话**被 reserve 判为
// BILLING_UNAVAILABLE 而整条请求失败（2026-11-20 线上问题 750f1211… 就是这个）。
const IMAGE_TOKEN_ALLOWANCE = 1500;
function upperBound(payload,snapshot,row){
  if(row.kind!=='chat'||!snapshot?.rates)return null;
  const input=Number(snapshot.rates.input),output=Number(snapshot.rates.output);
  const max=Number(payload.max_completion_tokens??payload.max_tokens??32768);
  if(!Number.isFinite(input)||input<0||!Number.isFinite(output)||output<0||!Number.isSafeInteger(max)||max<1||max>131072)return null;
  // 只统计文本：base64 图片会把字节数撑到百万级，按字节折算 token 会虚高几十倍，
  // 反过来把正常请求判成 POOL_EXHAUSTED。图片单独按张数加成。
  const textMessages=(Array.isArray(payload.messages)?payload.messages:[]).map(m=>{
    if(typeof m?.content==='string')return m.content;
    if(Array.isArray(m?.content))return m.content.filter(p=>p?.type!=='image_url').map(p=>typeof p?.text==='string'?p.text:'').join('');
    return '';
  });
  const imageTokens=Math.max(0,Number(row.inputImages)||0)*IMAGE_TOKEN_ALLOWANCE;
  // Conservative byte fallback: UTF-8 bytes bound byte-BPE token counts;
  // add per-message framing overhead. Cache discounts are not assumed.
  const bytes=Buffer.byteLength(JSON.stringify({messages:textMessages,tools:payload.tools}),'utf8')+(payload.messages?.length||0)*32+256;
  return money(((bytes+imageTokens)*input+max*output)/1e6);
}
async function reserve({db,id,row,payload,snapshot,runtime={},now=new Date()}){
 if(!row.accountId||row.kind!=='chat')return;
 return db.runTransaction(async tx=>{
  const aRef=tx.collection('bf_accounts').doc(row.accountId),a=documentOf(await aRef.get());
  const configured=runtime.USAGE_BILLING_MODE==='supplier_cost'&&Number(runtime.USAGE_COST_MULTIPLIER)===1;
  if(a?.costBudgetPolicy?.version!==1&&!configured)return;
  if(!a||a.status!=='active'||membershipExpired(a.expiresAt,new Date(now).getTime()))throw failure('MEMBERSHIP_EXPIRED');
  const ref=tx.collection('bf_model_calls').doc(id),call=documentOf(await ref.get());
  if(!call||call.accountId!==row.accountId)throw failure('BILLING_UNAVAILABLE');
  if(call.budgetHoldState==='active')return{enabled:true};
  let tiers;try{tiers=typeof runtime.TIERS_OVERRIDE==='string'?JSON.parse(runtime.TIERS_OVERRIDE):runtime.TIERS_OVERRIDE;}catch{throw failure('BILLING_UNAVAILABLE');}
  const tier=a.tier||'plus',policyCap=(!a.costBudgetPolicy?.tier||a.costBudgetPolicy.tier===tier)?a.costBudgetPolicy?.capCny:null,
    cap=Number(a.quotaOverrideCny)>0?Number(a.quotaOverrideCny):Number(policyCap??tiers?.[tier]?.poolCapCny??({plus:80,pro:600,ultra:1100}[tier]));
  const used=Number(a.chatUsedCny||0)+Number(a.imageUsedCny||0),held=Number(a.supplierReservedCny||0),native=Number(a.nativeCopyReservedCny||0)+Number(a.imageBudgetReservedCny||0),amount=upperBound(payload,snapshot,row);
  // 仍然失败关闭：预估不出来说明费率/请求形态有问题，放过就是免费调用。
  // 带图对话已改为按张数定界，不再走这条分支。
  if(![cap,used,held,native].every(n=>Number.isFinite(n)&&n>=0)||amount==null)throw failure('BILLING_UNAVAILABLE');
  if(cap-used-held-native+1e-8<amount)throw failure('POOL_EXHAUSTED');
  await aRef.update({supplierReservedCny:money(held+amount)});
  await ref.update({budgetHoldCny:amount,budgetHoldState:'active',budgetHoldCreatedAt:now});
  return{enabled:true};
 });
}
async function release({db,id,accountId,reason,now=new Date()}){
 return db.runTransaction(async tx=>{
  const ref=tx.collection('bf_model_calls').doc(id),call=documentOf(await ref.get());
  if(!call||call.accountId!==accountId||call.budgetHoldState!=='active')return;
  const aRef=tx.collection('bf_accounts').doc(accountId),a=documentOf(await aRef.get()),held=Number(a?.supplierReservedCny||0);
  if(!a||!Number.isFinite(held)||held+1e-8<call.budgetHoldCny)throw failure('BILLING_HOLD_CONFLICT');
  await aRef.update({supplierReservedCny:money(Math.max(0,held-call.budgetHoldCny))});
  await ref.update({budgetHoldState:'released',budgetHoldReleasedAt:now,budgetHoldReason:reason});
 });
}
module.exports={reserve,release,upperBound,IMAGE_TOKEN_ALLOWANCE};
