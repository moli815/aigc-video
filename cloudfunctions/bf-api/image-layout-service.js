"use strict";
const crypto=require("crypto"),protocol=require("./shared/image-layout-protocol");
function createLayoutService({request,cacheGet=async()=>null,cachePut=async()=>{},bill=async()=>{}}){
 const pending=new Map();
 return {async analyze(owner,raw,model){
  if(!owner||!model)throw Error("IMAGE_LAYOUT_UNAVAILABLE");
  const input=protocol.requestOf(raw),key="layout1_"+crypto.createHash("sha256").update(protocol.VERSION+"\0"+owner+"\0"+model+"\0"+JSON.stringify(input)).digest("hex");
  const cached=await cacheGet(key).catch(()=>null);if(cached)try{return {...protocol.responseOf(typeof cached==="string"?JSON.parse(cached):cached,input),cached:true};}catch{}
  if(pending.has(key))return pending.get(key);
  const task=(async()=>{
   const r=await request({model,messages:protocol.messagesOf(input),stream:false,enable_thinking:false,max_tokens:3500,response_format:{type:"json_object"}});
   // Charge once for the completed provider call even if semantic validation fails.
   await bill(r,owner);
   const content=r.choices?.[0]?.message?.content;let parsed;
   try{parsed=JSON.parse(String(content).replace(/^```(?:json)?\s*|\s*```$/g,"").trim());}catch{throw Error("IMAGE_LAYOUT_UNCERTAIN");}
   const result=protocol.responseOf(parsed,input);await cachePut(key,JSON.stringify(result)).catch(()=>{});return result;
  })();pending.set(key,task);try{return await task;}finally{pending.delete(key);}
 }};
}
module.exports={createLayoutService};
