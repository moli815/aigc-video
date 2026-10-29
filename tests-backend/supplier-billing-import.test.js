const test=require('node:test'),assert=require('node:assert/strict');
const {collect,datesOf,normalize,createReaders,assertBillDates}=require('../cloudfunctions/bf-billing/collector');
function fakeDb(){const docs=new Map();const db={collection:col=>({doc:id=>({get:async()=>({data:docs.has(col+'/'+id)?[docs.get(col+'/'+id)]:[]}),set:async data=>docs.set(col+'/'+id,data)})})};db.runTransaction=fn=>fn(db);return{db,docs};}
test('unconfigured finance credentials produce pending status, never fake a zero bill',async()=>{
 const h=fakeDb();const r=await collect({db:h.db,readers:{}});assert.equal(r.providers.volcengine.status,'awaiting_credentials');assert.equal(r.providers['aliyun-bailian'].status,'awaiting_credentials');assert.equal(h.docs.size,1);assert.equal(r.mutatesMemberBalances,false);
});
test('China day window crosses month correctly',()=>{assert.deepEqual(datesOf(Date.parse('2026-10-31T17:00:00Z')),['2026-11-01','2026-10-31','2026-10-30']);});
test('30 day backfill crosses month and rejects unbounded dates',()=>{
 const days=datesOf(Date.parse('2026-10-29T08:00Z'),30);assert.equal(days.length,30);assert.equal(days[0],'2026-10-29');assert.equal(days[29],'2026-09-30');
 assert.equal(datesOf(Date.parse('2026-10-29T08:00Z'),5,25)[4],'2026-09-30');assert.throws(()=>datesOf(Date.now(),1000));
});
test('provider pagination imports complete snapshots and rerun replaces provisional data',async()=>{
 const h=fakeDb();let count=0;const reader=async(day,cursor)=>{count++;return{rows:[{instanceID:'i',usage:cursor?'20':'10',pretaxAmount:cursor?0.2:0.1,currency:'CNY'}],next:cursor?null:'next'};};
 const now=Date.parse('2026-10-29T06:00:00Z');const r=await collect({db:h.db,readers:{'aliyun-bailian':reader},now});assert.equal(r.providers['aliyun-bailian'].rows,6);assert.equal(count,6);
 await collect({db:h.db,readers:{'aliyun-bailian':reader},now:now+1000});assert.equal(h.docs.size,4);assert.ok([...h.docs.entries()].filter(([key])=>key.startsWith('bf_vendor_bills/')).every(([,x])=>x.complete&&x.rows.length===2&&!x.finalSettlement));
});
test('failed provider does not block the other provider or change any member account',async()=>{
 const h=fakeDb(),logs=[];const r=await collect({db:h.db,readers:{volcengine:async()=>{throw Object.assign(new Error('PRIVATE_SECRET'),{code:'AccessDenied'});},'aliyun-bailian':async()=>({rows:[],next:null})},log:x=>logs.push(x)});
 assert.equal(r.providers.volcengine.code,'AccessDenied');assert.equal(r.providers['aliyun-bailian'].status,'read_verified');assert.ok(!JSON.stringify(logs).includes('PRIVATE_SECRET'));assert.ok([...h.docs.keys()].every(x=>!x.includes('bf_accounts')));
});
test('partial pagination cannot overwrite previously complete bill',async()=>{
 const h=fakeDb(),now=Date.now();await collect({db:h.db,readers:{volcengine:async()=>({rows:[{PayableAmount:1}],next:null})},now});
 const before=[...h.docs.values()].find(x=>x.provider==='volcengine');const r=await collect({db:h.db,readers:{volcengine:async()=>({rows:[{PayableAmount:999}],next:'next'})},now:now+1000});
 assert.equal(r.providers.volcengine.code,'PAGINATION_LIMIT');assert.equal([...h.docs.values()].find(x=>x.provider==='volcengine'),before);
});
test('negative adjustments and original official money fields survive without leaking unrelated fields',()=>{
 const row=normalize('volcengine',{PayableAmount:'-0.08',ModelName:'m',BillingItem:'token',UnknownAmount:'0.02',SecretKey:'PRIVATE'});assert.equal(row.officialFields.PayableAmount,'-0.08');assert.equal(row.officialFields.UnknownAmount,'0.02');assert.ok(!JSON.stringify(row).includes('PRIVATE'));
});
test('official Volcengine signer compiles a signed HTTPS bill request without exposing keys',async()=>{
 let captured;
   const readers=createReaders({VOLC_BILLING_ACCESS_KEY_ID:'test-id',VOLC_BILLING_ACCESS_KEY_SECRET:'test-secret'},
     {fetch:async(url,options)=>{captured={url,options};return new Response(JSON.stringify({ResponseMetadata:{RequestId:'test-request'},Result:{List:[]}}));}});
   const result=await readers.volcengine('2026-10-29',null);
   const url=new URL(captured.url);assert.equal(url.protocol,'https:');assert.equal(url.hostname,'open.volcengineapi.com');
   assert.equal(url.searchParams.get('Action'),'ListBillDetail');assert.equal(url.searchParams.get('Version'),'2022-01-01');
   const payload=JSON.parse(captured.options.body);
   assert.equal(payload.ExpenseDate,'2026-10-29');assert.equal(result.next,null);
   assert.equal(payload.GroupPeriod,1);assert.equal(payload.GroupTerm,0);
   assert.match(captured.options.headers.Authorization,/^HMAC-SHA256 Credential=test-id\//);
   assert.ok(!JSON.stringify(captured).includes('test-secret'));
});
test('monthly or out-of-day bills are rejected instead of counted once per queried day',()=>{
 assertBillDates([],'2026-10-29',row=>row.ExpenseDate);
 assertBillDates([{ExpenseDate:'2026-10-29'}],'2026-10-29',row=>row.ExpenseDate);
 for(const value of ['',undefined,'2026-10-28','2026-10']) assert.throws(()=>assertBillDates([{ExpenseDate:value}],'2026-10-29',row=>row.ExpenseDate),{code:'BILL_DATE_MISMATCH'});
});
