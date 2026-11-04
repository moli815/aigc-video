"use strict";
// Merge only references backed by the caller's durable, owned originals.
const crypto=require('node:crypto');
const {contractOf,assetDescriptor}=require('./image-reference-store');
const extensions={'image/png':'png','image/jpeg':'jpg','image/webp':'webp','image/gif':'gif'};
const hash=s=>crypto.createHash('sha256').update(s).digest('hex');
function mixedReferencesEnabled(raw,owner){
 let p=raw;if(typeof raw==='string'){if(raw.length>6000)return false;try{p=JSON.parse(raw);}catch{return false;}}
 return !!(owner&&p?.enabled===true&&(p.audience==='all'||Array.isArray(p.accountIds)&&p.accountIds.length<=100&&p.accountIds.includes(owner)));
}
function fail(code){throw Object.assign(new Error(code),{code});}
function referenceFailure(error){
 const raw=String(error?.code||error?.message||''),diagnostic=/^[A-Z][A-Z0-9_]{0,79}$/.test(raw)?raw:'REFERENCE_STORAGE_UNAVAILABLE';
 const invalid=/^IMAGE_REFERENCES_(INVALID|DUPLICATE|LIMIT)$|^IMAGE_REFERENCE_(CURRENT_(INVALID|UNAVAILABLE|REQUIRED)|ROLES_INVALID|NOT_FOUND|CHANGED|CONFLICT)$|^(INVALID_ASSET_ID|ASSET_(NOT_FOUND|NOT_READY|METADATA_CONFLICT))$/.test(diagnostic);
 return {status:invalid?422:503,diagnostic,msg:invalid?'这次需要的底图或历史原图尚未完整同步，请重新选择原图后再试。这次没有生成图片或扣费。':'暂时无法读取这次需要的原图，请稍后重试。这次没有生成图片或扣费。'};
}
function bindReferenceRequest(fingerprint,body){
 const stable=x=>Array.isArray(x)?x.map(stable):x&&typeof x==='object'?Object.fromEntries(Object.keys(x).sort().map(k=>[k,stable(x[k])])):x;
 const structured={...(body.structured||{})};delete structured.image_references;
 return hash(JSON.stringify(stable({version:1,references:fingerprint,prompt:String(body.prompt||''),structured,
  size:body.size,aspectRatio:body.aspect_ratio||body.aspectRatio,taskKind:body.task_kind||body.taskKind||'edit',qualityTier:body.quality_tier||body.qualityTier||'auto',
  renderIntent:body.render_intent||body.renderIntent||'',textMode:body.text_mode||'',requestedCount:body.requested_count||body.requestedCount||1})));
}
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
module.exports={currentPointer,currentItems,prepareMixedReferenceInput,mixedReferencesEnabled,referenceFailure,bindReferenceRequest};
