"use strict";
const assert=require("node:assert/strict"),fs=require("node:fs"),path=require("node:path"),vm=require("node:vm"),{createRequire}=require("node:module");
const {memoryDatabase}=require("./foundation-fixture"),{assetKey}=require("../cloudfunctions/shared/asset-store"),{syncRecordKey}=require("../cloudfunctions/shared/sync-identifiers");
const U=["B665E22F-B174-4C75-931A-962EC43FE3E1","B665E22F-B174-4C75-931A-962EC43FE3E2"];
const contract=()=>({version:1,mode:"replace",items:U.map((id,i)=>({kind:"library",id,role:i?"人物":"底图"}))});
async function harness(){
 const raw=memoryDatabase();
 const db={...raw,collection(name){const col=raw.collection(name);return {...col,doc(id){const doc=col.doc(id);return {...doc,async update(patch){const row=(await doc.get()).data[0];if(!row)throw Error("NOT_FOUND");for(const [key,value]of Object.entries(patch)){const parts=key.split('.');let at=row;for(const part of parts.slice(0,-1))at=at[part]??={};at[parts.at(-1)]=structuredClone(value);}return doc.set(row);}};}};}};
 const file=path.resolve(__dirname,"../cloudfunctions/bf-image/index.js"),realRequire=createRequire(file),calls=[],charges=[],reservations=[];let handler,epoch=0,failNext=false;
 const app={database:()=>db,async getTempFileURL({fileList}){return {fileList:fileList.map(f=>({fileID:f.fileID,tempFileURL:"https://fixture.myqcloud.com/"+f.fileID+"?epoch="+(++epoch)}))};}};
 const shared={db,charges,reservations,remaining:1000};
 const context={require:n=>n==="http"?{createServer(fn){handler=fn;return {listen(){}};}}:n==="@cloudbase/node-sdk"?{init:()=>app}:realRequire(n),module:{exports:{}},exports:{},process:{env:{}},Buffer,URL,AbortController,setTimeout,clearTimeout,console:{log(){}},__fixture:shared,fetch:async(url,options)=>{
  calls.push(JSON.parse(options.body));if(failNext){failNext=false;return new Response(JSON.stringify({error:{code:"InvalidParameter"}}),{status:400});}
  return new Response(JSON.stringify({data:[{url:"https://fixture.myqcloud.com/result-"+calls.length+".png"}]}),{status:200});
 }};
 vm.createContext(context);vm.runInContext(fs.readFileSync(file,"utf8")+`
 refreshRuntime=async()=>{};requireMember=async(req)=>({sub:req.owner||"A"});quotaExhausted=async()=>({remainingCny:__fixture.remaining,capCny:1000,usedCny:1000-__fixture.remaining});readBody=async(req)=>req.body;
 ensureCollection=async()=>{};flushJobs=async()=>{};reserveQuota=async(id,owner,cost)=>{__fixture.reservations.push({id,owner,cost});return true;};releaseQuota=async()=>{};
 finishIdem=async(rid,owner,url,cost,model,extra)=>{await __fixture.db.collection(JOB_COLL).doc(idemKey(rid,owner)).update({state:"done",url,costCny:cost,model,costCommitted:true,...extra});__fixture.charges.push({rid,owner,cost});return true;};
 abortIdem=async(rid,owner)=>__fixture.db.collection(JOB_COLL).doc(idemKey(rid,owner)).update({state:"failed"});
 RT.IMAGE_MIXED_REFERENCES_POLICY=JSON.stringify({enabled:true,audience:"all"});RT.IMAGE_API_KEY="fixture-only";RT.IMAGE_MODEL_FAST="doubao-seedream-5-0-flash-260915";RT.IMAGE_MODEL_PRO="doubao-seedream-5-0-pro-260628";
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
 return {db,calls,charges,reservations,assets,request,context,setRemaining(n){shared.remaining=n;},failNext(){failNext=true;},taskId:rid=>context.subject.seriesTaskIdOf("A",rid)};
}

module.exports={harness,U};
