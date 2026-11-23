"use strict";
const IMAGE=new Set(["image_generate","image_edit","image_series"]);
// Dependency barrier, not a prompt rewrite: old clients already execute a
// recall-only response and send its result in their next model turn.
function deferDependentImageCalls(calls,{enabled=false,canvasEnabled=false,userText="",messages=[],observe=()=>{}}={}){
 if(!enabled||!Array.isArray(calls))return calls;
 const recalls=calls.filter(c=>{if(c?.function?.name!=="recall_history")return false;try{return JSON.parse(c.function.arguments).include_images===true;}catch{return false;}});
 if(!recalls.length||!calls.some(c=>IMAGE.has(c?.function?.name))){
  for(const c of calls)if(IMAGE.has(c?.function?.name)){let a;try{a=JSON.parse(c.function.arguments);}catch{continue;}
   if(typeof a.prompt==="string"&&a.prompt.length>1500)throw Object.assign(new Error("TOOL_ARGUMENTS_INVALID"),{code:"TOOL_ARGUMENTS_INVALID",reason:"PROMPT_TOO_LONG",field:"prompt"});
   if(c.function.name==="image_generate"&&a.structured?.design_brief?.visual_map!==undefined&&!require("./shared/image-design-brief").visualMapOf(a.structured.design_brief,a.structured.text||[]))throw Object.assign(new Error("TOOL_ARGUMENTS_INVALID"),{code:"TOOL_ARGUMENTS_INVALID",reason:"DESIGN_EXECUTION_INVALID",field:"structured.design_brief"});
   require("./poster-reference-readiness").assertRequiredReferences(c,messages);
  }
  return require("./poster-canvas-calls").adaptPosterCanvasCalls(calls,{enabled:canvasEnabled,userText,messages});
 }
 const next=calls.filter(c=>!IMAGE.has(c?.function?.name));
 observe({event:"image_waiting_for_recall",deferred:calls.length-next.length,recalls:recalls.length});
 return next;
}
module.exports={deferDependentImageCalls};
