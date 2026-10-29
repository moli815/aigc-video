const test=require('node:test'),assert=require('node:assert/strict');
const {collect,datesOf,normalize}=require('../cloudfunctions/bf-billing/collector');
function fakeDb(){const docs=new Map();const db={collection:col=>({doc:id=>({get:async()=>({data:docs.has(col+'/'+id)?[docs.get(col+'/'+id)]:[]}),set:async data=>docs.set(col+'/'+id,data)})})};db.runTransaction=fn=>fn(db);return{db,docs};}
test('unconfigured finance credentials produce pending status, never fake a zero bill',async()=>{
 const h=fakeDb();const r=await collect({db:h.db,readers:{}});assert.equal(r.providers.volcengine.status,'awaiting_credentials');assert.equal(r.providers['aliyun-bailian'].status,'awaiting_credentials');assert.equal(h.docs.size,1);assert.equal(r.mutatesMemberBalances,false);
});
test('China day window crosses month correctly',()=>{assert.deepEqual(datesOf(Date.parse('2026-10-31T17:00:00Z')),['2026-11-01','2026-10-31','2026-10-30']);});
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
