"use strict";
// Preparation only. Not wired to public handlers until the complete old-client
// contract, idempotency claim and retry path are validated together.
const crypto=require('node:crypto');
const {contractOf,assetDescriptor}=require('./image-reference-store');
const extensions={'image/png':'png','image/jpeg':'jpg','image/webp':'webp','image/gif':'gif'};
const hash=s=>crypto.createHash('sha256').update(s).digest('hex');
function fail(code){throw Object.assign(new Error(code),{code});}
function currentPointer(owner,raw){
 if(typeof owner!=='string'||!owner.trim())fail('IMAGE_REFERENCE_OWNER_REQUIRED');
 if(typeof raw!=='string'||raw.length>16384)fail('IMAGE_REFERENCE_CURRENT_INVALID');
 let url;try{url=new URL(raw);}catch{fail('IMAGE_REFERENCE_CURRENT_INVALID');}
 if(url.protocol!=='https:'||url.username||url.password||url.hash||(url.port&&url.port!=='443')||
   !url.hostname.endsWith('.myqcloud.com'))fail('IMAGE_REFERENCE_CURRENT_INVALID');
 // The URL is a locator, never an authorization capability. Do not fetch it.
 // The canonical account path locates a record that is checked again below.
 const match=url.pathname.match(/^\/user\/([a-f0-9]{24})\/assets\/([a-f0-9]{64})\.(png|jpg|webp|gif)$/);
 if(!match||match[1]!==hash(owner).slice(0,24))fail('IMAGE_REFERENCE_CURRENT_UNAVAILABLE');
 return {id:hash(owner+':'+match[2]).slice(0,40),sha256:match[2],ext:match[3],cloudPath:url.pathname.slice(1)};
}
async function currentItems({owner,image,referenceRoles,readAsset}){
 const images=Array.isArray(image)?image:image?[image]:[];
 if(images.length<1||images.length>4||typeof readAsset!=='function')fail('IMAGE_REFERENCE_CURRENT_REQUIRED');
 if(referenceRoles!=null&&(!Array.isArray(referenceRoles)||referenceRoles.length!==images.length||referenceRoles.some(r=>typeof r!=='string'||!r.trim()||r.length>80)))fail('IMAGE_REFERENCE_ROLES_INVALID');
 const items=[];
 for(const [index,url]of images.entries()){
  const pointer=currentPointer(owner,url),row=await readAsset(owner,pointer.id);
  if(!row||row._id!==pointer.id||row.accountId!==owner||row.state!=='ready'||
    row.sha256!==pointer.sha256||row.cloudPath!==pointer.cloudPath||extensions[row.mime]!==pointer.ext||
    typeof row.fileID!=='string'||!row.fileID.startsWith('cloud://')||!row.fileID.endsWith('/'+pointer.cloudPath))fail('IMAGE_REFERENCE_CURRENT_UNAVAILABLE');
  const asset=assetDescriptor({id:row._id,sha256:row.sha256,mime:row.mime,byteCount:row.byteCount});
  items.push({kind:'asset',...asset,role:referenceRoles?.[index]?.trim()||(index===0?'当前底图':'当前素材'+(index+1))});
 }
 return items;
}
async function prepareMixedReferenceInput({store,readAsset,owner,structured,image,referenceRoles}){
 const raw=structured?.image_references;
 if(raw==null)return {referenceManifest:null,referenceFingerprint:''};
 const selection=contractOf(raw);
 let current=[];
 if(selection.mode==='replace'){
  if(image&&(Array.isArray(image)?image.length>0:true))fail('IMAGE_REFERENCE_CONFLICT');
 }else{
  const count=Array.isArray(image)?image.length:image?1:0;
  if(count+selection.items.length>4)fail('IMAGE_REFERENCES_LIMIT');
  current=await currentItems({owner,image,referenceRoles,readAsset});
 }
 // Existing store checks every owned/ready original, duplicates and metadata
 // before any signature. No raw URLs, query tokens or pixels reach persistence.
 const referenceManifest=await store.prepare(owner,{version:1,mode:'replace',items:[...current,...selection.items]});
 const referenceFingerprint=hash(JSON.stringify({version:1,selection,current}));
 return {referenceManifest,referenceFingerprint};
}
module.exports={currentPointer,currentItems,prepareMixedReferenceInput};
