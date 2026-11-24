"use strict";
const REASONS=new Set(["JSON_SYNTAX","ARGUMENTS_NOT_OBJECT","TEXT_ENTRY_INVALID","TEXT_ARRAY_INVALID","PROMPT_INVALID","PROMPT_TOO_LONG","DESIGN_EXECUTION_INVALID","REFERENCE_REQUIRED_MISSING","REFERENCE_PATH_INVALID","HISTORY_REQUIRED_MISSING","DESIGN_PATH_CONFLICT","PLAN_REFERENCE_MISMATCH","PLAN_ENUM_INVALID","CONTENT_INCOMPLETE"]);
function diagnostic(error) {
  return { reason:REASONS.has(error?.reason)?error.reason:"CONTRACT_REJECTED",
    field:typeof error?.field==="string" && /^(?:arguments|prompt|source_indexes|structured\.(?:design_brief|style_reference|image_references|image_plan)|structured\.text(?:\[\d{1,3}\])?(?:\.text)?)$/.test(error.field)?error.field:"",
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
    (info.reason==='PLAN_ENUM_INVALID'?'image_plan必须严格使用schema枚举：intent只能campaign/product_reference/redesign/local_edit/visual（不能写poster）；typography只能native/typeset；visual_style只能commercial_launch/photographic/illustrated/editorial/minimal。完整配色、摄影、构图和用户审美要求保留在原prompt与design_brief，枚举只是执行类别，不能把自定义风格长句当枚举，也不能因此把所有图改成同一种风格。保留原文案和素材，不增加新事实。':'')+
    (info.reason==="PROMPT_TOO_LONG"?"视觉prompt超出已安装接口1500字符限制，精简为1200字符内的视觉指令（中文约300字），不能截断或删掉用户必要文案；完整可见原文仍保存在structured.text，素材编号保持原样。":"")+
    (info.reason==="DESIGN_EXECUTION_INVALID"?"design_brief.visual_map中每个structured.text的key必须恰好出现一次，不能省略或新增key。form只用schema允许的表达形式，expression描述如何实际画出这些信息。density_source标明本轮用户/context/default；只有默认dense且多于3项原文时至少用两种不同表达形式，用户明确极简不受此限制。保留完整原文和原素材编号。":"")+
    (info.reason==="DESIGN_PATH_CONFLICT"?"设计元数据只能保存在structured.design_brief与structured.style_reference，不要在工具顶层双写不同版本；按当前用户要求合并成唯一版本，保留完整文案和原素材编号，不沿用已否决的风格。":"")+
    (info.reason==="REFERENCE_REQUIRED_MISSING"?"用户明确要求使用的当前附件原件没有选齐。重新核对用户给的图片身份和原始附件编号，source=attached并在source_indexes选择必要原件，reference_roles按选入顺序逐项对应。不要换成网上素材、历史成品或只在prompt描述Logo；原件不能因排版占位而省掉。":"")+
    (info.reason==="HISTORY_REQUIRED_MISSING"?"用户明确要求的历史原件漏选。以下编号均经账号归属和本轮检索验证，必须选齐："+JSON.stringify((error.requiredReferenceIds||[]).filter(id=>typeof id==='string'&&/^[A-F0-9-]{36}$/.test(id)).slice(0,4))+"。没有本轮附件时用source=none、structured.image_references={version:1,mode:replace,items:[{kind:library,id:编号,role:历史原图N}]}，不要把历史预览当当前附件，不要重画或只描述原件。保持用户要求的完整解释与大约字数，不把千字资料压成短口号。":"")+
    (info.reason==="REFERENCE_PATH_INVALID"?"image_references不能放工具顶层，旧包会忽略它。仅使用历史素材、没有当前底图时，用原有顶层library_refs选择已发放的历史图片ID，不用append。只有当前底图加历史素材混用时，才用source选择当前底图，把追加契约放structured.image_references，不能顶层与嵌套双写；不得更换或编造素材ID。":"")+
    (info.reason==='PLAN_REFERENCE_MISMATCH'?'image_plan.reference_count必须等于工具最终实际选入的素材数量。protected_references.index对应这个选入顺序，不是历史预览原始编号；不能用一个Logo占位来冒充3张图。核对每个图片ID的原件身份，不猜图、不改其作用。':'')+
    (info.reason==='CONTENT_INCOMPLETE'?'原稿没有达到用户已要求的完整篇幅。回看原始用户对能力、场景差异、分工和沟通步骤的解释，完整转成自然说明；不要只列名词或短标签。保持所有确认事实和素材，按原文明确字数补足用途解释，不编承诺、不重复凑字。':'')+
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
// A planning error in one image call must not remove the source order or roles of a sibling call.
const referenceErrors = new Set(["IMAGE_REFERENCE_CONFLICT", "IMAGE_REFERENCE_NOT_ISSUED", "TOOL_CONTRACT_INVALID"]);
function recoverImageReferences(calls, cause, {required, finalize}) {
  const codeOf = error => error?.code || error?.message;
  const missing = code => Object.assign(Error("TOOL_ARGUMENTS_INVALID"), {
    code: "TOOL_ARGUMENTS_INVALID", field: "source_indexes",
    reason: code === "IMAGE_REFERENCE_NOT_ISSUED" ? "HISTORY_REQUIRED_MISSING" : "REFERENCE_REQUIRED_MISSING"
  });
  if (!referenceErrors.has(codeOf(cause))) throw cause;
  if (required || !Array.isArray(calls)) throw missing(codeOf(cause));

  let recovered = false;
  const result = calls.flatMap(call => {
    try { return finalize([call]); }
    catch (error) {
      const code = codeOf(error);
      if (!referenceErrors.has(code)) throw error;
      if (!["image_generate","image_edit","image_series"].includes(call?.function?.name)) throw error;
      let args;
      try { args = JSON.parse(call.function.arguments); } catch { throw missing(code); }
      if (!args || (!args.library_refs && !args.structured?.image_references) || ["both","last"].includes(args.source)) throw missing(code);
      delete args.library_refs;
      if (args.structured) delete args.structured.image_references;
      if (!args.source_indexes && !args.source_index) delete args.reference_roles;
      const repaired = {...call, function: {...call.function, arguments: JSON.stringify(args)}};
      recovered = true;
      return finalize([repaired]);
    }
  });
  if (!recovered) throw missing(codeOf(cause));
  return result;
}
module.exports={diagnostic,repairImageCompletion,recoverImageReferences};
