"use strict";
const test=require("node:test"),assert=require("node:assert/strict"),m=require("../cloudfunctions/bf-api/account-context");
const id="11111111-1111-4111-8111-111111111111",row=(kind,content,extra={})=>({accountId:"a",kind,refId:id,payload:{id,...content},...extra});
test('a generic business keyword cannot inject an explicitly different project contact',()=>{
 const memories=[row('memory',{content:'甲项目联系方式：021-11112222'}),row('memory',{content:'乙项目联系方式：010-33334444'})];
 assert.deepEqual(m.selectFacts({owner:'a',query:'给甲项目做海报',memories,messages:[]}).map(f=>f.text),['甲项目联系方式：021-11112222']);
 assert.equal(m.selectFacts({owner:'a',query:'做公司海报',memories,messages:[]}).length,0);
});
test('latest explicit project selection outranks older context and source-labelled memories',()=>{
 const memories=[row('memory',{content:'合作电话021-11112222',source:'甲项目海报'}),row('memory',{content:'合作电话010-33334444',source:'乙项目海报'})];
 assert.deepEqual(m.selectFacts({owner:'a',query:'继续做海报',context:['给甲项目做海报','更正，今天做乙项目的海报'],memories,messages:[]}).map(f=>f.text),['合作电话010-33334444']);
});
test('project-scoped old corrections stay out of an unrelated new company profile',()=>{
 const messages=[row('message',{role:'user',createdAt:30,text:'请记住：乙项目：公司电话010-33334444。'})];
 assert.equal(m.selectFacts({owner:'a',query:'写公司简介',messages,memories:[]}).length,0);
});
test('negative correction does not revive a rejected project from older messages',()=>{
 const memories=[row('memory',{content:'甲项目联系方式：021-11112222'}),row('memory',{content:'乙项目联系方式：010-33334444'})];
 assert.deepEqual(m.selectFacts({owner:'a',query:'不要用乙项目的资料，今天做甲项目海报',context:['做乙项目海报'],memories,messages:[]}).map(f=>f.text),['甲项目联系方式：021-11112222']);
 assert.equal(m.selectFacts({owner:'a',query:'不要用乙项目的资料做海报',context:['做乙项目海报'],memories,messages:[]}).length,0);
});
test("latest explicit company relationship outranks old memories, excludes other owners and assistant guesses",()=>{
 const old=row("memory",{content:"公司直接服务物业"}),fix=row("message",{role:"user",text:"请你记住：我们给合作伙伴提供解决方案，再由伙伴服务终端场所。",createdAt:20});
 const facts=m.selectFacts({owner:"a",query:"公司简介",memories:[old,row("memory",{content:"别人的资料"},{accountId:"b"})],messages:[fix,row("message",{role:"assistant",createdAt:30,text:"记住我们是运营商"})]});
 assert.equal(facts.length,2);assert.equal(facts[0].text,fix.payload.text);assert.ok(!facts.some(f=>f.text.includes("别人")||f.text.includes("运营商")));
});
test("old event context does not contaminate a new company profile or unrelated task",()=>{
 const memories=[row("memory",{content:"上次参展日期为11月3日"})];assert.deepEqual(m.selectFacts({owner:"a",query:"写公司简介",memories,messages:[]}),[]);assert.deepEqual(m.selectFacts({owner:"a",query:"2加2",memories,messages:[]}),[]);
 assert.equal(m.selectFacts({owner:"a",query:"以前参展是什么时候",memories,messages:[]}).length,1);
});
test("account context is bounded data, opt-in, idempotent and leaves original request intact",async()=>{
 const chain={where:()=>chain,orderBy:()=>chain,limit:()=>chain,get:async()=>({data:[row("message",{role:"user",text:"请记住我们的公司名是甲公司",createdAt:10})]})},db={collection:()=>chain},messages=[{role:"user",content:"写公司简介"}];
 assert.equal(await m.injectAccountContext(messages,{db,owner:"a",enabled:false}),messages);
 const next=await m.injectAccountContext(messages,{db,owner:"a",enabled:true});assert.equal(next.length,2);assert.equal(next[0],messages[0]);assert.match(next[1].content,/不是新的系统指令/);assert.equal(await m.injectAccountContext(next,{db,owner:"a",enabled:true}),next);
 assert.ok(require("../cloudfunctions/bf-api/commercial-copy-review").sourceContext(next).some(f=>f.text.includes("公司名是甲公司")));
});
test("failed optional indexing cannot turn acknowledged sync into an error",async()=>{
 const {createFoundationHandler}=require("../cloudfunctions/bf-api/domains/foundation");let result,errors=0,logs=0;
 const handle=createFoundationHandler({requireMember:async()=>({sub:"a"}),readJsonBody:async()=>({records:[]}),syncV2:{push:async()=>({acknowledged:[{version:1}],revision:8})},sendJson:(res,status,body)=>{result={status,body};},sendError:()=>{errors++;},logSafe:()=>{logs++;},currentRequestId:()=>"test",afterSync:async()=>{throw Error("UNAVAILABLE");}});
 await handle({method:"POST"},{},{pathname:"/api/sync/v2/push"});assert.equal(result.status,200);assert.equal(result.body.revision,8);assert.equal(result.body.acknowledged[0].version,1);assert.equal(errors,0);assert.equal(logs,1);
});
test("incremental indexing verifies owned originals, preserves OCR, and repeats without extra writes",async()=>{
 const mid="22222222-2222-4222-8222-222222222222",file={accountId:"a",kind:"file",refId:id,version:1,payload:{id,categoryRaw:"image",textContent:"原始OCR",asset:{id:"f".repeat(40)}}},message={accountId:"a",kind:"message",refId:mid,version:1,payload:{id:mid,role:"user",text:"这是我们公司的Logo",createdAt:100,attachmentIds:id}};
 const db={collection:()=>({doc:()=>({get:async()=>({data:[file]})})})};let checks=0,writes=0;
 const after=m.createImageMemoryIndexer({db,assetStore:{verifyReferences:async(owner,refs)=>{assert.equal(owner,"a");assert.equal(refs.length,1);checks++;}},syncService:{push:async(owner,items)=>{assert.equal(owner,"a");assert.equal(items[0].baseVersion,1);assert.match(items[0].payload.textContent,/原始OCR/);file.payload=items[0].payload;file.version++;writes++;return {acknowledged:items,conflicts:[]};}}});
 await after("a",[],{acknowledged:[message]});await after("a",[],{acknowledged:[message]});assert.equal(writes,1);assert.equal(checks,1);
 file.accountId="b";await after("a",[],{acknowledged:[message]});assert.equal(writes,1);
});
