"use strict";
// Account-scoped bridge between recalled file UUIDs and private asset IDs.
// Callers provide the existing sync-store lookup adapter; no cross-function
// import, shared "latest image", permanent URL, or image bytes are persisted.
const UUID=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
const ID=/^[a-f0-9]{40}$/;
const IMAGE_TYPES=new Set(["image/png","image/jpeg","image/webp","image/gif"]);
const MAX_BYTES=24*1024*1024;
const {syncRecordKey}=require("./sync-identifiers");
const {documentOf}=require("./document-store");
function invalid(code="IMAGE_REFERENCES_INVALID") { throw new Error(code); }
function assetDescriptor(raw) {
  if(!raw||!ID.test(raw.id||"")||!/^[a-f0-9]{64}$/.test(raw.sha256||"")||
    !IMAGE_TYPES.has(raw.mime)||!Number.isSafeInteger(raw.byteCount)||raw.byteCount<1||raw.byteCount>MAX_BYTES)invalid();
  return {id:raw.id,sha256:raw.sha256,mime:raw.mime,byteCount:raw.byteCount};
}
function contractOf(raw) {
  if(!raw||raw.version!==1||!["append","replace"].includes(raw.mode)||
    !Array.isArray(raw.items)||raw.items.length<1||raw.items.length>4)invalid();
  const seen=new Set();
  const items=raw.items.map(item=>{
    if(!item||!["library","asset"].includes(item.kind)||typeof item.role!=="string"||
      !item.role.trim()||item.role.length>80)invalid();
    let out;
    if(item.kind==="library") {
      if(typeof item.id!=="string"||!UUID.test(item.id))invalid();
      out={kind:"library",id:item.id.toUpperCase(),role:item.role.trim()};
    } else out={kind:"asset",...assetDescriptor(item),role:item.role.trim()};
    if(seen.has(out.kind+":"+out.id))invalid("IMAGE_REFERENCES_DUPLICATE");
    seen.add(out.kind+":"+out.id);return out;
  });
  return {version:1,mode:raw.mode,items};
}
function createImageReferenceStore({readFile,assetStore}) {
  if(typeof readFile!=="function"||typeof assetStore?.verifyReferences!=="function"||typeof assetStore?.sign!=="function")invalid();
  async function prepare(owner,raw) {
    if(typeof owner!=="string"||!owner.trim())invalid("IMAGE_REFERENCE_OWNER_REQUIRED");
    const contract=contractOf(raw),references=[];
    for(const item of contract.items) {
      let asset;
      if(item.kind==="library") {
        const row=await readFile(owner,item.id);
        if(!row||row.accountId!==owner||row.kind!=="file"||row.deleted===true||
          typeof row.refId!=="string"||row.refId.toUpperCase()!==item.id)invalid("IMAGE_REFERENCE_NOT_FOUND");
        let file;
        try {file=typeof row.payload==="string"?JSON.parse(row.payload):row.payload;}
        catch {invalid("IMAGE_REFERENCE_NOT_FOUND");}
        if(!file||file.isDeleted===true||file.categoryRaw!=="image"||
          typeof file.id!=="string"||file.id.toUpperCase()!==item.id)invalid("IMAGE_REFERENCE_NOT_FOUND");
        asset=assetDescriptor(file.asset);
      } else asset=assetDescriptor(item);
      references.push({source:item,asset});
    }
    if(new Set(references.map(r=>r.asset.id)).size!==references.length)invalid("IMAGE_REFERENCES_DUPLICATE");
    // All metadata/ownership/readiness checks finish before issuing any URL.
    await assetStore.verifyReferences(owner,references.map(r=>r.asset));
    return {version:1,mode:contract.mode,references};
  }
  return {prepare,async sign(owner,manifest) {
    if(!manifest||manifest.version!==1||!Array.isArray(manifest.references))invalid();
    const fresh=await prepare(owner,{version:1,mode:manifest.mode,items:manifest.references.map(r=>r?.source)});
    if(fresh.references.some((r,i)=>{
      const saved=assetDescriptor(manifest.references[i]?.asset);
      return Object.keys(saved).some(k=>saved[k]!==r.asset[k]);
    }))invalid("IMAGE_REFERENCE_CHANGED");
    const urls=await assetStore.sign(owner,fresh.references.map(r=>r.asset.id));
    return fresh.references.map(ref=>{
      const signed=urls.find(u=>u.id===ref.asset.id);
      if(!signed||typeof signed.url!=="string"||!signed.url.startsWith("https://"))invalid("IMAGE_REFERENCE_SIGN_FAILED");
      return {id:ref.asset.id,role:ref.source.role,url:signed.url};
    });
  }};
}
function createSyncedImageReferenceStore({db,assetStore}) {
  return createImageReferenceStore({assetStore,readFile:async(owner,id)=>
    documentOf(await db.collection("bf_sync_v2").doc(syncRecordKey(owner,"file",id)).get())});
}
module.exports={createImageReferenceStore,createSyncedImageReferenceStore,contractOf,assetDescriptor};
