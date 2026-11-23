const test=require('node:test'),assert=require('node:assert/strict');
const {buildImport,applyImport}=require('../scripts/lib/import-deepseek-export.cjs');
const {aggregateFinance,windowOf}=require('../cloudfunctions/bf-api/domains/finance-report');
const {aggregateCostRows}=require('../cloudfunctions/bf-api/cost-report');
const account={_id:'customer-1',username:'customer',displayName:'客户',chatUsedCny:10};
const exportData=()=>({schemaVersion:1,provider:'deepseek',keyAlias:'boss AI',sourceDigest:'a'.repeat(64),sourceFile:'usage.zip',rows:[
 {start:'2026-11-05T00:00:00+08:00',end:'2026-11-06T00:00:00+08:00',model:'deepseek-flash',costUnits:638019960,requestCount:282,inputTokens:13440090,cachedInputTokens:9039744,outputTokens:208775}]});
function fixture(){const docs=new Map([['bf_accounts/customer-1',structuredClone(account)]]);
 const api=store=>({collection:col=>({doc:id=>({get:async()=>({data:store.has(col+'/'+id)?[structuredClone(store.get(col+'/'+id))]:[]}),set:async value=>{store.set(col+'/'+id,structuredClone(value));}})})});
 const db=api(docs);db.runTransaction=async fn=>{const snapshot=new Map(structuredClone([...docs]));const result=await fn(api(snapshot));docs.clear();for(const [k,v]of snapshot)docs.set(k,v);return result;};return{db,docs};}
test('daily export preserves exact cost, owner instruction and tokens without fabricating calls or debits',()=>{
 const p=buildImport(exportData(),account,'b'.repeat(16));assert.equal(p.totalCny,6.3801996);assert.equal(p.bills[0].rows[0].accountId,account._id);
 assert.equal(p.usage[0].priceCny,null);assert.equal(p.usage[0].requestId,'');assert.equal(p.usage[0].recordType,'vendor_daily_aggregate');
 assert.equal(p.bills[0].rows[0].attributionBasis,'owner_instruction');assert.ok(!JSON.stringify(p).includes('sk-'));
});
test('replay and overlapping snapshots replace daily amounts; customer allowance is untouched',async()=>{
 const h=fixture(),p=buildImport(exportData(),account,'b'.repeat(16));await applyImport(h.db,p);await applyImport(h.db,p);
 assert.equal(h.docs.size,3);assert.deepEqual(h.docs.get('bf_accounts/customer-1'),account);
 const data=exportData();data.sourceDigest='c'.repeat(64);data.rows[0].costUnits+=10;data.rows[0].requestCount++;
 await applyImport(h.db,buildImport(data,account,'b'.repeat(16)));assert.equal(h.docs.size,3);
 assert.equal(h.docs.get('bf_vendor_bills/'+p.bills[0].id).rows[0].payableAmount,6.3801997);
});
test('wrong account and stale exports fail atomically without changing saved finance rows',async()=>{
 const h=fixture(),p=buildImport(exportData(),account,'b'.repeat(16));await applyImport(h.db,p);const before=JSON.stringify([...h.docs]);
 const wrong=structuredClone(p);wrong.accountId='other';h.docs.set('bf_accounts/other',{_id:'other'});
 await assert.rejects(applyImport(h.db,wrong),{code:'BILL_WRONG_OWNER'});h.docs.delete('bf_accounts/other');assert.equal(JSON.stringify([...h.docs]),before);
 const data=exportData();data.sourceDigest='c'.repeat(64);data.rows[0].requestCount--;
 await assert.rejects(applyImport(h.db,buildImport(data,account,'b'.repeat(16))),{code:'OLDER_EXPORT'});assert.equal(JSON.stringify([...h.docs]),before);
});
test('invalid quantities, repeated models and malformed days cannot be imported',()=>{
 for(const patch of [{costUnits:-1},{inputTokens:1,cachedInputTokens:2},{requestCount:1.2},{end:'2026-11-07T00:00:00+08:00'}]){
  const d=exportData();Object.assign(d.rows[0],patch);assert.throws(()=>buildImport(d,account,'b'.repeat(16)),{code:'INVALID_IMPORT_ROW'});
 }
 const d=exportData();d.rows.push({...d.rows[0]});assert.throws(()=>buildImport(d,account,'b'.repeat(16)),{code:'DUPLICATE_IMPORT_ROW'});
});
test('both admin reports include imported spend exactly once and never count it as customer quota',()=>{
 const p=buildImport(exportData(),account,'b'.repeat(16));const window=windowOf(7,Date.parse('2026-11-06T01:00Z'));
 const r=aggregateFinance({bills:p.bills,calls:[],usage:p.usage,window});assert.equal(r.officialPayableCny,6.3801996);
 assert.equal(r.userQuotaDebitedCny,0);assert.equal(r.unknownCostCalls,0);assert.equal(r.trackedCallEstimateCny,0);
 assert.equal(r.attributedBillCosts[0].accountId,account._id);assert.equal(r.attributedBillCosts[0].requestCount,282);
 assert.equal(r.details[0].model,'deepseek-flash');assert.equal(r.details[0].granularity,'vendor_key_daily');
 const costs=aggregateCostRows(p.usage.map(({id,...row})=>({_id:id,...row})),{startMs:window.startMs,endMs:window.endMs});
 assert.equal(costs.totalCny,6.3801996);assert.equal(costs.topAccounts[0].accountId,account._id);assert.equal(costs.requestCount,0);
});
