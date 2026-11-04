"use strict";
const REASONS=new Set(["JSON_SYNTAX","ARGUMENTS_NOT_OBJECT","TEXT_ENTRY_INVALID","TEXT_ARRAY_INVALID","PROMPT_INVALID"]);
function diagnostic(error) {
  return { reason:REASONS.has(error?.reason)?error.reason:"CONTRACT_REJECTED",
    field:typeof error?.field==="string" && /^(?:arguments|prompt|structured\.text(?:\[\d{1,3}\])?(?:\.text)?)$/.test(error.field)?error.field:"",
    code:["TOOL_ARGUMENTS_INVALID","BRAND_PLAN_CONFLICT","IMAGE_REFERENCE_CONFLICT","IMAGE_REFERENCE_NOT_ISSUED"].includes(error?.code)?error.code:"TOOL_CONTRACT_INVALID" };
}
async function repairImageCompletion({error,body,released=false,request,sanitize,observe=()=>{}}) {
  const info=diagnostic(error);
  if(released || error?.code!=="TOOL_ARGUMENTS_INVALID" || !REASONS.has(info.reason))return null;
  observe({event:"attempt",...info});
  const repairBody={...body,stream:false,n:1,messages:[...body.messages,{role:"system",content:
    "上一轮图片工具参数未通过格式校验，图片尚未执行。本轮只重新编译同一用户任务的工具参数，不补编事实或更换素材。"+
    "必须输出可由JSON.parse解析的完整JSON，不含注释或1/3等表达式。prompt必须是字符串；structured.text必须是数组，每项key、role、text均为字符串，"+
    "role仅用title/subtitle/body/label/contact/footer；一个栏目正文放text字符串，不能放嵌套对象或数组。已确认公司、产品、标题、电话、数值与单位逐字保留。"+
    "安全格式诊断："+info.reason+"，字段："+info.field}]};
  delete repairBody.stream_options;
  try {
    const raw=await request(repairBody);
    if(raw?.choices?.some(c=>["length","content_filter"].includes(c.finish_reason)))throw Error("REPAIR_INCOMPLETE");
    const data=sanitize(raw);
    const calls=data?.choices?.[0]?.message?.tool_calls;
    if(!Array.isArray(calls)||!calls.some(c=>["image_generate","image_edit","image_series","image_decompose"].includes(c.function?.name)))throw Error("REPAIR_NO_IMAGE_TOOL");
    observe({event:"recovered",...info});return data;
  } catch(e) { observe({event:"failed",...diagnostic(e),failure:["AbortError","TimeoutError"].includes(e?.name)?"TIMEOUT":["REPAIR_INCOMPLETE","REPAIR_NO_IMAGE_TOOL","REPAIR_UPSTREAM_UNAVAILABLE"].includes(e?.message)?e.message:"CONTRACT_OR_TRANSPORT"});return null; }
}
module.exports={diagnostic,repairImageCompletion};
