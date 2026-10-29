const test=require('node:test'),assert=require('node:assert/strict');
const {catalogFromBills,ratesFor,quoteCall,imageQuote}=require('../cloudfunctions/shared/supplier-pricing');
const {settleUsage}=require('../cloudfunctions/shared/usage-settlement');
const model='deepseek-v4.1-flash-1017',provider='aliyun-bailian',now=new Date('2026-10-29T07:40:00Z');
const runtime={USAGE_COST_MULTIPLIER:2};
function bills(){return[{provider,day:'2026-10-28',complete:true,rows:[['input_token_peak',523.199,1.046398],['output_token_peak',71.437,.571496],['input_token_cache_peak',795.136,.1590272],['input_token_offpeak',61.528,.061528],['output_token_offpeak',5.575,.0223],['input_token_cache_offpeak',40.96,.004096]].map(([tag,usage,payableAmount])=>({product:'sfm',currency:'CNY',item:'token_number',usageUnit:'千tokens',usage,payableAmount,instanceId:'key;workspace;'+model+';'+tag+';;0'}))}];}
const catalog=catalogFromBills(bills());
function call(override={}){return{_id:'call_one',kind:'chat',accountId:'a',provider,model,status:'succeeded',usageSource:'provider_response',inputTokens:3000,outputTokens:500,cachedInputTokens:2000,startedAt:now,chargeState:'not_recorded',orderId:'ord_one',requestId:'r',...override};}
function fakeDb(c=call()){
 let docs=new Map([['bf_accounts/a',{chatUsedCny:0,imageUsedCny:0,dayUsedCny:0,weekUsedCny:0,cycleAnchorAt:new Date('2026-10-01')}],['bf_model_calls/call_one',c]]),lock=Promise.resolve(),fail=false;
 const make=store=>({collection:col=>({doc:id=>({get:async()=>({data:store.has(col+'/'+id)?[structuredClone(store.get(col+'/'+id))]:[]}),set:async v=>{if(fail&&col==='bf_usage_logs')throw Error('disk');store.set(col+'/'+id,structuredClone(v));},update:async v=>store.set(col+'/'+id,{...store.get(col+'/'+id),...structuredClone(v)})})})});
 const db=make(docs);db.runTransaction=fn=>{const work=lock.then(async()=>{const copy=structuredClone(docs),out=await fn(make(copy));docs.clear();for(const [k,v]of copy)docs.set(k,v);return out;});lock=work.catch(()=>{});return work;};
 return{db,docs,fail:()=>{fail=true;}};
}
test('real bill examples derive exact peak/cache/offpeak rates without whole-bill allocation',()=>{
 assert.deepEqual(catalog.models[provider+':'+model],{billDay:'2026-10-28',peak:{input:2,output:8,cachedInput:.2},offpeak:{input:1,output:4,cachedInput:.1}});
 assert.equal(catalog.perRequestInvoice,false);assert.ok(!JSON.stringify(catalog).includes('workspace'));
});
test('actual usage x supplier rates x 2 accounts for cache discount and preserves sub-cent charges',()=>{
 const q=quoteCall(call(),ratesFor(catalog,runtime,provider,model,now));assert.equal(q.supplierCostCny,.0064);assert.equal(q.priceCny,.0128);
 const small=call({inputTokens:1,outputTokens:1,cachedInputTokens:0});assert.equal(quoteCall(small,ratesFor(catalog,runtime,provider,model,now)).priceCny,.00002);
});
test('China offpeak window is 22:00 inclusive to 08:00 exclusive',()=>{
 for(const [time,period]of [['2026-10-29T13:59:59Z','peak'],['2026-10-29T14:00:00Z','offpeak'],['2026-10-29T23:59:59Z','offpeak'],['2026-10-30T00:00:00Z','peak']]) assert.equal(ratesFor(catalog,runtime,provider,model,new Date(time)).period,period);
 assert.equal(quoteCall(call(),ratesFor(catalog,runtime,provider,model,new Date('2026-10-29T15:00Z'))).priceCny,.0064);
});
test('missing usage, cache count, provider mismatch, response model change and unknown outcome never receive a guessed charge',()=>{
 const s=ratesFor(catalog,runtime,provider,model,now);
 for(const change of [{inputTokens:null},{cachedInputTokens:null},{cachedInputTokens:4000},{model:'other'},{provider:'other'},{status:'outcome_unknown'},{usageSource:'estimated'}])assert.equal(quoteCall(call(change),s),null);
 assert.equal(ratesFor(catalog,runtime,'another-vendor',model,now),null);
 const incomplete={models:{[provider+':'+model]:{peak:{input:2,output:8}}}};
 assert.equal(ratesFor(incomplete,runtime,provider,model,new Date('2026-10-29T15:00Z')),null);
});
test('ambiguous rates, resource packages, negative adjustment and coupons require review; no averaging across keys',()=>{
 for(const extra of [{resourcePackageDeduction:1},{couponDeduction:1},{adjustAmount:-.1},{payableAmount:0}]){
 const b=bills();Object.assign(b[0].rows[0],extra);const c=catalogFromBills(b);assert.equal(c.models[provider+':'+model].peak.input,undefined);assert.ok(c.issues.length);
 }
 const b=bills();b[0].rows.push({...b[0].rows[0],payableAmount:2});assert.equal(catalogFromBills(b).models[provider+':'+model].peak.input,undefined);
});
test('transaction atomically separates supplier cost from charge; repeat and parallel settlement debit exactly once',async()=>{
 const h=fakeDb(),args={db:h.db,accountId:'a',callId:'call_one',catalog,runtime,now};
 const r=await Promise.all([settleUsage(args),settleUsage(args),settleUsage(args)]);assert.ok(r.every(x=>x.state==='committed'));
 assert.equal(h.docs.get('bf_accounts/a').chatUsedCny,.0128);const rows=[...h.docs.entries()].filter(([k])=>k.startsWith('bf_usage_logs/'));assert.equal(rows.length,1);
 assert.equal(rows[0][1].costCny,.0064);assert.equal(rows[0][1].priceCny,.0128);assert.equal(rows[0][1].supplierBilledCny,null);
});
test('transaction failure never leaves account debited without a matching ledger row',async()=>{
 const h=fakeDb();h.fail();await assert.rejects(settleUsage({db:h.db,accountId:'a',callId:'call_one',catalog,runtime,now}));assert.equal(h.docs.get('bf_accounts/a').chatUsedCny,0);assert.equal(h.docs.get('bf_model_calls/call_one').chargeState,'not_recorded');
});
test('unknown rate is pending, later verified rates settle once, wrong account cannot debit',async()=>{
 const h=fakeDb(),args={db:h.db,accountId:'a',callId:'call_one',runtime,now};
 assert.equal((await settleUsage({...args,catalog:{}})).state,'pending_cost');assert.equal(h.docs.get('bf_accounts/a').chatUsedCny,0);
 assert.equal((await settleUsage({...args,catalog,accountId:'b'})).state,'call_missing_or_wrong_owner');
 assert.equal((await settleUsage({...args,catalog})).priceCny,.0128);
});
test('late settlement never consumes today allowance or a renewed membership cycle',async()=>{
 const h=fakeDb(call({startedAt:new Date('2026-10-21T07:40Z')}));
 await settleUsage({db:h.db,accountId:'a',callId:'call_one',catalog,runtime,now});const a=h.docs.get('bf_accounts/a');assert.equal(a.chatUsedCny,.0128);assert.equal(a.dayUsedCny,0);assert.equal(a.weekUsedCny,0);
 const h2=fakeDb(call({startedAt:new Date('2026-09-21T07:40Z')}));assert.equal((await settleUsage({db:h2.db,accountId:'a',callId:'call_one',catalog,runtime,now})).state,'closed_cycle_review');assert.equal(h2.docs.get('bf_accounts/a').chatUsedCny,0);
});
test('legacy poster path also uses actual Pro resolution and reference count, never its old flat .45 price',()=>{
 assert.equal(imageQuote('doubao-seedream-5-0-pro-260628','2K',1,runtime).priceCny,1.2);
 assert.equal(imageQuote('doubao-seedream-5-0-pro-260628','1536x1536',3,runtime).priceCny,.68);
 assert.equal(imageQuote('doubao-seedream-5-0-flash-260915','2K',3,runtime).priceCny,.24);
 assert.equal(imageQuote('unknown','2K',1,runtime),null);
});
