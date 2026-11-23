'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const migration=require('../cloudfunctions/shared/cost-budget-migration');
const {settleUsage}=require('../cloudfunctions/shared/usage-settlement');
const {settleImageCharge}=require('../cloudfunctions/bf-image/image-billing');
const admission=require('../cloudfunctions/shared/cost-budget-admission');
const imageAdmission=require('../cloudfunctions/bf-image/image-cost-budget');
const {remainingPct}=require('../cloudfunctions/shared/quota-percent');
const now=new Date('2026-11-18T00:30:00+08:00'),anchor=new Date('2026-11-17T11:36:10+08:00');
function fixture(){const rows=[{_id:'u1',accountId:'a',kind:'chat',priceCny:.00002,costCny:.00001,costBasis:'vendor_bill_rate_estimate',ts:now},
 {_id:'u2',accountId:'a',kind:'image',priceCny:.46,costCny:.23,ts:anchor}];
 const account={_id:'a',tier:'plus',chatUsedCny:.00002,imageUsedCny:.46,proUsedCny:0,dayUsedCny:.00002,weekUsedCny:.46002,dayKey:'2026-11-18',weekKey:'2026-11-16',cycleAnchorAt:anchor,expiresAt:new Date('2026-12-17')};
 return{account,rows};}
test('a real remaining balance never becomes a rounded-zero old-app block',()=>{
 assert.equal(remainingPct(79.77,80),.2875);assert.ok(remainingPct(79.99999999,80)>0);assert.equal(remainingPct(80,80),0);assert.equal(remainingPct(81,80),0);assert.equal(remainingPct(0,80),100);
});
function dbOf(entries){const store=new Map(entries);let queue=Promise.resolve();const wrap=docs=>({collection:n=>({doc:id=>({get:async()=>({data:docs.has(n+':'+id)?structuredClone(docs.get(n+':'+id)):null}),set:async v=>docs.set(n+':'+id,structuredClone(v)),update:async v=>{if(!docs.has(n+':'+id))throw Error('MISSING');docs.set(n+':'+id,{...docs.get(n+':'+id),...structuredClone(v)});}})})});
 return{store,runTransaction(fn){const r=queue.then(async()=>{const copy=structuredClone(store),result=await fn(wrap(copy));store.clear();for(const[k,v]of copy)store.set(k,v);return result;});queue=r.catch(()=>{});return r;}};}
test('80-cost conversion preserves sub-cent amounts, current cycle and expiry; old usage stays immutable',async()=>{
 const f=fixture(),p=migration.plan({...f,now});assert.equal(p.after.chatUsedCny,.00001);assert.equal(p.after.imageUsedCny,.23);assert.equal(p.after.dayUsedCny,.00001);assert.equal(p.after.weekUsedCny,.23001);
 const db=dbOf([['bf_accounts:a',f.account]]);const args={plan:p,rows:f.rows,now};
 await db.runTransaction(tx=>migration.apply({...args,tx}));await db.runTransaction(async tx=>assert.equal((await migration.apply({...args,tx})).replayed,true));
 const a=db.store.get('bf_accounts:a');assert.deepEqual(a.expiresAt,f.account.expiresAt);assert.deepEqual(a.cycleAnchorAt,anchor);assert.equal(a.costBudgetPolicy.multiplier,1);
 assert.equal(db.store.get('bf_usage_logs:'+p.eventId).priceCny,-.23001);assert.equal(db.store.size,3);
});
test('conversion rejects other owners, duplicate/missing evidence, partial ledgers, old cycles and changed accounts',async()=>{
 for(const edit of [f=>f.rows[0].accountId='b',f=>f.rows.push(f.rows[0]),f=>f.rows.pop(),f=>f.rows[0].costBasis='',f=>f.rows[0].ts=new Date('2026-11-01'),f=>f.rows[0].costCny=null]){const f=fixture();edit(f);assert.throws(()=>migration.plan({...f,now}));}
 const f=fixture(),p=migration.plan({...f,now}),db=dbOf([['bf_accounts:a',{...f.account,chatUsedCny:.5}]]);
 await assert.rejects(db.runTransaction(tx=>migration.apply({tx,plan:p,rows:f.rows,now})));assert.equal(db.store.size,1);
});
test('an impossible carried-over Pro subtotal is rebuilt from complete cycle evidence; ambiguous subtotals require review',()=>{
 const f=fixture();f.account.proUsedCny=3.291975;const p=migration.plan({...f,now});assert.equal(p.staleProCounterRepaired,true);assert.equal(p.after.proUsedCny,0);assert.equal(p.after.chatUsedCny,.00001);
 f.account.proUsedCny=.00001;assert.throws(()=>migration.plan({...f,now}),/PRO_COUNTER_REQUIRES_REVIEW/);
});
test('a call started before the policy change settles exactly once at cost despite its frozen x2 rate',async()=>{
 const f=fixture(),call={accountId:'a',kind:'chat',provider:'aliyun-bailian',model:'ds',startedAt:now,status:'succeeded',usageSource:'provider_response',inputTokens:1,outputTokens:1,cachedInputTokens:0,rateSnapshot:{provider:'aliyun-bailian',model:'ds',rates:{input:2,output:8,cachedInput:.2},multiplier:2,costBasis:'operator_verified_rate'},settlementMultiplier:2};
 const db=dbOf([['bf_accounts:a',{...f.account,chatUsedCny:0,imageUsedCny:0,costBudgetPolicy:{version:1}}],['bf_model_calls:c',call]]);
 const args={db,accountId:'a',callId:'c',runtime:{USAGE_COST_MULTIPLIER:2},catalog:{},now};
 await Promise.all([settleUsage(args),settleUsage(args)]);assert.equal(db.store.get('bf_accounts:a').chatUsedCny,.00001);
 assert.equal(db.store.get('bf_model_calls:c').supplierCostEstimateCny,.00001);
 assert.equal([...db.store.values()].find(r=>r.modelCallId==='c').supplierBilledCny,null);
});
test('an in-flight image uses cost at transaction time, preserves old replay and prevents cross-owner replay',async()=>{
 const db=dbOf([['bf_accounts:a',{imageUsedCny:0,costBudgetPolicy:{version:1}}]]),args={db,accountId:'a',eventId:'image1',chargeCny:.46,meta:{upstreamCostCny:.23},now};
 const res=await Promise.all([settleImageCharge(args),settleImageCharge(args)]);assert.ok(res.every(r=>r.state==='committed'));assert.equal(db.store.get('bf_accounts:a').imageUsedCny,.23);
 assert.equal(db.store.get('bf_usage_logs:image1').estimated,true);assert.equal(db.store.get('bf_usage_logs:image1').supplierBilledCny,null);
 db.store.set('bf_accounts:b',{imageUsedCny:0});assert.equal((await settleImageCharge({...args,accountId:'b'})).state,'conflict');
 const old={accountId:'a',costCny:.23,priceCny:.46,state:'committed'};db.store.set('bf_billing_events:old',old);
 assert.equal((await settleImageCharge({...args,eventId:'old'})).replayed,true);assert.equal(db.store.get('bf_accounts:a').imageUsedCny,.23);
});
test('concurrent text calls atomically reserve the cost ceiling; unknown results keep their hold, rejection releases once',async()=>{
 const row={accountId:'a',kind:'chat',inputImages:0},snapshot={rates:{input:2,output:8,cachedInput:.2}},payload={messages:[{role:'user',content:'你好'}],max_tokens:1000};
 const bound=admission.upperBound(payload,snapshot,row),account={status:'active',expiresAt:new Date('2026-12-17'),tier:'plus',costBudgetPolicy:{version:1,capCny:bound*1.5}};
 const db=dbOf([['bf_accounts:a',account],['bf_model_calls:c1',row],['bf_model_calls:c2',row]]),args={db,row,payload,snapshot,now};
 const r=await Promise.allSettled(['c1','c2'].map(id=>admission.reserve({...args,id})));assert.equal(r.filter(x=>x.status==='fulfilled').length,1);
 assert.equal(r.find(x=>x.status==='rejected').reason.code,'POOL_EXHAUSTED');assert.equal(db.store.get('bf_accounts:a').supplierReservedCny,bound);
 const id=r[0].status==='fulfilled'?'c1':'c2';await admission.release({db,id,accountId:'b',reason:'rejected',now});assert.equal(db.store.get('bf_accounts:a').supplierReservedCny,bound);
 await admission.release({db,id,accountId:'a',reason:'provider_rejected',now});await admission.release({db,id,accountId:'a',reason:'provider_rejected',now});assert.equal(db.store.get('bf_accounts:a').supplierReservedCny,0);
});
test('actual chat settlement consumes its hold and records tiny verified-usage costs once, not the ceiling',async()=>{
 const row={accountId:'a',kind:'chat',inputImages:0,provider:'p',model:'m',status:'succeeded',usageSource:'provider_response',inputTokens:1,outputTokens:1,cachedInputTokens:0,startedAt:now,rateSnapshot:{provider:'p',model:'m',rates:{input:2,output:8},multiplier:2}},account={status:'active',expiresAt:new Date('2026-12-17'),tier:'plus',costBudgetPolicy:{version:1,capCny:80}};
 const db=dbOf([['bf_accounts:a',account],['bf_model_calls:c',row]]);
 await admission.reserve({db,id:'c',row,payload:{max_tokens:1000,messages:[]},snapshot:row.rateSnapshot,now});
 assert.ok(db.store.get('bf_accounts:a').supplierReservedCny>.001);
 await settleUsage({db,accountId:'a',callId:'c',now});assert.equal(db.store.get('bf_accounts:a').supplierReservedCny,0);assert.equal(db.store.get('bf_accounts:a').chatUsedCny,.00001);
});
test('no silent free call for unknown rates, missing ledger or expiry; vision is bounded and reserved; other tiers keep their pool',async()=>{
 const row={accountId:'a',kind:'chat',inputImages:0},payload={messages:[],max_tokens:1000},snapshot={rates:{input:2,output:8}},base={status:'active',expiresAt:new Date('2026-12-17'),tier:'plus',costBudgetPolicy:{version:1,capCny:80}};
 for(const change of [{snapshot:null},{account:{...base,expiresAt:new Date('2026-10-01')}},{missing:true}]){
  const db=dbOf([['bf_accounts:a',change.account||base],...(!change.missing?[['bf_model_calls:c',row]]:[])]);
  await assert.rejects(admission.reserve({db,id:'c',row,payload,snapshot,now,...change}));assert.equal(db.store.get('bf_accounts:a').supplierReservedCny,undefined);
 }
 // 带图对话不再「无法定界」：必须预留，不能免费放行（2026-11-20 起视觉按张数计价预估）
 const vdb=dbOf([['bf_accounts:a',base],['bf_model_calls:c',row]]);
 await admission.reserve({db:vdb,id:'c',row:{...row,inputImages:1},payload,snapshot,now});
 assert.ok(vdb.store.get('bf_accounts:a').supplierReservedCny>0,'带图对话必须预留');
 const db=dbOf([['bf_accounts:a',{...base,costBudgetPolicy:null,tier:'pro'}],['bf_model_calls:c',row]]);
 await admission.reserve({db,id:'c',row,payload,snapshot,now,runtime:{USAGE_BILLING_MODE:'supplier_cost',USAGE_COST_MULTIPLIER:1,TIERS_OVERRIDE:{pro:{poolCapCny:600}}}});assert.ok(db.store.get('bf_accounts:a').supplierReservedCny>0);
});
test('image versus chat concurrency shares the same pool; delivery and image hold release are one transaction',async()=>{
 const account={status:'active',expiresAt:new Date('2026-12-17'),imageUsedCny:0,chatUsedCny:0,costBudgetPolicy:{version:1,capCny:.3}},row={accountId:'a',kind:'chat',inputImages:0};
 const db=dbOf([['bf_accounts:a',account],['bf_model_calls:c',row]]),img={db,accountId:'a',key:'ih',amountCny:.28,capCny:.3,enabled:true,now:now.getTime()};
 assert.equal((await imageAdmission.reserve(img)).state,'reserved');
 await assert.rejects(admission.reserve({db,id:'c',row,payload:{messages:[],max_tokens:100000},snapshot:{rates:{input:2,output:8}},now}),e=>e.code==='POOL_EXHAUSTED');
 const args={db,accountId:'a',eventId:'i',chargeCny:.56,meta:{upstreamCostCny:.28,imageBudgetId:'ih'},now};
 await Promise.all([settleImageCharge(args),settleImageCharge(args)]);assert.equal(db.store.get('bf_accounts:a').imageUsedCny,.28);assert.equal(db.store.get('bf_accounts:a').imageBudgetReservedCny,0);
 assert.equal(db.store.get('bf_quota_reservations:ih').state,'released');assert.equal((await imageAdmission.reserve({...img,key:'another'})).state,'insufficient');
});
test('an uncertain image keeps its reservation; known failure can release and retry without granting another account the hold',async()=>{
 const db=dbOf([['bf_accounts:a',{status:'active',expiresAt:new Date('2026-12-17')}]]),args={db,accountId:'a',key:'i',amountCny:.28,capCny:80,enabled:true,now:now.getTime()};
 await imageAdmission.reserve(args);assert.equal((await imageAdmission.reserve({...args,accountId:'b'})).state,'conflict');
 await assert.rejects(imageAdmission.release({db,accountId:'b',key:'i',reason:'generation_rejected'}));assert.equal(db.store.get('bf_accounts:a').imageBudgetReservedCny,.28);
 await imageAdmission.release({db,accountId:'a',key:'i',reason:'generation_rejected'});await imageAdmission.release({db,accountId:'a',key:'i',reason:'generation_rejected'});
 assert.equal((await imageAdmission.reserve(args)).state,'reserved');assert.equal(db.store.get('bf_accounts:a').imageBudgetReservedCny,.28);
});
test('group cancellation cannot free a dispatched child budget; cancel/transfer races conserve all reserved money',async()=>{
 const db=dbOf([['bf_accounts:a',{status:'active',expiresAt:new Date('2026-12-17'),costBudgetPolicy:{version:1}}]]),args={db,accountId:'a',key:'group',amountCny:.56,capCny:80,enabled:true,now:now.getTime()};
 await imageAdmission.reserve(args);assert.equal((await imageAdmission.child({...args,key:'child',parentKeys:['group'],amountCny:.28})).state,'reserved');
 assert.equal(db.store.get('bf_accounts:a').imageBudgetReservedCny,.56);assert.equal(db.store.get('bf_quota_reservations:group').amountCny,.28);
 await imageAdmission.release({...args,reason:'cancelled'});assert.equal(db.store.get('bf_accounts:a').imageBudgetReservedCny,.28);
 assert.equal((await imageAdmission.child({...args,key:'late-child',parentKeys:['group'],amountCny:.28})).state,'cancelled');
 await settleImageCharge({db,accountId:'a',eventId:'child-charge',chargeCny:.56,meta:{upstreamCostCny:.28,imageBudgetId:'child'},now});
 assert.equal(db.store.get('bf_accounts:a').imageBudgetReservedCny,0);assert.equal(db.store.get('bf_accounts:a').imageUsedCny,.28);
});

// ── 带图对话的预留预估（2026-11-20 线上 BILLING_UNAVAILABLE 回归）──
const RATES={rates:{input:4,output:16}};
const imgPayload=n=>({max_tokens:1000,messages:[{role:'user',content:[
  {type:'text',text:'请把这张图片做成海报'},
  ...Array.from({length:n},()=>({type:'image_url',image_url:{url:'data:image/png;base64,'+'A'.repeat(400000)}})),
]}]});

test('带一张图的对话必须能算出预留，不得返回 null',()=>{
  const v=admission.upperBound(imgPayload(1),RATES,{kind:'chat',inputImages:1});
  assert.equal(typeof v,'number');
  assert.ok(v>0&&Number.isFinite(v));
});

test('带图对话的预留比纯文本高，且随张数线性增长',()=>{
  const one=admission.upperBound(imgPayload(1),RATES,{kind:'chat',inputImages:1});
  const three=admission.upperBound(imgPayload(3),RATES,{kind:'chat',inputImages:3});
  const none=admission.upperBound({max_tokens:1000,messages:[{role:'user',content:'请把这张图片做成海报'}]},RATES,{kind:'chat',inputImages:0});
  assert.ok(one>none);
  assert.ok(three>one);
});

test('base64 图片内容不得计入字节预估（否则会把正常请求判成额度耗尽）',()=>{
  const withImg=admission.upperBound(imgPayload(1),RATES,{kind:'chat',inputImages:0});
  const plain=admission.upperBound({max_tokens:1000,messages:[{role:'user',content:'请把这张图片做成海报'}]},RATES,{kind:'chat',inputImages:0});
  // 图片被排除后，两者差值只来自消息条数与框架开销，量级必须很小
  assert.ok(Math.abs(withImg-plain)<0.01,`差值过大：${withImg-plain}`);
});

test('缺少费率或非 chat 类型仍返回 null（调用方跳过预留而不是报错）',()=>{
  assert.equal(admission.upperBound(imgPayload(1),null,{kind:'chat',inputImages:1}),null);
  assert.equal(admission.upperBound(imgPayload(1),RATES,{kind:'image',inputImages:1}),null);
});

// ── 跨周期调用：不扣费，但预留必须释放（2026-11-20 线上 hold 泄漏）──
test('跨周期的调用不扣费但要释放预算预留，不能把额度挂死',async()=>{
  const anchor=new Date('2026-11-20T00:00:00Z');
  const call={accountId:'a',kind:'chat',provider:'aliyun-bailian',model:'ds',
    startedAt:new Date('2026-11-19T23:00:00Z'),status:'succeeded',usageSource:'provider_response',
    inputTokens:10,outputTokens:10,cachedInputTokens:0,
    rateSnapshot:{provider:'aliyun-bailian',model:'ds',rates:{input:2,output:8,cachedInput:.2},multiplier:1,costBasis:'operator_verified_rate'},
    budgetHoldCny:0.16,budgetHoldState:'active'};
  const account={status:'active',expiresAt:new Date('2026-12-20'),cycleAnchorAt:anchor,
    chatUsedCny:0,imageUsedCny:0,dayUsedCny:0,weekUsedCny:0,supplierReservedCny:0.16,
    costBudgetPolicy:{version:1,capCny:50}};
  const db=dbOf([['bf_accounts:a',account],['bf_model_calls:c',call]]);
  const r=await settleUsage({db,accountId:'a',callId:'c',runtime:{USAGE_COST_MULTIPLIER:1},catalog:{},now:new Date('2026-11-20T01:00:00Z')});
  assert.equal(r.state,'closed_cycle_review');
  assert.equal(db.store.get('bf_model_calls:c').chargeState,'closed_cycle_review');
  assert.equal(db.store.get('bf_model_calls:c').budgetHoldState,'released');
  assert.equal(db.store.get('bf_accounts:a').supplierReservedCny,0);
  assert.equal(db.store.get('bf_accounts:a').chatUsedCny,0);
});
