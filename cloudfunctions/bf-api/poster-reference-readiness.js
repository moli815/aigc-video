"use strict";
// Validate only explicit role/ordinal bindings on CURRENT user attachments.
// No global recent image, guessed role, URL persistence or cross-account lookup.
function requiredCurrentSources(messages) {
  const current = (Array.isArray(messages) ? messages : []).filter(m => m?.role === "user").at(-1);
  if (!Array.isArray(current?.content)) return [];
  const count = current.content.filter(p => p?.type === "image_url").length;
  const text = current.content.filter(p => p?.type === "text").map(p => p.text || "").join("\n");
  if (!count || /历史图片预览|非当前附件|刚生成的图片预览/.test(text)) return [];
  const ord = v => "一二三四五六七八九十".indexOf(v) + 1 || Number(v);
  const required = [];
  for (const m of text.matchAll(/(?:图|附件)\s*([一二三四五六七八九十]|10|[1-9])\s*[：:是]\s*([^\n。；;]{1,100})/g)) {
    const index = ord(m[1]), role = m[2];
    if (index > count || /仅.*风格|只是.*风格|仅.*样式/.test(role)) continue;
    const logo = /logo|商标|标志原件/i.test(role) && /原件|原图|我们|公司|品牌/.test(role);
    const ui = /真实|实际|原件/.test(role) && /大屏|平台|界面|截图/.test(role);
    const requested = logo ? /(?:用|保留|贴|加|放|带).{0,20}(?:logo|商标|标志)/i.test(text) && !/不要(?:加|放|用)?\s*logo/i.test(text)
      : ui && /(?:用|保留|展示).{0,20}(?:大屏|平台|界面|截图)/.test(text);
    if (requested && !required.includes(index)) required.push(index);
  }
  return required;
}
function assertRequiredReferences(call, messages) {
  if (call?.function?.name !== "image_generate") return;
  let a; try { a = JSON.parse(call.function.arguments); } catch { return; }
  const required = requiredCurrentSources(messages);
  if (!required.length) return;
  if (a.library_refs || ["last", "both"].includes(a.source)) return;
  const selected = a.source === "attached" ? a.source_indexes || [a.source_index || 1] : [];
  const missing = required.filter(i => !Array.isArray(selected) || !selected.includes(i));
  if (missing.length) throw Object.assign(Error("TOOL_ARGUMENTS_INVALID"), {
    code: "TOOL_ARGUMENTS_INVALID", reason: "REFERENCE_REQUIRED_MISSING", field: "source_indexes", requiredSourceIndexes: required
  });
}
function historicalRecallChoice({messages,tools,enabled=false,ownedReferenceCount=0}) {
  if(!enabled||ownedReferenceCount>0||!Array.isArray(tools)||!tools.some(t=>t?.function?.name==="recall_history"))return null;
  const {latestUserText,isHistoryPreview}=require("./shared/image-delivery");
  const text=latestUserText(messages);
  if(!/海报|宣传图|产品长图|信息图/.test(text)||!/之前|以前|上次|历史/.test(text)||!/大屏|logo|原图|图片|截图/i.test(text)||/不要.{0,8}(?:检索|召回|历史)/.test(text))return null;
  const latest=[...messages].reverse().find(m=>m?.role==="user"&&!isHistoryPreview(m));
  if(Array.isArray(latest?.content)&&latest.content.some(p=>p?.type==="image_url"))return null;
  const recallIds=new Set();
  for(const m of messages){
    if(m?.role==="assistant")for(const c of m.tool_calls||[])if(c?.function?.name==="recall_history")recallIds.add(c.id);
    if(m?.role==="tool"&&recallIds.has(m.tool_call_id))return null;
  }
  return {type:"function",function:{name:"recall_history"}};
}
// Enforce only explicit requests and a unique binding in recall's returned
// records. Ownership is checked separately; descriptions never authorize a file.
function requiredHistoricalSources(messages, allowed) {
  const {latestUserText}=require("./shared/image-delivery");
  const text=latestUserText(messages), calls=new Set(), rows=new Map();
  if(!/之前|以前|上次|历史/.test(text)||!/用|保留|带|加|放|展示/.test(text))return [];
  for(const m of messages){
    if(m?.role==="assistant")for(const c of m.tool_calls||[])if(c?.function?.name==="recall_history")calls.add(c.id);
    if(m?.role!=="tool"||!calls.has(m.tool_call_id)||typeof m.content!=="string")continue;
    for(const hit of m.content.matchAll(/(?:^|\n)图片ID[:：]\s*([a-f0-9-]{36})([^]*?)(?=\n图片ID[:：]|$)/gi)){
      const id=hit[1].toUpperCase();if(allowed.has(id))rows.set(id,hit[2]);
    }
  }
  const required=[];
  for(const [requested,descriptor,excluded]of [[/大屏|界面|截图/,/大屏|界面|截图/,/(?:不用|不要|不带|不加|去掉).{0,5}(?:大屏|界面|截图)/],[/logo|商标|标志/i,/logo|商标|标志/i,/(?:不用|不要|不带|不加|去掉).{0,5}(?:logo|商标|标志)/i]]){
    if(!requested.test(text)||excluded.test(text))continue;
    const matches=[...rows].filter(([,d])=>descriptor.test(d)&&!/仅.*风格|只是.*风格|只借.*层级/.test(d));
    if(matches.length===1&&!required.includes(matches[0][0]))required.push(matches[0][0]);
  }
  return required;
}
function assertNativePlanCalls(calls,{enabled=false,policy,owner}={}){
 if(!enabled)return calls;
 for(const c of calls||[]){if(c.function?.name!=='image_generate')continue;let a;try{a=JSON.parse(c.function.arguments);}catch{continue;}
  if(!a.structured?.image_plan||a.structured.preserve_assets?.length)continue;
  const history=a.structured.image_references;
  const current=a.source==='attached'?(a.source_indexes||[a.source_index||1]).length:a.source==='last'?1:a.source==='both'?2:0;
  const count=history?.mode==='replace'?history.items.length:current+(history?.items?.length||a.library_refs?.length||0);
  try{require('./shared/image-workflow').compile({structured:a.structured,image:Array(count).fill('owned-slot'),taskKind:'generate',policy,owner});}
  catch(error){const shape=error.code==='IMAGE_PLAN_INVALID';throw Object.assign(Error('TOOL_ARGUMENTS_INVALID'),{code:'TOOL_ARGUMENTS_INVALID',reason:shape?'PLAN_ENUM_INVALID':'PLAN_REFERENCE_MISMATCH',field:shape?'structured.image_plan':'structured.image_references'});}
 }return calls;
}
module.exports = { requiredCurrentSources, assertRequiredReferences, historicalRecallChoice, requiredHistoricalSources,assertNativePlanCalls };
