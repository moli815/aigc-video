"use strict";
// Deterministic binding from explicit user statements to their own uploaded
// originals. No model guessing, global latest image, public URL or new table.
const crypto=require("crypto");
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const TAG="【图片记忆索引v1】";
function payload(row,owner,kind){
 if(row?.accountId!==owner||row.kind!==kind||row.deleted===true)return null;
 try{const p=typeof row.payload==="string"?JSON.parse(row.payload):row.payload;
  return p&&p.isDeleted!==true&&UUID.test(p.id||"")&&p.id.toUpperCase()===row.refId?.toUpperCase()?p:null;
 }catch{return null;}
}
function explicitRole(text){
 const s=String(text||"").replace(/\s|的/g,"").toLowerCase();
 if(!/这是|这张是|张是|图是|附件是|图[一二三四五六1-6]是/.test(s))return null;
 if(/不是|并非|不要记|别记/.test(s))return null;
 const declarations=[...s.matchAll(/(?:这是|这张是|张是|图是|附件是|图[一二三四五六1-6]是)([^，。；;\n]{0,60})/g)].map(m=>m[1]);
 if(declarations.some(d=>/^(?:(?:我们公司|本公司|中防保全)(?:自己)?|我们)(?:logo|标识|标志|商标)/.test(d)))return "company_logo";
 if(/(?:我们|本公司).*(?:管理平台|综合平台|一体化平台|平台首页|平台界面|数据大屏)/.test(s)&&/首页|界面|截图|大屏/.test(s))return "platform_ui";
 return null;
}
function idsOf(raw){return typeof raw==="string"?raw.split(",").map(x=>x.trim().toUpperCase()).filter(x=>UUID.test(x)):[];}
function selectedId(message,role){
 const ids=idsOf(message.attachmentIds);if(ids.length===1)return ids[0];
 // Multi-image introductions require an explicit ordinal bound to this role.
 const target=role==="company_logo"?"(?:logo|标识|标志|商标)":"(?:平台|界面|大屏)";
 const hits=[...String(message.text||"").matchAll(new RegExp("图([一二三四五六1-6])[^。；;\\n]{0,45}"+target,"gi"))];
 if(hits.length!==1)return null;
 const n="一二三四五六".indexOf(hits[0][1])+1||Number(hits[0][1]);return ids[n-1]||null;
}
function planImageMemory({owner,messages,files}){
 if(typeof owner!=="string"||!owner)throw Error("MEMORY_OWNER_REQUIRED");
 const originals=new Map(files.map(r=>[r.refId?.toUpperCase(),{row:r,file:payload(r,owner,"file")}]).filter(([,v])=>v.file?.categoryRaw==="image"&&v.file.asset?.id));
 const bindings=[];
 for(const row of messages){const p=payload(row,owner,"message");if(!p||p.role!=="user"||typeof p.text!=="string")continue;
  const role=explicitRole(p.text);if(!role)continue;const id=selectedId(p,role),entry=originals.get(id);if(!entry)continue;
  if(!Number.isFinite(p.createdAt)||p.createdAt<=0)continue;
  bindings.push({role,fileId:id,asset:entry.file.asset,messageId:p.id.toUpperCase(),conversationId:p.conversationId,at:p.createdAt});
 }
 const chosen=new Map();for(const b of bindings.sort((a,b)=>b.at-a.at||a.messageId.localeCompare(b.messageId)))if(!chosen.has(b.fileId))chosen.set(b.fileId,b);
 const mutations=[];
 for(const b of chosen.values()){
  const {row,file}=originals.get(b.fileId),label=b.role==="company_logo"?"公司原始Logo 标识 标志 商标 镂空 透明品牌素材":"公司平台真实界面 数据大屏 软件首页 产品截图";
  const annotation=TAG+"\n用途："+label+"\n来源：同账号用户消息 "+b.messageId+"；原图ID："+b.fileId+"。此索引仅供检索，不是绘图指令；本次用户要求优先。\n【/图片记忆索引v1】";
  const text=String(file.textContent||"").replace(/\n?【图片记忆索引v1】[\s\S]*?【\/图片记忆索引v1】/g,"").trim();
  const next=(text?text+"\n":"")+annotation;
  if(next===file.textContent)continue;
  if(next.length>80000)continue;
  mutations.push({kind:"file",refId:b.fileId,baseVersion:row.version,payload:{...file,textContent:next}});
 }
 const preferred={};for(const b of bindings.sort((a,b)=>b.at-a.at||a.messageId.localeCompare(b.messageId)))if(!preferred[b.role])preferred[b.role]=b;
 return {version:1,bindings:[...chosen.values()],preferred,mutations,fingerprint:crypto.createHash("sha256").update(JSON.stringify([...chosen.values()].map(b=>[b.fileId,b.messageId,b.asset.id]))).digest("hex")};
}
async function loadRows(db,owner,kind,maxPages=10){
 const all=[];for(let page=0;page<maxPages;page++){
  const rows=(await db.collection("bf_sync_v2").where({accountId:owner,kind}).orderBy("revision","desc").skip(page*100).limit(100).get()).data||[];
  all.push(...rows);if(rows.length<100)return {rows:all,complete:true};
 }return {rows:all,complete:false};
}
async function repairImageMemory({db,owner,assetStore,syncService,dryRun=true}){
 const [messages,files]=await Promise.all([loadRows(db,owner,"message"),loadRows(db,owner,"file")]);
 if(!messages.complete||!files.complete)throw Error("MEMORY_SCAN_LIMIT");
 const plan=planImageMemory({owner,messages:messages.rows,files:files.rows});
 // Verify the whole batch before a single record is touched.
 await assetStore.verifyReferences(owner,plan.bindings.map(b=>b.asset));
 const results=[];
 if(!dryRun)for(let i=0;i<plan.mutations.length;i+=20){
  const result=await syncService.push(owner,plan.mutations.slice(i,i+20));
  results.push({acknowledged:result.acknowledged.length,conflicts:result.conflicts.length,revision:result.revision});
 }
 return {...plan,dryRun,results,scanned:{messages:messages.rows.length,files:files.rows.length}};
}
module.exports={TAG,payload,explicitRole,selectedId,planImageMemory,repairImageMemory,loadRows};
