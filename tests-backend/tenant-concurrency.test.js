"use strict";
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),crypto=require('node:crypto'),http=require('node:http');
const {AsyncLocalStorage}=require('node:async_hooks'),{once}=require('node:events');
const {memoryDatabase}=require('./foundation-fixture'),{createSyncService}=require('../cloudfunctions/bf-api/domains/sync-v2');
const {createFoundationHandler}=require('../cloudfunctions/bf-api/domains/foundation'),{injectAccountContext}=require('../cloudfunctions/bf-api/account-context');
const {restoreSyncedImageContext}=require('../cloudfunctions/bf-api/confirmed-image-context');
const src=fs.readFileSync(process.env.ISOLATION_API_SOURCE||require.resolve('../cloudfunctions/bf-api/index.js'),'utf8');
const id=n=>'10000000-0000-4000-8000-'+String(n).padStart(12,'0');
const record=(kind,n,payload,baseVersion=0)=>({kind,refId:id(n),baseVersion,payload:{id:id(n),...payload}});
const pause=ms=>new Promise(r=>setTimeout(r,ms));
test('cache owner is mandatory and equal questions never reuse another tenant or legacy entry',()=>{
 const a=src.indexOf('function semanticCacheKey('),b=src.indexOf('\n}',a)+2,key=vm.runInNewContext(src.slice(a,b)+'\nsemanticCacheKey',{crypto});
 const m=[{role:'user',content:'企业运营效率怎样提升'}];
 assert.equal(key(m,'standard'),null);assert.equal(key(m,'standard',' '),null);
 assert.notEqual(key(m,'standard','A'),key(m,'standard','B'));
 assert.equal(key(m,'standard','A'),key(m,'standard','A'));
 assert.match(key(m,'standard','A'),/^ca2_[a-f0-9]{64}$/);
 assert.notEqual(key(m,'high','A'),key(m,'standard','A'));
});
test('actual HTTP request wrapper isolates 200 interleaved account/ledger contexts and leaves sibling listeners untouched',async()=>{
 const reqStore=new AsyncLocalStorage(),logs=[],outside=[];
 const a=src.indexOf('const server = http.createServer('),b=src.indexOf('\nserver.listen(9000);',a);
 const context={http,crypto,reqStore,URL,process,RUNTIME:{},refreshRuntime:async()=>pause(1),maskText:x=>x,logSafe:x=>logs.push(x),
  sendError:(res,status,code)=>{res.writeHead(status);res.end(code);},
  handleChat:async(req,res)=>{const owner=req.headers.authorization==='Bearer A'?'A':'B',st=reqStore.getStore();st.accountId=owner;
   await pause(Number(req.headers['x-delay'])%7);assert.equal(reqStore.getStore().accountId,owner);
   await Promise.resolve();assert.equal(reqStore.getStore().requestId,req.headers['x-request-id']);
   res.end(JSON.stringify({owner,rid:reqStore.getStore().requestId}));}};
 const server=vm.runInNewContext(src.slice(a,b)+'\nserver',context);
 server.on('request',()=>outside.push(reqStore.getStore()));server.listen(0,'127.0.0.1');await once(server,'listening');
 try{const port=server.address().port;await Promise.all(Array.from({length:200},async(_,i)=>{const owner=i%2?'A':'B',rid='isolation-'+i;
  const r=await fetch('http://127.0.0.1:'+port+'/api/chat',{method:'POST',headers:{authorization:'Bearer '+owner,'x-request-id':rid,'x-delay':String(i)},signal:AbortSignal.timeout(15000)});
  assert.equal(r.status,200);assert.deepEqual(await r.json(),{owner,rid});}));
  assert.equal(outside.length,200);assert.ok(outside.every(x=>x===undefined));assert.equal(reqStore.getStore(),undefined);
  assert.equal(logs.length,200);
 }finally{server.closeAllConnections();await new Promise(r=>server.close(r));}
});
test('two tenants concurrently upload identical UUIDs, replay, conflict and delete independently',async()=>{
 const db=memoryDatabase(),sync=createSyncService({db});
 await Promise.all(['A','B'].map(owner=>sync.push(owner,[record('conversation',1,{title:owner})])));
 await Promise.all(Array.from({length:200},(_,i)=>{const owner=i%2?'A':'B';return sync.push(owner,[record('message',Math.floor(i/2)+2,{conversationId:id(1),role:'user',text:owner+'-private-'+i,createdAt:i})]);}));
 for(const owner of ['A','B']){const first=await sync.pull(owner,0,null,0,100),last=await sync.pull(owner,0,first.watermark,first.after,100),all=[...first.items,...last.items];
  assert.equal(all.length,101);assert.equal(new Set(all.map(r=>r.revision)).size,101);assert.ok(all.every(r=>!r.payload.includes((owner==='A'?'B':'A')+'-private')));}
 const changes=await Promise.all([sync.push('A',[record('conversation',1,{title:'newA'},1)]),sync.push('A',[record('conversation',1,{title:'staleA'},1)])]);
 assert.equal(changes.reduce((n,x)=>n+x.conflicts.length,0),1);
 await sync.deleteConversation('A',id(1));assert.equal((await sync.pull('B',0,null,0,2)).items[0].deleted,false);
 await assert.rejects(sync.push('C',[record('message',2,{conversationId:id(1),text:'foreign parent'})]),/INVALID_PARENT/);
});
test('foundation uses authenticated subject despite forged body/query owners under concurrency',async()=>{
 const db=memoryDatabase(),sync=createSyncService({db}),handle=createFoundationHandler({requireMember:async req=>({sub:req.owner}),readJsonBody:async req=>req.body,syncV2:sync,
  sendJson:(res,status,body)=>Object.assign(res,{status,body}),sendError:()=>assert.fail('unexpected error'),logSafe:()=>{},currentRequestId:()=>''});
 await Promise.all(['A','B'].map(async owner=>{const res={};await handle({method:'POST',owner,body:{accountId:owner==='A'?'B':'A',records:[record('memory',4,{content:owner+' private'})]}},res,new URL('http://fixture/api/sync/v2/push'));assert.equal(res.status,200);}));
 await Promise.all(['A','B'].map(async owner=>{const res={};await handle({method:'GET',owner},res,new URL('http://fixture/api/sync/v2/pull?accountId=other'));assert.equal(res.body.items.length,1);assert.equal(JSON.parse(res.body.items[0].payload).content,owner+' private');}));
});
test('parallel long-term recall verifies row ownership even when storage returns foreign records',async()=>{
 const rows=['A','B'].map(owner=>({accountId:owner,kind:'memory',refId:id(1),payload:{id:id(1),content:owner+'-ONLY 企业长期资料'}}));
 const db={collection:()=>({where(filter){return{orderBy(){return this;},limit(){return this;},get:async()=>{await pause(filter.accountId==='A'?4:1);return{data:rows};}};}})};
 await Promise.all(Array.from({length:100},async(_,i)=>{const owner=i%2?'A':'B',r=await injectAccountContext([{role:'user',content:'企业公司简介'}],{db,owner,enabled:true});
  assert.match(JSON.stringify(r),new RegExp(owner+'-ONLY'));assert.doesNotMatch(JSON.stringify(r),new RegExp((owner==='A'?'B':'A')+'-ONLY'));}));
});
test('ambiguous equal anchors in two same-account conversations never restore either history',async()=>{
 const anchors=['请按照前面已经明确过的所有实际业务资料整理宣传海报','根据前面已经确认的全部内容和最新更正生成完整宣传海报'];
 const rows=[1,2].flatMap(n=>anchors.map((text,i)=>({accountId:'A',kind:'message',parentId:id(n),refId:id(10+n+i),payload:{role:'user',text,conversationId:id(n),createdAt:i+1}})));
 let parentReads=0;const db={collection:()=>({where(){return{orderBy(){return this;},limit(){return this;},get:async()=>({data:rows})};},doc(){parentReads++;throw Error('AMBIGUOUS_PARENT_LOOKUP');}})};
 const messages=[...Array.from({length:28},()=>({role:'assistant',content:'note'})),...anchors.map(content=>({role:'user',content}))];
 await restoreSyncedImageContext(messages,{owner:'A',db,enabled:true});assert.equal(parentReads,0);
});
test('100 interleaved supplier ledger calls keep owners separate even with an identical client request ID',async()=>{
 const {createModelCallLedger,orderIdOf}=require('../cloudfunctions/shared/model-call-ledger'),db=memoryDatabase(),scope=new AsyncLocalStorage();
 const ledger=createModelCallLedger({db,context:()=>scope.getStore(),source:'unpaid-local-fixture',log:()=>{},pricing:()=>null});
 await Promise.all(Array.from({length:100},(_,i)=>{const owner=i%2?'A':'B';return scope.run({accountId:owner,requestId:'same-rid',endpoint:'/api/chat'},async()=>{
  const r=await ledger.fetch('https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions',{method:'POST',body:JSON.stringify({model:'fixture'})},async()=>{await pause(i%5);return Response.json({id:owner+'-'+i,usage:{prompt_tokens:1,completion_tokens:1},choices:[]});});await r.json();
 });}));
 const rows=(await db.collection('bf_model_calls').get()).data;assert.equal(rows.length,100);assert.equal(new Set(rows.map(r=>r._id)).size,100);
 for(const r of rows){assert.ok(r.providerResponseId.startsWith(r.accountId+'-'));assert.equal(r.orderId,orderIdOf(r.accountId,'same-rid'));}
 assert.notEqual(orderIdOf('A','same-rid'),orderIdOf('B','same-rid'));
});
function periodHarness(db,now){const a=src.indexOf('async function ensurePeriod(account) {'),b=src.indexOf('\n/** 用量分档',a);return vm.runInNewContext(src.slice(a,b)+'\nensurePeriod',{db,C:{accounts:'bf_accounts'},nowMs:()=>now,MEMBER_MONTHS:1,periodKey:()=> 'fixture-cycle',Date});}
test('late stale period snapshots never erase charges committed after the first rollover',async()=>{
 const db=memoryDatabase(),now=Date.now(),stale={_id:'A',createdAt:new Date(now-40*86400000),cycleAnchorAt:new Date(now-40*86400000),chatUsedCny:100,imageUsedCny:20};
 await db.collection('bf_accounts').doc('A').set(stale);const ensure=periodHarness(db,now);await ensure(stale);
 await db.collection('bf_accounts').doc('A').update({chatUsedCny:.25,imageUsedCny:.5});
 const later=await ensure(stale);assert.equal(later.chatUsedCny,.25);assert.equal(later.imageUsedCny,.5);
 assert.equal((await db.collection('bf_accounts').doc('A').get()).data[0].chatUsedCny,.25);
});
test('concurrent rollover is account-local and within-cycle requests add no database round trip',async()=>{
 const db=memoryDatabase(),now=Date.now(),stale={_id:'A',cycleAnchorAt:new Date(now-40*86400000),chatUsedCny:100};
 await db.collection('bf_accounts').doc('A').set(stale);await db.collection('bf_accounts').doc('B').set({_id:'B',chatUsedCny:87});
 const ensure=periodHarness(db,now);await Promise.all(Array.from({length:20},()=>ensure(stale)));
 assert.equal((await db.collection('bf_accounts').doc('A').get()).data[0].chatUsedCny,0);assert.equal((await db.collection('bf_accounts').doc('B').get()).data[0].chatUsedCny,87);
 const current={_id:'A',cycleAnchorAt:new Date(now),chatUsedCny:3};assert.equal(await periodHarness({runTransaction:()=>assert.fail('extra query')},now)(current),current);
 await assert.rejects(ensure({...stale,_id:'missing'}),/MEMBER_ACCOUNT_MISSING/);
});
