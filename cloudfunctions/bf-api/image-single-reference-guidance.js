"use strict";
const {contractOf}=require('./shared/image-reference-store');
const {recalledIds}=require('./image-series-reference-guidance');
const {mixedReferencesEnabled}=require('./shared/image-reference-merge');
const singles=new Set(['image_edit','image_generate']);
function conflict(code='IMAGE_REFERENCE_CONFLICT'){throw Object.assign(new Error(code),{code});}
async function prepareSingleReferenceGuidance({messages,tools,owner,referenceStore,policy}){
 if(!mixedReferencesEnabled(policy,owner)||!Array.isArray(tools)||!tools.some(t=>singles.has(t?.function?.name)&&t.function.parameters?.properties?.structured))return {messages,tools,finalize:c=>c};
 const options=typeof policy==='string'?JSON.parse(policy):policy;
 // Admit cached execution contracts first, then enable new planning after both
 // functions' runtime caches have refreshed. This avoids rollout-time 422s.
 if(options.planningEnabled===false)return {messages,tools,finalize:c=>c};
 const ids=[];for(const id of recalledIds(messages))try{await referenceStore.prepare(owner,{version:1,mode:'replace',items:[{kind:'library',id,role:'历史素材'}]});ids.push(id);}catch{}
 const allowed=new Set(ids);
 const schema=ids.length?tools.map(tool=>{const f=tool?.function,p=f?.parameters;if(!singles.has(f?.name)||!p?.properties?.structured)return tool;
  const s=p.properties.structured;return {...tool,function:{...f,parameters:{...p,properties:{...p.properties,structured:{...s,properties:{...s.properties,
   image_references:{type:'object',description:'当前底图加已检索历史原图；仅适用单图混合，不用于preserve_assets本地Logo合成。',properties:{version:{type:'integer',enum:[1]},mode:{type:'string',enum:['append']},items:{type:'array',minItems:1,maxItems:3,items:{type:'object',properties:{kind:{type:'string',enum:['library']},id:{type:'string',enum:ids},role:{type:'string',enum:['历史原图1','历史原图2','历史原图3'],description:'只声明输入位置；主体用途写在prompt，不猜图片分类。'}},required:['kind','id','role']}}},required:['version','mode','items']}
  }}}}}};}):tools;
 const next=ids.length?[...messages,{role:'system',content:'【当前底图+历史原图·单图混合V1】已校验当前账号可用历史原图编号：'+JSON.stringify(ids)+'。用户要求将这些历史素材加入本轮附件或最近生成图时，用image_edit/image_generate和原有source选择真实当前图，历史原图写structured.image_references={version:1,mode:"append",items:[{kind:"library",id:已发放编号,role:"历史原图1"}]}。此时不要再填顶层library_refs，它会让已安装客户端丢掉当前底图。当前底图先传，服务端再追加这些原图，总计最多4张。只选本次需要的原图；编号不能证明画面内容，未知角色也只写历史原图N；具体主体与用户要求写在prompt，不把分类猜测当作已验证结果。只用历史原图且没有当前底图时，仍沿用原library_refs。preserve_assets的精确Logo保真必须保持原本地合成流程，不得和这个混合字段一起用；不能为了接混合而删preserve_assets改成重绘Logo。组图仍沿用既有历史replace契约，未送达的当前附件不能靠描述替代。'}]:messages;
 return {messages:next,tools:schema,finalize(calls){return calls.map(call=>{
  if(!singles.has(call?.function?.name))return call;
  const args=JSON.parse(call.function.arguments),structured=args.structured||{},local=Array.isArray(structured.preserve_assets)&&structured.preserve_assets.length;
  let raw=structured.image_references;
  if(args.library_refs!=null&&!Array.isArray(args.library_refs))conflict();
  const current=['last','attached','both'].includes(args.source);
  if(!raw&&current&&Array.isArray(args.library_refs)&&args.library_refs.length&&!local){raw={version:1,mode:'append',items:args.library_refs.map((id,i)=>({kind:'library',id,role:'历史素材'+(i+1)}))};}
  if(!raw)return call;
  let contract;try{contract=contractOf(raw);}catch{conflict();}
  if(local||!current||contract.mode!=='append')conflict();
  if(contract.items.some(i=>i.kind!=='library'||!allowed.has(i.id)))conflict('IMAGE_REFERENCE_NOT_ISSUED');
  if(args.library_refs){const legacy=contractOf({version:1,mode:'append',items:args.library_refs.map((id,i)=>({kind:'library',id,role:contract.items[i]?.role||'历史素材'}))});if(JSON.stringify(legacy)!==JSON.stringify(contract))conflict();}
  const aliases=contract.items.map(i=>i.role);
  contract={...contract,items:contract.items.map((item,i)=>{
    const role='历史原图'+(i+1),alias=item.role;
    // Bind source aliases to slots instead of presenting a model's guessed
    // "person material" as a verified classification of a cabinet/product.
    if(aliases.filter(s=>s===alias).length===1&&alias.length>=4&&/(素材|原图|参考图|照片)$/.test(alias)&&typeof args.prompt==='string')args.prompt=args.prompt.split(alias).join(role);
    return {...item,role};
  })};
  args.structured={...structured,image_references:contract};delete args.library_refs;
  // In legacy library_refs calls these roles described historical files, not
  // the current image slots. Leave only roles bound to actual source_indexes.
  if(!Array.isArray(args.source_indexes))delete args.reference_roles;
  return {...call,function:{...call.function,arguments:JSON.stringify(args)}};
 });}};
}
module.exports={prepareSingleReferenceGuidance};
