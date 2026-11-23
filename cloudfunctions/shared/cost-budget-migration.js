"use strict";
const crypto=require('node:crypto');
const {dayKey,weekKey}=require('./usage-settlement');
const money=n=>Number(n.toFixed(8));
const counters=['chatUsedCny','imageUsedCny','proUsedCny','dayUsedCny','weekUsedCny'];
function requireCost(row){
  if(!['chat','image'].includes(row.kind)||!Number.isFinite(row.costCny)||row.costCny<0||!Number.isFinite(row.priceCny)||row.priceCny<0)
    throw Error('UNVERIFIED_USAGE_ROW');
  if(Math.abs(row.priceCny-2*row.costCny)>0.00011)throw Error('NON_X2_USAGE_REQUIRES_REVIEW');
  if(row.kind==='chat'&&!['vendor_bill_rate_estimate','operator_verified_rate'].includes(row.costBasis))throw Error('UNVERIFIED_CHAT_COST');
  return row.supplierBilledCny==null?row.costCny:row.supplierBilledCny;
}
function plan({account,rows,now=new Date()}){
  if(!account?._id||account.tier!=='plus'||account.costBudgetPolicy||!account.cycleAnchorAt)throw Error('ACCOUNT_NOT_ELIGIBLE');
  const anchor=new Date(account.cycleAnchorAt).getTime();
  if(!Number.isFinite(anchor))throw Error('INVALID_CYCLE');
  const old={chatUsedCny:0,imageUsedCny:0,proUsedCny:0},next={chatUsedCny:0,imageUsedCny:0,proUsedCny:0,dayUsedCny:0,weekUsedCny:0};
  const ids=new Set();
  for(const r of rows){
    const at=r.usageAt||r.ts;
    if(r.accountId!==account._id||!r._id||ids.has(r._id)||!Number.isFinite(new Date(at).getTime())||new Date(at).getTime()<anchor)throw Error('USAGE_SCOPE_CONFLICT');
    ids.add(r._id);const cost=requireCost(r),key=r.kind==='image'?'imageUsedCny':'chatUsedCny';
    if(!Number.isFinite(cost)||cost<0)throw Error('INVALID_COST');
    old[key]+=r.priceCny;next[key]+=cost;
    if(r.tier==='pro'){old.proUsedCny+=r.priceCny;next.proUsedCny+=cost;}
    if(dayKey(at)===dayKey(now))next.dayUsedCny+=cost;
    if(weekKey(at)===weekKey(now))next.weekUsedCny+=cost;
  }
  for(const k of ['chatUsedCny','imageUsedCny'])if(Math.abs(old[k]-Number(account[k]||0))>0.00011)throw Error('COUNTER_LEDGER_MISMATCH');
  const stalePro=old.proUsedCny===0&&Number(account.proUsedCny||0)>Number(account.chatUsedCny||0);
  if(!stalePro&&Math.abs(old.proUsedCny-Number(account.proUsedCny||0))>0.00000002)throw Error('PRO_COUNTER_REQUIRES_REVIEW');
  const before=Object.fromEntries(counters.map(k=>[k,Number(account[k]||0)])),after=Object.fromEntries(counters.map(k=>[k,money(next[k])]));
  const eventId='budget80_v1_'+crypto.createHash('sha256').update(account._id+'\0'+account.cycleAnchorAt).digest('hex').slice(0,40);
  return {accountId:account._id,eventId,cycleAnchorAt:account.cycleAnchorAt,expiresAt:account.expiresAt,
    before,after,dayKey:dayKey(now),weekKey:weekKey(now),originalDayKey:account.dayKey||null,originalWeekKey:account.weekKey||null,
    rowIds:[...ids].sort(),usageHash:crypto.createHash('sha256').update(JSON.stringify([...rows].sort((a,b)=>a._id.localeCompare(b._id)))).digest('hex'),
    capCny:80,multiplier:1,staleProCounterRepaired:stalePro,deltaCny:money(after.chatUsedCny+after.imageUsedCny-before.chatUsedCny-before.imageUsedCny),
    costBasis:rows.every(r=>r.supplierBilledCny!=null)?'supplier_billed':'recorded_usage_rate_provisional_not_invoice'};
}
async function apply({tx,plan:p,rows,now=new Date()}){
  const one=r=>Array.isArray(r.data)?r.data[0]:r.data;
  const eventRef=tx.collection('bf_billing_events').doc(p.eventId),event=one(await eventRef.get());
  if(event){if(event.accountId!==p.accountId||event.usageHash!==p.usageHash)throw Error('MIGRATION_CONFLICT');return{replayed:true};}
  const accountRef=tx.collection('bf_accounts').doc(p.accountId),account=one(await accountRef.get());
  const fresh=plan({account:{...account,_id:p.accountId},rows,now});
  if(JSON.stringify(fresh)!==JSON.stringify(p))throw Error('BASELINE_CHANGED');
  const policy={version:1,tier:'plus',multiplier:1,capCny:80,activatedAt:now,migrationEventId:p.eventId};
  await accountRef.update({...p.after,dayKey:p.dayKey,weekKey:p.weekKey,costBudgetPolicy:policy});
  await eventRef.set({...p,kind:'cost_policy_migration',state:'committed',ts:now});
  await tx.collection('bf_usage_logs').doc(p.eventId).set({accountId:p.accountId,kind:'quota_adjustment',priceCny:p.deltaCny,costCny:0,
    estimated:p.costBasis!=='supplier_billed',supplierBilledCny:null,costBasis:p.costBasis,
    reason:'Remove previous x2 markup; no change to payment, expiry, or original supplier usage',migrationEventId:p.eventId,ts:now});
  return{replayed:false};
}
module.exports={plan,apply,counters};
