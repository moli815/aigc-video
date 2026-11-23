"use strict";
const test=require('node:test'),assert=require('node:assert/strict'),{settleImageCharge}=require('../cloudfunctions/bf-image/image-billing'),{allocateCharge,aggregateCosts}=require('../cloudfunctions/bf-image/native-copy-task');
function fake(){const store=new Map([['bf_accounts:a',{accountId:'a',imageUsedCny:1,dayUsedCny:1,weekUsedCny:1}]]);let queue=Promise.resolve();return{store,runTransaction(fn){const r=queue.then(async()=>{const work=structuredClone(store),result=await fn({collection(name){return{doc(id){const key=name+':'+id;return{get:async()=>({data:work.get(key)||null}),set:async value=>{work.set(key,structuredClone(value));},update:async value=>{if(!work.has(key))throw Error('MISSING');work.set(key,{...work.get(key),...structuredClone(value)});}};}};}});store.clear();for(const [k,v]of work)store.set(k,v);return result;});queue=r.catch(()=>{});return r;}};}
const calls=[{modelCallId:'call_draft',model:'seedream55',supplierCostEstimateCny:.28},{modelCallId:'call_layers',model:'seedream55',supplierCostEstimateCny:.74}];
test('image-only settlements advance China day/week keys atomically and never reset the monthly pool',async()=>{
 const db=fake(),now=new Date('2026-11-16T16:01:00Z'),account=db.store.get('bf_accounts:a');Object.assign(account,{dayKey:'2026-11-16',weekKey:'2026-11-9',dayUsedCny:9,weekUsedCny:19});
 const input={db,accountId:'a',eventId:'rollover-image',chargeCny:.5,meta:{upstreamCostCny:.25},now};
 await Promise.all([settleImageCharge(input),settleImageCharge(input)]);const actual=db.store.get('bf_accounts:a');
 assert.equal(actual.imageUsedCny,1.5);assert.equal(actual.dayUsedCny,.5);assert.equal(actual.weekUsedCny,.5);assert.equal(actual.dayKey,'2026-11-17');assert.equal(actual.weekKey,'2026-11-16');
 await settleImageCharge({...input,eventId:'rollover-image-2'});assert.equal(db.store.get('bf_accounts:a').dayUsedCny,1);
});
test('all provider stages produce one atomic member debit with two attributable calls, even under concurrent replay',async()=>{
 const db=fake(),input={db,accountId:'a',eventId:'bill1',chargeCny:2.04,meta:{upstreamCostCny:1.02,modelCalls:calls,jobKey:'poster1',model:'seedream55'}};
 const results=await Promise.all(Array.from({length:8},()=>settleImageCharge(input)));assert.ok(results.every(r=>r.state==='committed'));
 assert.equal(db.store.get('bf_accounts:a').imageUsedCny,3.04);
 const event=db.store.get('bf_billing_events:bill1'),usage=db.store.get('bf_usage_logs:bill1');assert.equal(event.providerCharges.length,2);assert.equal(event.costCny,1.02);assert.equal(event.priceCny,2.04);assert.equal(usage.estimated,true);
 assert.equal(event.providerCharges.reduce((n,c)=>n+c.priceCny,0),2.04);assert.equal(db.store.size,3);
 assert.equal((await settleImageCharge({...input,accountId:'another'})).state,'conflict');
 assert.equal((await settleImageCharge({...input,meta:{...input.meta,modelCalls:[{...calls[0],modelCallId:'call_other'},calls[1]]}})).state,'conflict');
});
test('unavailable or inconsistent stage costs never charge, while rounding conserves the exact total price',async()=>{
 const db=fake(),base={db,accountId:'a',eventId:'e',chargeCny:2.04,meta:{upstreamCostCny:.5,modelCalls:calls}};
 await assert.rejects(settleImageCharge(base),/COST_CONFLICT/);assert.equal(db.store.size,1);assert.equal(db.store.get('bf_accounts:a').imageUsedCny,1);
 const cost=aggregateCosts(calls),r=allocateCharge(cost,2.01);assert.equal(Number(r.reduce((n,c)=>n+c.priceCny,0).toFixed(4)),2.01);
 assert.throws(()=>allocateCharge(cost,.9),/CHARGE_INVALID/);
});
