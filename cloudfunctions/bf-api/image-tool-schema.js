"use strict";
// Reinforce the same typed copy contract already supported by shipped phones.
// Preserve source selection, asset preservation and every unrelated tool field.
function withImageToolSchema(tools, { commercial = false } = {}) {
  if (!Array.isArray(tools)) return tools;
  return tools.map(tool => {
    const fn=tool?.function, properties=fn?.parameters?.properties;
    if (!["image_generate","image_edit"].includes(fn?.name) || !properties?.structured) return tool;
    const structured=properties.structured;
    const designBrief = commercial && fn.name === "image_generate" ? {
      artwork_prompt:{type:"string",description:"独立无字视觉素材简报：与业务相关的具体物理主体、人物、环境、材质、光线及风格；不包含整张海报布局、表格、看板界面、正文、数字或Logo字样。"},
      design_brief:{type:"object",description:"内部设计简报，不是画面正文；将必要上下文带进本次图片任务。",properties:{
        purpose:{type:"string",enum:["action_guide","advertisement","product_explainer","brand_identity","illustration","other"]},
        audience:{type:"string"},goal:{type:"string"},
        reader_questions:{type:"array",maxItems:12,items:{type:"string"}},
        visual_approach:{type:"string"},information_density:{type:"string",enum:["sparse","balanced","dense"]}
      },required:["purpose","audience","goal","reader_questions","visual_approach","information_density"]}
    } : {};
    return {...tool,function:{...fn,parameters:{...fn.parameters,properties:{...properties,structured:{
      ...structured,type:"object",
      description:"准确文字及排版元数据，text为逐项数组，无文字填[]；不要用自定义字段替代text。",
      required:[...new Set([...(structured.required||[]),"text",...Object.keys(designBrief)])],
      properties:{...structured.properties,...designBrief,...(commercial?{print_style:{type:"object",description:"可选的准确排字配色，严格遵从用户风格；不改变已有composition视觉描述字段。",properties:{palette:{type:"object",properties:{background:{type:"string"},ink:{type:"string"},accent:{type:"string"}},required:["background","ink","accent"]}}}}:{}),text:{type:"array",description:"画面定稿全文，不漏项，不把构图指令当文字。",items:{
        type:"object",properties:{key:{type:"string"},role:{type:"string",enum:["title","subtitle","body","label","contact","footer"]},text:{type:"string"}},
        required:["key","role","text"]
      }}}
    }}}}};
  });
}
module.exports={withImageToolSchema};
