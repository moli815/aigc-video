"use strict";
const test=require('node:test'),assert=require('node:assert/strict'),crypto=require('node:crypto');
const budget=require('../cloudfunctions/bf-image/native-copy-budget'),{settleImageCharge}=require('../cloudfunctions/bf-image/image-billing');
function fake(){const store=new Map([['bf_accounts:a',{status:'active',expiresAt:new Date(Date.now()+3600000),chatUsedCny:0,imageUsedCny:0,nativeCopyReservedCny:0}]]);let queue=Promise.resolve();return{store,runTransaction(fn){const p=queue.then(async()=>{const rows=structuredClone(store),out=await fn({collection:n=>({doc:id=>({get:async()=>({data:rows.get(n+':'+id)||null}),set:async v=>rows.set(n+':'+id,structuredClone(v)),update:async v=>{const k=n+':'+id;if(!rows.has(k))throw Error('MISSING');rows.set(k,{...rows.get(k),...structuredClone(v)});}})})});store.clear();for(const [k,v]of rows)store.set(k,v);return out;});queue=p.catch(()=>{});return p;}};}
const fp=crypto.createHash('sha256').update('owned immutable request').digest('hex'),input=db=>({db,owner:'a',rid:'job1',fingerprint:fp,amountCny:2,quota:{capCny:3,remainingCny:3,nonNativeReservedCny:0}});
test('native paid stages reserve atomically against concurrent jobs and replay only the same immutable intent',async()=>{
 const db=fake(),base=input(db),r=await Promise.all([budget.reserve(base),budget.reserve({...base,rid:'job2'})]);
 assert.deepEqual(r.map(x=>x.state),['reserved','insufficient']);assert.equal(db.store.get('bf_accounts:a').nativeCopyReservedCny,2);
 assert.equal((await budget.reserve(base)).replayed,true);assert.equal((await budget.reserve({...base,fingerprint:'f'.repeat(64)})).state,'conflict');
 assert.equal((await budget.reserve({...base,amountCny:2.5})).state,'conflict');
 assert.equal(await budget.release({db,owner:'b',key:r[0].key}),false);assert.equal(db.store.get('bf_accounts:a').nativeCopyReservedCny,2);
 assert.equal(await budget.release({db,owner:'a',key:r[0].key,reason:'quality_rejected'}),true);
 assert.equal(await budget.release({db,owner:'a',key:r[0].key}),true);assert.equal(db.store.get('bf_accounts:a').nativeCopyReservedCny,0);
 assert.equal((await budget.reserve(base)).state,'conflict');
});
test('unknown paid outcomes remain held; only definitive no-generation rejection can reacquire a reservation',async()=>{
 const db=fake(),base=input(db),r=await budget.reserve(base),row=db.store.get('bf_quota_reservations:'+r.key);row.expiresAt=1;
 assert.equal((await budget.reserve(base)).state,'reserved');assert.equal((await budget.reserve({...base,rid:'other'})).state,'insufficient');
 assert.equal(await budget.release({db,owner:'a',key:r.key,reason:'primary_rejected'}),true);assert.equal((await budget.reserve(base)).state,'reserved');
 db.store.get('bf_accounts:a').expiresAt=new Date(1);assert.equal((await budget.reserve({...base,rid:'other'})).state,'denied');
});
test('member debit and complete reservation release share one transaction, including old pending-event recovery',async()=>{
 for(const old of [false,true]){
  const db=fake(),r=await budget.reserve(input(db));if(old)db.store.set('bf_billing_events:event',{accountId:'a',priceCny:1,costCny:.5,accountApplied:true,state:'pending'});
  const call={db,accountId:'a',eventId:'event',chargeCny:1,meta:{upstreamCostCny:.5,nativeReservationId:r.key}};
  assert.equal((await settleImageCharge(call)).state,'committed');assert.equal((await settleImageCharge(call)).replayed,true);
  assert.equal(db.store.get('bf_accounts:a').imageUsedCny,old?0:1);assert.equal(db.store.get('bf_accounts:a').nativeCopyReservedCny,0);
  assert.equal(db.store.get('bf_quota_reservations:'+r.key).releaseReason,'settled');
 }
});
test('missing, non-finite or insufficient quota snapshots fail before any hold or member debit',async()=>{
 const db=fake(),base=input(db);for(const quota of [{},{...base.quota,capCny:NaN},{...base.quota,nonNativeReservedCny:Infinity}])assert.equal((await budget.reserve({...base,quota})).state,'unavailable');
 assert.equal((await budget.reserve({...base,quota:{...base.quota,nonNativeReservedCny:2}})).state,'insufficient');assert.equal(db.store.size,1);
});
