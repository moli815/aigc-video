"use strict";
const test=require("node:test"),assert=require("node:assert/strict");
const {createImageReferenceStore,contractOf}=require("../cloudfunctions/shared/image-reference-store");
const {createSyncService,key}=require("../cloudfunctions/bf-api/domains/sync-v2");
const {memoryDatabase}=require("./foundation-fixture");
const uuid="B665E22F-B174-4C75-931A-962EC43FE3E1",other="B665E22F-B174-4C75-931A-962EC43FE3E2";
const descriptor=(letter="a")=>({id:letter.repeat(40),sha256:letter.repeat(64),mime:"image/png",byteCount:24});
const contract=(items=[{kind:"library",id:uuid,role:"底图"}])=>({version:1,mode:"append",items});
function fixture(){
 let signed=0,verified=[],epoch=0;
 const rows=new Map([[uuid,{accountId:"A",kind:"file",refId:uuid,deleted:false,payload:JSON.stringify({id:uuid,categoryRaw:"image",asset:descriptor()})}]]);
 const store=createImageReferenceStore({readFile:async(owner,id)=>rows.get(id),assetStore:{
  async verifyReferences(owner,refs){verified.push({owner,refs});if(owner!=="A")throw Error("ASSET_NOT_FOUND");},
  async sign(owner,ids){signed++;return ids.map(id=>({id,url:"https://private.example/"+id+"?epoch="+(++epoch)}));}
 }});
 return {store,rows,verified,get signed(){return signed;}};
}
test("library UUID maps through actual synced owned file payload, never UUID-as-asset-ID",async()=>{
 const db=memoryDatabase(),asset=descriptor();const sync=createSyncService({db,assetStore:{async verifyReferences(){}}});
 await sync.push("A",[{kind:"file",refId:uuid.toLowerCase(),payload:{id:uuid,categoryRaw:"image",asset}}]);
 let lookedUp;
 const store=createImageReferenceStore({readFile:async(owner,id)=>{lookedUp=key(owner,"file",id);return (await db.collection("bf_sync_v2").doc(lookedUp).get()).data[0];},assetStore:{async verifyReferences(owner,refs){assert.equal(owner,"A");assert.deepEqual(refs,[asset]);},async sign(){throw Error("not yet");}}});
 const manifest=await store.prepare("A",contract());assert.equal(lookedUp,key("A","file",uuid));assert.equal(manifest.references[0].asset.id,asset.id);
});
test("foreign lookup row is denied before issuing URLs, even if lookup adapter is buggy",async()=>{
 const f=fixture();await assert.rejects(f.store.prepare("B",contract()),/NOT_FOUND/);assert.equal(f.signed,0);assert.equal(f.verified.length,0);
});
test("deleted or corrupt file records do not silently become text-only image generation",async()=>{
 for(const edit of [r=>r.deleted=true,r=>r.payload="{broken",r=>r.kind="memory",r=>r.refId=other,r=>r.payload=JSON.stringify({id:uuid,categoryRaw:"document",asset:descriptor()})]){
  const f=fixture();edit(f.rows.get(uuid));await assert.rejects(f.store.prepare("A",contract()),/NOT_FOUND/);assert.equal(f.signed,0);
 }
});
test("non-image, missing and malformed descriptors are rejected without signing",async()=>{
 for(const asset of [null,{...descriptor(),mime:"application/pdf"},{...descriptor(),byteCount:NaN},{...descriptor(),sha256:"wrong"}]){
  const f=fixture();f.rows.get(uuid).payload={id:uuid,categoryRaw:"image",asset};await assert.rejects(f.store.prepare("A",contract()));assert.equal(f.signed,0);
 }
});
test("duplicate UUID casing and duplicate resolved assets are rejected",async()=>{
 assert.throws(()=>contractOf(contract([{kind:"library",id:uuid,role:"底图"},{kind:"library",id:uuid.toLowerCase(),role:"人物"}])),/DUPLICATE/);
 const f=fixture();await assert.rejects(f.store.prepare("A",contract([{kind:"library",id:uuid,role:"底图"},{kind:"asset",...descriptor(),role:"人物"}])),/DUPLICATE/);
});
test("ready asset verification failure prevents all URL creation",async()=>{
 const store=createImageReferenceStore({readFile:async()=>null,assetStore:{async verifyReferences(){throw Error("ASSET_NOT_READY");},async sign(){throw Error("must not sign");}}});
 await assert.rejects(store.prepare("A",contract([{kind:"asset",...descriptor(),role:"Logo"}])),/NOT_READY/);
});
test("manifest order and roles survive idempotent preparation and fresh retry signing",async()=>{
 const f=fixture(),input=contract([{kind:"library",id:uuid,role:"底图"},{kind:"asset",...descriptor("b"),role:"人物"}]);
 const first=await f.store.prepare("A",input),again=await f.store.prepare("A",input);assert.deepEqual(first,again);
 assert.doesNotMatch(JSON.stringify(first),/https:|base64|data:image/);
 const one=await f.store.sign("A",first),two=await f.store.sign("A",first);
 assert.deepEqual(one.map(i=>i.role),["底图","人物"]);assert.deepEqual(one.map(i=>i.id),[descriptor().id,descriptor("b").id]);assert.notEqual(one[0].url,two[0].url);assert.equal(f.signed,2);
});
test("deleted or substituted library image invalidates persisted retry manifest",async()=>{
 for(const mutate of [r=>r.deleted=true,r=>r.payload={id:uuid,categoryRaw:"image",asset:descriptor("b")}]){
  const f=fixture(),manifest=await f.store.prepare("A",contract());mutate(f.rows.get(uuid));await assert.rejects(f.store.sign("A",manifest),/NOT_FOUND|CHANGED/);assert.equal(f.signed,0);
 }
});
test("client URLs, bare IDs and ambiguous input modes are not authorization",()=>{
 for(const raw of [undefined,{version:1,items:[{kind:"library",id:uuid,role:"Logo"}]},contract([{kind:"url",id:"https://elsewhere.test/logo.png",role:"Logo"}]),contract([{kind:"library",id:descriptor().id,role:"Logo"}]),contract([])])assert.throws(()=>contractOf(raw));
});
