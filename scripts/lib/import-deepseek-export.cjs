"use strict";
// Offline finance operation: daily aggregates are not model-call records and do not debit quota.
const crypto = require('node:crypto');
const hash = s => crypto.createHash('sha256').update(s).digest('hex');
const one = r => Array.isArray(r.data) ? r.data[0] : r.data;
const fail = code => { throw Object.assign(new Error(code), {code}); };
function buildImport(data, account, fingerprint, now = new Date()) {
  if (data.schemaVersion !== 1 || data.provider !== 'deepseek' || data.keyAlias !== 'boss AI'
      || !/^[a-f0-9]{64}$/.test(data.sourceDigest) || !/^[a-f0-9]{16}$/.test(fingerprint)
      || !account?._id || !Array.isArray(data.rows) || !data.rows.length || data.rows.length > 62) fail('INVALID_IMPORT');
  const days = new Map(), usage = [], ids = new Set();
  for (const r of data.rows) {
    const start = Date.parse(r.start), end = Date.parse(r.end);
    if (!Number.isFinite(start) || end - start !== 86400000 || !/^\d{4}-\d{2}-\d{2}T00:00:00\+08:00$/.test(r.start)
        || !['deepseek-flash', 'deepseek-v4-pro'].includes(r.model)
        || !['costUnits','requestCount','inputTokens','cachedInputTokens','outputTokens'].every(k => Number.isSafeInteger(r[k]) && r[k] >= 0)
        || r.cachedInputTokens > r.inputTokens) fail('INVALID_IMPORT_ROW');
    const day = r.start.slice(0,10), identity = 'deepseek\0'+fingerprint+'\0'+day;
    const id = hash(identity+'\0'+r.model); if (ids.has(id)) fail('DUPLICATE_IMPORT_ROW'); ids.add(id);
    const row = { currency:'CNY', payableAmount:r.costUnits/1e8, product:'deepseek', model:r.model,
      item:'平台日汇总', usage:r.requestCount, usageUnit:'次请求（含失败）', accountId:account._id,
      accountLabel:account.displayName || account.username, attributionBasis:'owner_instruction',
      requestCount:r.requestCount, inputTokens:r.inputTokens, cachedInputTokens:r.cachedInputTokens,
      outputTokens:r.outputTokens, costBasis:'official_key_usage_export', granularity:'vendor_key_daily' };
    if (!days.has(day)) days.set(day,{id:hash(identity), provider:'deepseek', day,
      granularity:'vendor_key_daily', keyAlias:data.keyAlias, credentialFingerprint:fingerprint,
      accountId:account._id, sourceDigest:data.sourceDigest, sourceFile:data.sourceFile,
      complete:true, finalSettlement:false, reconciliationState:'owner_attributed_export',
      importedAt:now, rows:[], rowCount:0 });
    days.get(day).rows.push(row); days.get(day).rowCount++;
    usage.push({id:'external_bill_'+id, accountId:account._id, kind:'chat', model:r.model,
      tier:r.model==='deepseek-v4-pro'?'pro':'flash', recordType:'vendor_daily_aggregate',
      costCny:row.payableAmount, supplierBilledCny:row.payableAmount, priceCny:null,
      chargeState:'not_debited', costBasis:row.costBasis, state:'committed', requestId:'',
      requestCount:r.requestCount, promptTokens:r.inputTokens, cachedInputTokens:r.cachedInputTokens,
      completionTokens:r.outputTokens, ts:new Date(start), periodEnd:new Date(end),
      provider:'deepseek', credentialFingerprint:fingerprint, sourceDigest:data.sourceDigest,
      attributionBasis:'owner_instruction', importedAt:now });
  }
  return { bills:[...days.values()], usage, totalCny:usage.reduce((s,r)=>s+Math.round(r.costCny*1e8),0)/1e8,
    accountId:account._id, sourceDigest:data.sourceDigest };
}
async function applyImport(db, plan) {
  return db.runTransaction(async tx => {
    if (!one(await tx.collection('bf_accounts').doc(plan.accountId).get())) fail('ACCOUNT_MISSING');
    const existing = [];
    for (const bill of plan.bills) {
      const old = one(await tx.collection('bf_vendor_bills').doc(bill.id).get());
      if (old && old.accountId !== plan.accountId) fail('BILL_WRONG_OWNER');
      if (old && old.sourceDigest !== plan.sourceDigest) {
        for (const row of old.rows || []) {
          const next = bill.rows.find(x => x.model === row.model);
          if (!next || ['requestCount','inputTokens','cachedInputTokens','outputTokens'].some(k=>Number(next[k]) < Number(row[k]))) fail('OLDER_EXPORT');
        }
      }
      existing.push(old);
    }
    const oldUsage=[];
    for(const row of plan.usage){const old=one(await tx.collection('bf_usage_logs').doc(row.id).get());
      if(old&&(old.accountId!==plan.accountId||old.recordType!=='vendor_daily_aggregate'||old.priceCny!=null)) fail('USAGE_CONFLICT');oldUsage.push(old);}
    // Deterministic daily/model IDs replace overlapping snapshots, never append twice.
    for (let i=0;i<plan.bills.length;i++) {
      const bill=plan.bills[i]; const {id,...value}=bill;
      await tx.collection('bf_vendor_bills').doc(id).set({...value, importedAt:existing[i]?.sourceDigest===plan.sourceDigest?existing[i].importedAt:value.importedAt});
    }
    for (let i=0;i<plan.usage.length;i++) {const {id,...value}=plan.usage[i],old=oldUsage[i];
      await tx.collection('bf_usage_logs').doc(id).set({...value, importedAt:old?.sourceDigest===plan.sourceDigest?old.importedAt:value.importedAt});
    }
    return {bills:plan.bills.length,usageRows:plan.usage.length,totalCny:plan.totalCny,quotaChanged:false};
  });
}
module.exports={buildImport,applyImport};
