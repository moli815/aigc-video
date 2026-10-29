const test=require('node:test'),assert=require('node:assert/strict');
const {windowOf,aggregateFinance}=require('../cloudfunctions/bf-api/domains/finance-report');
const window=windowOf(30,Date.parse('2026-10-29T08:00:00Z'));
test('finance uses China calendar dates and limits its window',()=>{assert.equal(window.start,'2026-09-30');assert.equal(window.end,'2026-10-29');assert.throws(()=>windowOf(NaN));assert.throws(()=>windowOf(1000));});
test('official payable, actual quota debit, and call estimates remain separate',()=>{
 const r=aggregateFinance({window,bills:[{provider:'volcengine',day:'2026-10-29',complete:true,rows:[{currency:'CNY',payableAmount:.12,product:'Seedream',usage:1}]}],calls:[{startedAt:'2026-10-29T07:00Z',supplierCostEstimateCny:.12},{startedAt:'2026-10-29T07:01Z',supplierCostEstimateCny:null}],usage:[{ts:'2026-10-29T07:00Z',priceCny:.24,costCny:.12},{ts:'2026-10-29T07:02Z',kind:'chat',costCny:100,priceCny:.02}]});
 assert.equal(r.officialPayableCny,.12);assert.equal(r.trackedCallEstimateCny,.12);assert.equal(r.userQuotaDebitedCny,.26);assert.equal(r.legacyUnknownCostRows,1);assert.equal(r.unknownCostCalls,1);assert.equal(r.coverage.complete,false);
});
test('refunds and sub-cent amounts survive; partial bills and out-of-window usage cannot inflate costs',()=>{
 const r=aggregateFinance({window,bills:[{provider:'volcengine',day:'2026-10-29',complete:true,rows:[{currency:'CNY',payableAmount:.0000035},{currency:'CNY',payableAmount:-.1}]},{provider:'volcengine',day:'2026-10-28',complete:false,rows:[{currency:'CNY',payableAmount:999}]}],calls:[],usage:[{ts:'2026-01-01',priceCny:999}]});
 assert.equal(r.officialPayableCny,-.0999965);assert.equal(r.userQuotaDebitedCny,0);assert.equal(r.details.length,2);assert.equal(r.finalSettlement,false);
});
test('finance response never leaks provider account, API key identifiers or raw bill instance strings',()=>{
 const r=aggregateFinance({window,bills:[{provider:'aliyun-bailian',day:'2026-10-29',complete:true,rows:[{currency:'CNY',payableAmount:1,instanceId:'PRIVATEKEY;PRIVATEWORKSPACE;deepseek-v4.1-flash-1017;input_token_peak;;0'}]}],calls:[],usage:[]});
 assert.equal(r.details[0].model,'deepseek-v4.1-flash-1017');assert.ok(!JSON.stringify(r).includes('PRIVATE'));
});
test('all thirty calendar dates per platform are required for complete coverage',()=>{
 const bills=[];for(let t=window.startMs;t<=window.endMs;t+=86400000)for(const provider of ['volcengine','aliyun-bailian'])bills.push({provider,day:new Date(t+8*3600000).toISOString().slice(0,10),complete:true,rows:[]});
 assert.equal(aggregateFinance({window,bills,calls:[],usage:[]}).coverage.complete,true);
 bills.pop();assert.equal(aggregateFinance({window,bills,calls:[],usage:[]}).coverage.missing.length,1);
});
