"use strict";
// Reinforce typed copy and optional design metadata supported by shipped clients.
const textItem={type:"object",properties:{key:{type:"string"},role:{type:"string",enum:["title","subtitle","body","label","contact","footer"]},text:{type:"string"}},required:["key","role","text"]};
const designPlan={type:"object",description:"可执行构图元数据，可选；引用已有文案key，不自行编坐标。",properties:{
 version:{type:"integer",enum:[1]},
 style_id:{type:"string",enum:["data-editorial","organic-craft","hyperreal-product"]},
 layout_id:{type:"string",enum:["timeline-sequence","split-vertical","modular-grid","product-shelf","editorial-column","triptych"]},
 blocks:{type:"array",maxItems:40,items:{type:"object",properties:{text_keys:{type:"array",items:{type:"string"}},kind:{type:"string",enum:["body","metrics","route","timeline","services","checklist"]}},required:["text_keys","kind"]}}
}};
const printStyle={type:"object",description:"可选的准确排字配色，严格遵从用户风格；不改变已有composition字符串。",properties:{palette:{type:"object",properties:{background:{type:"string"},ink:{type:"string"},accent:{type:"string"}},required:["background","ink","accent"]}}};
function withImageToolSchema(tools,{commercial=false,workflow=false,nativeCommercial=false,posterPlanner=false}={}){
 if(!Array.isArray(tools))return tools;
 return tools.map(tool=>{
  const fn=tool?.function,properties=fn?.parameters?.properties;
  if(!["image_generate","image_edit"].includes(fn?.name)||!properties?.structured)return tool;
  const structured=properties.structured;
   const designBrief=commercial&&fn.name==="image_generate"&&!workflow&&!nativeCommercial?{
   artwork_prompt:{type:"string",description:"独立无字视觉素材简报：相关物理主体、人物、环境、材质、光线与风格，不包含整张海报布局、正文、数字或Logo字样。"},
   design_brief:{type:"object",description:"内部设计简报，非画面正文；将必要上下文带入任务。",properties:{
    purpose:{type:"string",enum:["action_guide","advertisement","product_explainer","brand_identity","illustration","other"]},audience:{type:"string"},goal:{type:"string"},reader_questions:{type:"array",maxItems:12,items:{type:"string"}},visual_approach:{type:"string"},information_density:{type:"string",enum:["sparse","balanced","dense"]}
   },required:["purpose","audience","goal","reader_questions","visual_approach","information_density"]}
  }:{};
  const reinforced={...structured,type:"object",description:"准确文字及排版元数据，text为逐项数组，无文字填[]；不要用自定义字段替代text。",
   required:[...new Set([...(structured.required||[]),"text",...(posterPlanner?[]:Object.keys(designBrief))])],
   properties:{...structured.properties,...designBrief,...(commercial&&!posterPlanner?{design_plan:designPlan,print_style:printStyle}:{}),text:{type:"array",description:"画面定稿全文，不漏用户要求的信息。区分已确认事实与明确要求印刷的原文：背景解释、分类纠错、绘图指令不自动成为正文；先据资料写成自然通顺的商业文案，再逐项定稿。用户明确要求原文上图才逐字照录。",items:textItem}}
  };
   if(nativeCommercial){delete reinforced.properties.design_plan;delete reinforced.properties.print_style;
    if(fn.name==="image_generate"){
     reinforced.properties.design_brief={type:"object",additionalProperties:false,description:"本轮可执行设计简报。未指定时默认内容充实、图文表达多样；明确极简/短文案等要求优先。按资料选择表达形式，不固定三栏、巨幅截图或某种色板。",properties:{purpose:{type:"string",enum:["action_guide","advertisement","product_explainer","brand_identity","illustration","other"]},audience:{type:"string",maxLength:200},goal:{type:"string",maxLength:400},visual_approach:{type:"string",maxLength:400},information_density:{type:"string",enum:["dense","balanced","sparse"]},density_source:{type:"string",enum:["current_user","context","default"]},visual_map:{type:"array",maxItems:16,items:{type:"object",additionalProperties:false,properties:{form:{type:"string",enum:require("./shared/image-design-brief").FORMS},text_keys:{type:"array",items:{type:"string"}},expression:{type:"string",maxLength:120}},required:["form","text_keys","expression"]}}},required:["purpose","audience","goal","visual_approach","information_density","density_source","visual_map"]};
     reinforced.required=[...new Set([...reinforced.required,"design_brief"])];
    }
    reinforced.properties.style_reference={type:"object",additionalProperties:false,description:"仅在用户提供参考图时填写。最新风格优先；visual_language分析真实视觉语言，information_structure只借信息组织不沿用旧颜色/字体/光效。reference_roles须有且仅有一张风格参考，产品原件角色不变。",properties:{scope:{type:"string",enum:["visual_language","information_structure"]},palette:{type:"array",minItems:2,maxItems:5,items:{type:"string",pattern:"^#[0-9A-Fa-f]{6}$"}},typography:{type:"string",maxLength:160},graphic_language:{type:"string",maxLength:160},image_integration:{type:"string",maxLength:160},density:{type:"string",maxLength:160}},required:["scope","density"]};}
   if(workflow){
    const w=require("./shared/image-workflow");
    delete reinforced.properties.design_plan;delete reinforced.properties.print_style;
    if(fn.name==="image_generate")reinforced.required=[...new Set([...reinforced.required,"image_plan"])];
    reinforced.properties.artwork_prompt={type:"string",description:"可选无字视觉层描述：只写材质、光线、真实空间与风格，不含整幅版式、UI、Logo、正文、数据或占位框；真实产品素材在服务器保真合成。"};
    reinforced.properties.image_plan={type:"object",additionalProperties:false,properties:{version:{type:"integer",enum:[2]},intent:{type:"string",enum:w.INTENTS},typography:{type:"string",enum:["native","typeset"]},visual_style:{type:"string",enum:w.STYLES},layout:{type:"string",enum:w.LAYOUTS,description:"准确产品海报的几何布局，与视觉配色独立选择；product_launch产品发布，product_spread编辑展开，product_stage主视觉舞台。"},reference_count:{type:"integer",minimum:0,maximum:6},protected_references:{type:"array",maxItems:6,items:{type:"object",additionalProperties:false,properties:{index:{type:"integer",minimum:1,maximum:6},role:{type:"string",enum:["ui","logo","product","person"]},crop:{type:"array",description:"只在素材来自另一张海报或照片时填写：原图中确切素材范围[x,y,width,height]，归一化0至1；不凭空猜范围。",minItems:4,maxItems:4,items:{type:"number",minimum:0,maximum:1}},anchor:{type:"string",enum:["auto","top_left","top_right","bottom_left","bottom_right"],description:"用户指定Logo位置；仍须避开现有文字与主体。"}},required:["index","role"]}}},required:["version","intent","typography","visual_style","reference_count","protected_references"]};
   }
   if(workflow&&nativeCommercial){
    delete reinforced.properties.artwork_prompt;
    if(reinforced.properties.image_plan?.properties?.typography)reinforced.properties.image_plan.properties.typography={type:'string',enum:['native']};
   }
   return {...tool,function:{...fn,parameters:{...fn.parameters,properties:{...properties,...(nativeCommercial&&properties.prompt?{prompt:{...properties.prompt,maxLength:1500,description:fn.name==="image_generate"?"简明写当前创作目标、受众、素材用途和用户明确要求的风格/约束；用户没指定的构图由制图模型整体设计，不主动锁死分栏、截图占比、大角度斜屏、微字标注或特效。约中文300字以内，硬上限1500字符；完整可见原文保留structured.text，不在prompt重复全文。":properties.prompt.description+" 硬上限1500字符；完整原文保留structured.text。"}}:{}),structured:reinforced}}}};
 });
}
module.exports={withImageToolSchema};
