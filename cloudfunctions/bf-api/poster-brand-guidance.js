"use strict";
const {documentOf}=require("./shared/document-store");
const {syncRecordKey}=require("./shared/sync-identifiers");
const {mixedReferencesEnabled}=require("./shared/image-reference-merge");
const {posterRequested}=require("./shared/poster-delivery");
const {payload,planImageMemory}=require("./account-image-memory");

const BRAND_ROLE="公司Logo原件";
const anchors={左上:"top_left",右上:"top_right",左下:"bottom_left",右下:"bottom_right"};

function brandEnabled(policy,owner){
  if(!mixedReferencesEnabled(policy,owner))return false;
  const options=typeof policy==="string"?JSON.parse(policy):policy;
  return options.posterBrand===true;
}
function requestedBrand(text){
  return /(?:我们公司|自己公司|我们品牌|本公司|公司(?:自己的)?(?:logo|标志|标识))/i.test(text)
    && !/(?:不要|不用|不需要|无|去掉|去除|删掉|省略|别).{0,12}(?:logo|标识|标志|品牌)/i.test(text)
    && !/(?:联名|联合主办|双品牌|(?:双方|两家|合作方|合作伙伴).{0,10}(?:logo|标识|标志))/i.test(text);
}
function anchorFor(text){
  const matches=[...text.matchAll(/(?:logo|标识|标志)[^。；，\n]{0,14}([左右][上下])|([左右][上下])[^。；，\n]{0,12}(?:logo|标识|标志)/ig)];
  return anchors[matches.at(-1)?.[1]||matches.at(-1)?.[2]]||"auto";
}
function addBrand(calls,binding,text){
  if(!binding)return calls;
  return calls.map(call=>{
    const f=call?.function;
    if(f?.name!=="image_generate")return call;
    let a;try{a=JSON.parse(f.arguments);}catch{return call;}
    const s=a.structured||{};
    if(a.source&&!["none","auto"].includes(a.source)||a.library_refs||a.source_indexes||a.source_index
        ||s.image_references||s.preserve_assets?.length||s.image_plan||s.poster_reformat||a.text_mode==="overlay"
        ||a.render_intent==="mockup"||!posterRequested(a.render_intent,a.prompt,text))return call;
    a.source="none";
    a.structured={...s,
      image_references:{version:1,mode:"replace",items:[{kind:"library",id:binding.fileId,role:BRAND_ROLE}]},
      poster_brand:{version:1,anchor:anchorFor(text)}};
    return {...call,function:{...f,arguments:JSON.stringify(a)}};
  });
}

async function preparePosterBrand({db,owner,policy,referenceStore,text,hasCurrentImages}){
  if(hasCurrentImages||!brandEnabled(policy,owner)||!requestedBrand(text)||!posterRequested("",text))return null;
  const col=db.collection("bf_sync_v2");
  const files=(await col.where({accountId:owner,kind:"file",deleted:false}).orderBy("revision","desc").limit(100).get()).data||[];
  // Read only declarations actually tied to the existing private image index.
  const matches=files.flatMap(row=>{
    const file=payload(row,owner,"file");
    const note=file?.textContent?.match(/【图片记忆索引v1】\n用途：公司原始Logo[^\n]*\n来源：同账号用户消息 ([A-F0-9-]{36})；原图ID：([A-F0-9-]{36})。/i);
    return note&&note[2].toUpperCase()===row.refId.toUpperCase()?[{row,messageId:note[1].toUpperCase()}]:[];
  }).slice(0,10);
  const messages=await Promise.all(matches.map(({messageId})=>col.doc(syncRecordKey(owner,"message",messageId)).get().then(documentOf)));
  const {preferred}=planImageMemory({owner,messages:messages.filter(Boolean),files:matches.map(x=>x.row)});
  const brand=preferred.company_logo;
  if(!brand)return null;
  const ref=await referenceStore.prepare(owner,{version:1,mode:"replace",items:[{kind:"library",id:brand.fileId,role:BRAND_ROLE}]});
  return ref.references[0]?.asset.id===brand.asset.id ? brand:null;
}

module.exports={BRAND_ROLE,brandEnabled,requestedBrand,anchorFor,addBrand,preparePosterBrand};

