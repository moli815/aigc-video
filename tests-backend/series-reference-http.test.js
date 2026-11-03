"use strict";
const test=require("node:test"),assert=require("node:assert/strict"),fs=require("node:fs"),path=require("node:path"),vm=require("node:vm"),{createRequire}=require("node:module");
const {memoryDatabase}=require("./foundation-fixture"),{assetKey}=require("../cloudfunctions/shared/asset-store"),{syncRecordKey}=require("../cloudfunctions/shared/sync-identifiers");
const U=["B665E22F-B174-4C75-931A-962EC43FE3E1","B665E22F-B174-4C75-931A-962EC43FE3E2"];
const contract=()=>({version:1,mode:"replace",items:U.map((id,i)=>({kind:"library",id,role:i?"人物":"底图"}))});
async function harness(){
 const raw=memoryDatabase();
 const db={...raw,collection(name){const col=raw.collection(name);return {...col,doc(id){const doc=col.doc(id);return {...doc,async update(patch){const row=(await doc.get()).data[0];if(!row)throw Error("NOT_FOUND");for(const [key,value]of Object.entries(patch)){const parts=key.split('.');let at=row;for(const part of parts.slice(0,-1))at=at[part]??={};at[parts.at(-1)]=structuredClone(value);}return doc.set(row);}};}};}};
 const file=path.resolve(__dirname,"../cloudfunctions/bf-image/index.js"),realRequire=createRequire(file),calls=[],charges=[],reservations=[];let handler,epoch=0,failNext=false;
 const app={database:()=>db,async getTempFileURL({fileList}){return {fileList:fileList.map(f=>({fileID:f.fileID,tempFileURL:"https://fixture.myqcloud.com/"+f.fileID+"?epoch="+(++epoch)}))};}};
 const context={require:n=>n==="http"?{createServer(fn){handler=fn;return {listen(){}};}}:n==="@cloudbase/node-sdk"?{init:()=>app}:realRequire(n),module:{exports:{}},exports:{},process:{env:{}},Buffer,URL,AbortController,setTimeout,clearTimeout,console:{log(){}},__fixture:{db,charges,reservations},fetch:async(url,options)=>{
  calls.push(JSON.parse(options.body));if(failNext){failNext=false;return new Response(JSON.stringify({error:{code:"InvalidParameter"}}),{status:400});}
  return new Response(JSON.stringify({data:[{url:"https://fixture.myqcloud.com/result-"+calls.length+".png"}]}),{status:200});
 }};
 vm.createContext(context);vm.runInContext(fs.readFileSync(file,"utf8")+`
 refreshRuntime=async()=>{};requireMember=async(req)=>({sub:req.owner||"A"});quotaExhausted=async()=>({remainingCny:1000,capCny:1000,usedCny:0});readBody=async(req)=>req.body;
 ensureCollection=async()=>{};flushJobs=async()=>{};reserveQuota=async(id,owner,cost)=>{__fixture.reservations.push({id,owner,cost});return true;};releaseQuota=async()=>{};
 finishIdem=async(rid,owner,url,cost,model,extra)=>{await __fixture.db.collection(JOB_COLL).doc(idemKey(rid,owner)).update({state:"done",url,costCny:cost,model,costCommitted:true,...extra});__fixture.charges.push({rid,owner,cost});return true;};
 abortIdem=async(rid,owner)=>__fixture.db.collection(JOB_COLL).doc(idemKey(rid,owner)).update({state:"failed"});
 RT.IMAGE_API_KEY="fixture-only";RT.IMAGE_MODEL_FAST="doubao-seedream-5-0-flash-260915";RT.IMAGE_MODEL_PRO="doubao-seedream-5-0-pro-260628";
 globalThis.subject={seriesTaskIdOf};`,context);
 const assets=[];
 for(let i=0;i<2;i++){
  const sha=String(i+1).repeat(64),id=assetKey("A",sha),asset={id,sha256:sha,mime:"image/png",byteCount:24};assets.push(asset);
  await db.collection("bf_assets").doc(id).set({accountId:"A",state:"ready",privateACL:true,fileID:"image-"+i,...asset});
  await db.collection("bf_sync_v2").doc(syncRecordKey("A","file",U[i])).set({accountId:"A",kind:"file",refId:U[i],deleted:false,payload:JSON.stringify({id:U[i],categoryRaw:"image",asset})});
 }
 async function request(route,body,owner="A"){
  let status,out;const res={setHeader(){},writeHead(code){status=code;},end(text){out=JSON.parse(text);}};
  await handler({url:route,method:"POST",headers:{},body,owner},res);return {status,body:out};
 }
 return {db,calls,charges,reservations,assets,request,failNext(){failNext=true;},taskId:rid=>context.subject.seriesTaskIdOf("A",rid)};
}
const start=(rid,extra={})=>({requestId:rid,prompt:"把人物素材合成到提供的底图，做两张不同构图。",requested_count:2,size:"1536x1536",structured:{image_references:contract()},...extra});
test("real HTTP start/step/retry sends both owned inputs in order and re-signs retry without duplicate charge",async()=>{
 const h=await harness(),s=await h.request("/series/start",start("refs-flow"));assert.equal(s.status,200);assert.equal(h.calls.length,0);assert.equal(h.reservations.length,1);assert.equal(h.reservations[0].cost,1.28);
 const stored=(await h.db.collection("bf_image_series").doc(s.body.taskId).get()).data[0];assert.equal(stored.referenceManifest.references.length,2);assert.doesNotMatch(JSON.stringify(stored.referenceManifest),/https:|base64/);
 h.failNext();const failed=await h.request("/series/step",{taskId:s.body.taskId,index:1});assert.equal(failed.status,200);assert.equal(failed.body.failed,1);assert.equal(h.charges.length,0);
 await h.request("/series/step",{taskId:s.body.taskId,index:2});assert.equal(h.charges.length,1);
 const retry=await h.request("/series/retry",{requestId:"refs-flow",indices:[1,2]});assert.equal(retry.status,200);assert.equal(retry.body.succeeded,2);assert.deepEqual(retry.body.retriedIndices,[1]);assert.equal(h.charges.length,2);
 for(const call of h.calls){assert.equal(call.image.length,2);assert.match(call.image[0],/image-0/);assert.match(call.image[1],/image-1/);assert.match(call.prompt,/底图/);assert.match(call.prompt,/人物/);}
 assert.notEqual(h.calls[0].image[0],h.calls[2].image[0]);
 await h.request("/series/retry",{requestId:"refs-flow",indices:[1,2]});await h.request("/series/step",{taskId:s.body.taskId,index:1});assert.equal(h.calls.length,3);assert.equal(h.charges.length,2);
});
test("missing/foreign memory is rejected before reservation or provider calls",async()=>{
 for(const owner of ["A","B"]){const h=await harness();if(owner==="A")await h.db.collection("bf_sync_v2").doc(syncRecordKey("A","file",U[1])).update({deleted:true});const r=await h.request("/series/start",start("missing"),owner);assert.equal(r.status,422);assert.match(r.body.msg,/原图/);assert.equal(h.calls.length,0);assert.equal(h.reservations.length,0);assert.equal(h.charges.length,0);}
});
test("same request selection replay is stable; changed roles or IDs conflict without new charges",async()=>{
 const h=await harness(),s=await h.request("/series/start",start("same")),again=await h.request("/series/start",start("same"));assert.equal(again.body.taskId,s.body.taskId);assert.equal(h.reservations.length,1);
 const changed=start("same");changed.structured.image_references.items.reverse();const conflict=await h.request("/series/start",changed);assert.equal(conflict.status,409);assert.equal(h.reservations.length,1);assert.equal(h.calls.length,0);
});
test("deletion after start fails closed without supplier call; restoring original permits targeted retry",async()=>{
 const h=await harness(),s=await h.request("/series/start",start("delete-later"));const file=h.db.collection("bf_sync_v2").doc(syncRecordKey("A","file",U[1]));await file.update({deleted:true});
 const failed=await h.request("/series/step",{taskId:s.body.taskId,index:1});assert.equal(failed.body.items[0].errorCategory,"reference_unavailable");assert.equal(h.calls.length,0);assert.equal(h.charges.length,0);
 await file.update({deleted:false});const retry=await h.request("/series/retry",{requestId:"delete-later",indices:[1]});assert.equal(retry.body.succeeded,1);assert.equal(h.calls.length,1);
});
test("foreign task step and cancelled retry cannot generate",async()=>{
 const h=await harness(),s=await h.request("/series/start",start("guard"));assert.equal((await h.request("/series/step",{taskId:s.body.taskId,index:1},"B")).status,403);
 await h.request("/series/cancel",{taskId:s.body.taskId});assert.equal((await h.request("/series/retry",{requestId:"guard",indices:[1]})).status,409);assert.equal(h.calls.length,0);
});
test("old text-only series still works and unresolved raw start images are never silently discarded",async()=>{
 const h=await harness(),s=await h.request("/series/start",start("legacy",{structured:undefined}));assert.equal(s.status,200);await h.request("/series/step",{taskId:s.body.taskId,index:1});assert.equal(h.calls[0].image,undefined);
 const before=h.calls.length,r=await h.request("/series/start",start("raw",{structured:undefined,image:"data:image/png;base64,AA=="}));assert.equal(r.status,422);assert.equal(h.calls.length,before);
});
