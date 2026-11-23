"use strict";
const test=require('node:test'),assert=require('node:assert/strict'),mod=require('../cloudfunctions/bf-image/native-copy-task');
function fakeDb(){const store=new Map();let queue=Promise.resolve();return{store,runTransaction(work){const run=queue.then(async()=>{const staged=structuredClone(store),result=await work({collection(name){return{doc(id){const key=name+':'+id;return{async get(){return{data:staged.get(key)||null};},async set(v){staged.set(key,structuredClone(v));},async update(v){if(!staged.has(key))throw Error('MISSING');staged.set(key,{...staged.get(key),...structuredClone(v)});}};}};}});store.clear();for(const [k,v]of staged)store.set(k,v);return result;});queue=run.catch(()=>{});return run;}};}
const asset=n=>({id:String(n).repeat(40),sha256:String(n).repeat(64),mime:'image/png',byteCount:100});
const primary={modelCallId:'call_primary',model:'doubao-seedream-5-5-261028',supplierCostEstimateCny:.28};
const secondary={modelCallId:'call_layers',model:primary.model,supplierCostEstimateCny:.74};
function request(){return{owner:'alice',requestId:'poster1',draft:asset(1),items:[{key:'body',role:'body',text:'这是客户确认的完整正文，不能在重试时删除。'}],model:primary.model,policyRevision:'fontsha400-and-v1',primaryCall:primary};}
function setup(){const db=fakeDb(),counts={decompose:0,render:0},owned=new Map([[asset(1).id,'alice'],[asset(2).id,'alice'],[asset(3).id,'alice']]);
 const deps={db,verifyAssets:async(owner,descs)=>{if(descs.some(d=>owned.get(d.id)!==owner))throw Error('FOREIGN_ASSET');},decompose:async()=>{counts.decompose++;return{call:secondary,layers:[{index:0,asset:asset(2),url:'https://not-saved.invalid/?token=never'},{index:1,asset:asset(3),bounding_box:{absolute:[0,0,200,200]},text_recognition:{lines:[{bounding_box:{absolute:[2,2,190,30]},runs:[{text:'这是客户确认的完整正文，不能在重试时删除。',style:{foreground_color:'#141414'}}]}]}}]};},render:async()=>{counts.render++;return{asset:asset(3)};}};
 return{db,counts,deps,owned};}
test('render/storage restart resumes immutable layers and settles no account inside the typography task',async()=>{
 const s=setup();s.deps.render=async()=>{s.counts.render++;if(s.counts.render===1)throw Error('STORE_UNAVAILABLE');return{asset:asset(3)};};
 const first=await mod.createTask(s.deps).run(request());assert.equal(first.state,'retry_local');
 const second=await mod.createTask(s.deps).run(request());assert.equal(second.state,'done');assert.equal(second.costs.supplierCostEstimateCny,1.02);
 const replay=await mod.createTask(s.deps).run(request());assert.equal(replay.state,'done');assert.equal(s.counts.decompose,1);assert.equal(s.counts.render,2);
 const persisted=JSON.stringify([...s.db.store]);assert.ok(!persisted.includes('https:'));assert.ok(!persisted.includes('base64'));assert.ok(!persisted.includes('bf_accounts'));assert.ok(!persisted.includes('bf_billing_events'));
});
test('concurrent and arbitrarily late retries never redispatch an unknown paid request',async()=>{
 const s=setup();let release;const barrier=new Promise(r=>release=r);s.deps.decompose=async()=>{s.counts.decompose++;await barrier;throw Error('UPSTREAM_TIMEOUT');};
 const first=mod.createTask(s.deps).run(request());while(!s.counts.decompose)await new Promise(r=>setTimeout(r,1));
 assert.equal((await mod.createTask(s.deps).run(request())).state,'confirming');release();assert.equal((await first).state,'confirming');
 assert.equal((await mod.createTask({...s.deps,now:()=>Date.now()+86400000}).run(request())).state,'confirming');assert.equal(s.counts.decompose,1);
});
test('same request cannot change copy, policy, model cost or account ownership and cannot steal cached results',async()=>{
 const s=setup(),task=mod.createTask(s.deps);assert.equal((await task.run(request())).state,'done');
 for(const patch of[{items:[{key:'body',role:'body',text:'换成另一份文案'}]},{policyRevision:'changed'},{primaryCall:{...primary,supplierCostEstimateCny:.3}}])assert.equal((await task.run({...request(),...patch})).state,'conflict');
 await assert.rejects(task.run({...request(),owner:'bob'}),/FOREIGN_ASSET/);
 assert.notEqual(mod.keyOf('alice','poster1'),mod.keyOf('bob','poster1'));assert.equal(s.counts.decompose,1);
});
test('incomplete native recognition is a durable quality rejection, not silent unrefined delivery or another model call',async()=>{
 const s=setup();s.deps.render=async()=>{throw Object.assign(Error('bad'),{code:'NATIVE_TEXT_RECOGNITION_INCOMPLETE'});};
 const result=await mod.createTask(s.deps).run(request());assert.equal(result.state,'rejected');assert.equal(result.asset,undefined);assert.equal(result.costs.supplierCostEstimateCny,1.02);
 assert.equal((await mod.createTask(s.deps).run(request())).state,'rejected');assert.equal(s.counts.decompose,1);
});

test('deterministic glyph failure terminates without another paid call, while worker interruption remains locally recoverable',async()=>{
 for(const code of ['GLYPH_MISSING','GLYPH_HEIGHT_OVERFLOW','GLYPH_LAYOUT_INVALID','GLYPH_SHAPING_UNSUPPORTED']){
  const s=setup();s.deps.render=async()=>{s.counts.render++;throw Object.assign(Error(code),{code});};
  const task=mod.createTask(s.deps),r=await task.run(request());assert.equal(r.state,'rejected');assert.equal(r.diagnostic,'NATIVE_TEXT_GLYPH_LAYOUT_UNSAFE');assert.equal((await task.run(request())).state,'rejected');assert.equal(s.counts.decompose,1);assert.equal(s.counts.render,1);assert.equal(r.costs.supplierCostEstimateCny,1.02);
 }
 const s=setup();s.deps.render=async()=>{s.counts.render++;if(s.counts.render===1)throw Object.assign(Error('interrupted'),{code:'GLYPH_WORKER_LIMIT'});return{asset:asset(3)};};
 const task=mod.createTask(s.deps);assert.equal((await task.run(request())).state,'retry_local');assert.equal((await task.run(request())).state,'done');assert.equal(s.counts.decompose,1);
});
test('checkpoint local leases cannot be stolen before expiry and only local work resumes after it',async()=>{
 const s=setup();s.deps.render=async()=>{throw Error('LOCAL_RETRY');};await mod.createTask(s.deps).run(request());
 const key='bf_image_jobs:'+mod.keyOf('alice','poster1'),row=s.db.store.get(key);row.leaseUntil=Date.now()+60000;s.db.store.set(key,row);
 assert.equal((await mod.createTask(s.deps).run(request())).state,'busy');
 s.deps.render=async()=>({asset:asset(3)});assert.equal((await mod.createTask({...s.deps,now:()=>Date.now()+120000}).run(request())).state,'done');assert.equal(s.counts.decompose,1);
});
test('provider costs include every output stage once, and conflicting or unavailable amounts cannot become zero',()=>{
 assert.equal(mod.aggregateCosts([primary,secondary,secondary]).supplierCostEstimateCny,1.02);
 assert.throws(()=>mod.aggregateCosts([primary,{...primary,supplierCostEstimateCny:.4}]),/COST_CONFLICT/);
 for(const n of[null,undefined,NaN,-1,Infinity])assert.throws(()=>mod.aggregateCosts([{...primary,supplierCostEstimateCny:n}]),/COST_INVALID/);
 const s=setup();assert.throws(()=>mod.requestOf({...request(),draft:{...asset(1),mime:'text/html'}}),/ASSET_INVALID/);assert.equal(s.counts.decompose,0);
});
test('repeated local faults stop at a bounded review state while preserving assets and paid-call evidence',async()=>{
 const s=setup();s.deps.render=async()=>{s.counts.render++;throw Error('FONT_STORAGE_UNAVAILABLE');};
 const states=[];for(let i=0;i<5;i++)states.push((await mod.createTask(s.deps).run(request())).state);
 assert.deepEqual(states,['retry_local','retry_local','needs_review','needs_review','needs_review']);assert.equal(s.counts.decompose,1);assert.equal(s.counts.render,3);
 const row=[...s.db.store.values()][0];assert.equal(row.layers.length,2);assert.equal(row.costs.supplierCostEstimateCny,1.02);
});
const visionCall={modelCallId:'call_supplement',model:'existing-vision',supplierCostEstimateCny:.0021};
const plan=()=>({version:1,contact:asset(2),regions:[{id:'r0',layerIndex:1,box:[2,2,100,30]}]});
test('archived layers resume review and supplementary transcription independently, without repeating paid stages',async()=>{
 const s=setup();let reviews=0,supplements=0;
 s.deps.review=async()=>{if(++reviews===1)throw Error('LOCAL_REVIEW_OUTAGE');return{needsSupplement:true,plan:plan()};};
 s.deps.supplement=async()=>{if(++supplements===1)throw Object.assign(Error('budget'),{code:'COPY_NOT_DISPATCHED'});return{call:visionCall,transcription:{regions:[{id:'r0',text:'实际文字'}]}};};
 const first=await mod.createTask(s.deps).run(request());assert.equal(first.state,'retry_local');assert.equal(s.counts.decompose,1);
 assert.equal((await mod.createTask(s.deps).run(request())).state,'retry_local');
 const done=await mod.createTask(s.deps).run(request());assert.equal(done.state,'done');assert.equal(done.costs.supplierCostEstimateCny,1.0221);
 assert.equal(s.counts.decompose,1);assert.equal(reviews,2);assert.equal(supplements,2);assert.equal(s.counts.render,1);
 assert.equal((await mod.createTask(s.deps).run(request())).state,'done');
 const row=[...s.db.store.values()][0];assert.equal(row.transcript.regions[0].text,'实际文字');
});
test('unknown supplementary response never issues another vision request, even after lease expiry',async()=>{
 const s=setup();let n=0;s.deps.review=async()=>({needsSupplement:true,plan:plan()});s.deps.supplement=async()=>{n++;throw Error('UNKNOWN_UPSTREAM_OUTCOME');};
 assert.equal((await mod.createTask(s.deps).run(request())).state,'confirming');
 assert.equal((await mod.createTask({...s.deps,now:()=>Date.now()+86400000}).run(request())).state,'confirming');assert.equal(n,1);assert.equal(s.counts.decompose,1);
});
test('definite rejected decomposition releases a terminal quality outcome, keeps primary cost and never retries',async()=>{
 const s=setup();s.deps.decompose=async()=>{s.counts.decompose++;throw Object.assign(Error('rejected'),{code:'NATIVE_TEXT_PROVIDER_REJECTED'});};
 const result=await mod.createTask(s.deps).run(request());assert.equal(result.state,'rejected');assert.equal(result.costs.supplierCostEstimateCny,.28);
 assert.equal((await mod.createTask(s.deps).run(request())).state,'rejected');assert.equal(s.counts.decompose,1);assert.equal(s.counts.render,0);
 assert.equal([...s.db.store.values()][0].leaseUntil,0);
});
test('completed but unreadable supplementary response keeps all costs and rejects before rendering',async()=>{
 const s=setup();s.deps.review=async()=>({needsSupplement:true,plan:plan()});s.deps.supplement=async()=>({call:visionCall,transcription:{regions:[{id:'r0',text:null}]}});
 const r=await mod.createTask(s.deps).run(request());assert.equal(r.state,'rejected');assert.equal(r.costs.supplierCostEstimateCny,1.0221);assert.equal(s.counts.render,0);
});
