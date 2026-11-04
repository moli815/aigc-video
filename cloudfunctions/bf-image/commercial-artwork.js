"use strict";
// The provider gets an artwork brief; the complete poster's copy and layout
// remain with the typography module. This prevents native tables under text.
function artworkPrompt(structured){
 const s=structured||{},explicit=typeof s.artwork_prompt==="string"?s.artwork_prompt.trim().slice(0,2200):"";
 const palette=s.print_style?.palette;
 const colors=palette&&["background","ink","accent"].every(k=>/^#[0-9a-f]{6}$/i.test(palette[k]||""))?"配色："+[palette.background,palette.ink,palette.accent].join("、"):"";
 const fallback="企业业务场景插画：以真实的人、设备与工作环境表达企业协作；横向完整场景，有清晰主体与细节，不以信息表格或界面作为主体。";
 const audience=String(s.design_brief?.audience||"").slice(0,250);
 return "独立的无字商业视觉素材，不是整张海报。业务受众："+audience+"。"+(explicit||fallback)+"\n"+colors+
  "\n实施作战图、经营战报等商业比喻按实际企业工作场景表达，不引入与业务无关的军事器材。仅绘制物理场景、人物、产品或无字插画；所有版式与文字另行排版。不得绘制表格、看板界面、文档页面、文字卡片、标题、数字、字母、伪文字、徽标字样或空白文本框。横向3:1构图，主体完整，商业成品的画面品质。";
}
module.exports={artworkPrompt};
