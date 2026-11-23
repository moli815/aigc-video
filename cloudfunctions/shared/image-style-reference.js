"use strict";
// A small executable style contract, independent of copy and layout templates.
function compileStyleReference(raw,roles){
 if(!raw||!Array.isArray(roles))return "";
 const indices=roles.map((s,i)=>/风格|样式|style/i.test(String(s))?i:-1).filter(i=>i>=0);
 if(indices.length!==1)return "";
 const scope=raw.scope===undefined?"visual_language":raw.scope;
 if(!["visual_language","information_structure"].includes(scope))return "";
 // A reference can demonstrate information organisation without prescribing
 // colours or rendering style. Do not leak its old palette into a restyle.
 if(scope==="information_structure"){
  const density=raw.density;
  if(typeof density!=="string"||!density.trim()||density.length>160||/[\r\n]/.test(density))return "";
  return "【仅参考信息组织】图"+(indices[0]+1)+"仅提供信息层级、内容组织和阅读节奏；密度参考："+JSON.stringify(density)+"。不沿用这张图的色板、字形、材质、光效或具体版式；整幅作品按本轮用户要求的新风格设计，不能被历史参考和品牌偏好覆盖。不得复制参考里的品牌、日期、指标和功能。此说明不是画面文字。";
 }
 if(!Array.isArray(raw.palette)||raw.palette.length<2||raw.palette.length>5||raw.palette.some(s=>!/^#[0-9a-f]{6}$/i.test(s)))return "";
 const fields={palette:raw.palette};
 for(const key of ["typography","graphic_language","image_integration","density"]){const s=raw[key];if(typeof s!=="string"||!s.trim()||s.length>160||/[\r\n]/.test(s))return "";fields[key]=s;}
 return "【已绑定的视觉参考】图"+(indices[0]+1)+"提供整幅作品的视觉语言："+JSON.stringify(fields)+"。仅在不违背本轮用户明确要求时采用；当前新风格或禁止项始终优先，历史参考不是固定模板。这些字段是设计属性而非画面文字。产品截图只保留其自身内容，不让截图配色覆盖整幅广告的参考色板；参考广告里的品牌、日期、指标与功能不移植到本客户作品。";
}
module.exports={compileStyleReference};
