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
function indexesCompanyImages(composition,mixed,owner){
  return require('./shared/image-workflow').enabled(composition,owner)||brandEnabled(mixed,owner)
    ||(mixedReferencesEnabled(mixed,owner)&&require('./shared/poster-delivery').compactBriefEnabled(composition,owner));
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

function currentImageNeedsCompanyLogo(messages){
  if(require('./reference-text').currentImageParts(messages).length!==1)return false;
  const text=require('./shared/verbatim-image-prompt').authoredText(messages);
  const own=/(?:我们(?:的|公司|企业|品牌)?|本公司|公司|企业|品牌)\s*的?\s*(?:logo|标志|标识|商标)/iu;
  const use=/(?:加|用|放|带|补|配|展示|保留)[^。；;\n]{0,55}(?:logo|标识|标志|商标)/iu;
  const excluded=/(?:不要|不用|不必|不加|不需要|移除|去掉|别用)[^。；;\n]{0,16}(?:logo|标识|标志|商标|历史|这张图)|联名|合作方|合作伙伴的|他们的|客户的|对方的|(?:之前|上一张|上次|刚才|刚生成)的?(?:底图|海报|成图)|(?:这是|这张是|图一是|附件是)[^，。；;\n]{0,16}(?:logo|标识|商标)/iu;
  // The single upload can itself be the logo; it is not necessarily the canvas.
  const currentLogo=/(?:这(?:个|张|份)|(?:本轮|本次|这次|刚刚?|刚才|新)(?:上传|发来|发给你)|附件(?:中|里)?)(?:的)?\s*(?:(?:我们|我)(?:的)?)?(?:公司|企业|品牌)?的?\s*(?:新版?|新)?\s*(?:logo|标识|标志|商标)/iu;
  const previousLogo=/(?:以前|之前|上次|历史|先前|原先)[^，,。；;\n]{0,16}(?:logo|标识|标志|商标)/iu;
  const base=/(?:这[张幅个]|本[轮次]|当前|上传的)\s*(?:的)?[^，,。；;\n]{0,10}(?:图|海报|照片)/u;
  return own.test(text)&&use.test(text)&&!excluded.test(text)&&!currentLogo.test(text)
    &&(base.test(text)||previousLogo.test(text));
}

function bindCurrentWithLogo(args,logo){
  const s=args.structured||{},fail=()=>{throw Object.assign(Error('TOOL_ARGUMENTS_INVALID'),{
    code:'TOOL_ARGUMENTS_INVALID',reason:'HISTORY_REQUIRED_MISSING',field:'structured.image_references'});};
  // A private file UUID is not a current iOS attachment index. Keep incompatible
  // local-composition contracts out of the mixed-input path.
  if(s.preserve_assets?.length||s.poster_reformat||args.layer_decomposition)return fail();
  const raw=args.image_references||s.image_references;
  if(args.image_references&&s.image_references)return fail();
  if(raw&&require('./shared/image-reference-store').contractOf(raw).items.some(i=>i.kind!=='library'||i.id!==logo.fileId))return fail();
  if(args.library_refs&&(!Array.isArray(args.library_refs)||args.library_refs.some(id=>String(id).toUpperCase()!==logo.fileId)))return fail();
  args.source='attached';args.source_index=1;
  delete args.source_indexes;delete args.reference_roles;delete args.library_refs;delete args.image_references;
  args.structured={...s,image_references:{version:1,mode:'append',items:[{kind:'library',id:logo.fileId,role:BRAND_ROLE}]}};
  return true;
}

async function preparePosterBrand({db,owner,policy,referenceStore,text,hasCurrentImages}){
  if(hasCurrentImages||!brandEnabled(policy,owner)||!requestedBrand(text)||!posterRequested("",text))return null;
  return lookupCompanyLogo({db,owner,referenceStore});
}

// The sync index is only a candidate list. Recheck the original declaration and file owner.
async function lookupCompanyLogo({db,owner,referenceStore,fileIds=[],unique=false}){
  const col=db.collection("bf_sync_v2");
  const files=fileIds.length ? (await Promise.all(fileIds.map(id=>col.doc(syncRecordKey(owner,"file",id)).get().then(documentOf)))).filter(Boolean) : (await col.where({accountId:owner,kind:"file",deleted:false}).orderBy("revision","desc").limit(100).get()).data||[];
  if(unique&&!fileIds.length&&files.length===100)return null;
  // Read only declarations actually tied to the existing private image index.
  const matches=files.flatMap(row=>{
    const file=payload(row,owner,"file");
    const note=file?.textContent?.match(/【图片记忆索引v1】\n用途：公司原始Logo[^\n]*\n来源：同账号用户消息 ([A-F0-9-]{36})；原图ID：([A-F0-9-]{36})。/i);
    return note&&note[2].toUpperCase()===row.refId.toUpperCase()?[{row,messageId:note[1].toUpperCase()}]:[];
  });
  if(unique&&matches.length>10)return null;
  matches.splice(10);
  const declarations=[...new Set(matches.map(m=>m.messageId))];
  const [indexedMessages,recent]=await Promise.all([
    Promise.all(declarations.map(id=>col.doc(syncRecordKey(owner,"message",id)).get().then(documentOf))),
    unique&&matches.length<files.length ? col.where({accountId:owner,kind:"message"}).orderBy("revision","desc").limit(100).get() : null
  ]);
  const messages=new Map();
  for(const row of [...indexedMessages,...(recent?.data||[])])if(row)messages.set(row.refId,row);
  const {preferred,bindings}=planImageMemory({owner,messages:[...messages.values()],files});
  const brand=preferred.company_logo;
  if(!brand||unique&&new Set(bindings.filter(b=>b.role==="company_logo").map(b=>b.asset.id)).size!==1)return null;
  const ref=await referenceStore.prepare(owner,{version:1,mode:"replace",items:[{kind:"library",id:brand.fileId,role:BRAND_ROLE}]});
  return ref.references[0]?.asset.id===brand.asset.id ? brand:null;
}

module.exports={BRAND_ROLE,brandEnabled,indexesCompanyImages,requestedBrand,anchorFor,addBrand,preparePosterBrand,currentImageNeedsCompanyLogo,bindCurrentWithLogo,lookupCompanyLogo};

