"use strict";
const library=require("./design/library.json");
const VERSION="commercial-design-plan-v1";
const KINDS=new Set(["body","metrics","route","timeline","services","checklist"]);
function textOf(s){return s.items.map(t=>t.text).join("\n");}
function kindOf(section){
 const label=section.items.filter(t=>t.role!=="body").map(t=>t.text).join(" ");
 const body=section.items.filter(t=>t.role==="body").map(t=>t.text).join("\n");
 if(/路线|走访优先|优先级.*理由/.test(label))return "route";
 if(/三天行动|六周|每周|交付步骤|合作流程|六步/.test(label)&&body.split("\n").filter(Boolean).length>=3)return "timeline";
 if(/目标|亮点|指标/.test(label)&&body.split("\n").filter(t=>/\d/.test(t)).length>=2&&body.length<650)return "metrics";
 if(/验收|核验|必问|清单|边界/.test(label))return "checklist";
 if(/服务|诊断|梳理|培训|复盘|落地/.test(label))return "services";
 return "body";
}
function planOf({structured,prompt,width,height,content}){
 const raw=structured?.design_plan,valid=raw&&raw.version===1;
 const request=valid?raw:{};
 const purpose=structured?.design_brief?.purpose||"";
 const labels=content.sections.map(textOf).join("\n");
 const hints=[structured?.design_brief?.visual_approach,prompt].filter(Boolean).join(" ").split(/[。；;\n]/).filter(s=>!/(不要|避免|禁止|不使用|不用)/.test(s)).join(" ");
 let styleId=Object.hasOwn(library.styles,request.style_id)?request.style_id:/暖|手绘|插画|森林绿|木刻|纸感/.test(hints)?"organic-craft":purpose==="advertisement"?"hyperreal-product":"data-editorial";
 let layoutId=content.matrix?"product-shelf":width/height>=2.4?"triptych":Object.hasOwn(library.layouts,request.layout_id)&&request.layout_id!=="product-shelf"?request.layout_id:
   /走访|参展|攻略|三天行动|六周/.test(labels)?"timeline-sequence":/01|经营诊断|六项服务|六个模块/.test(labels)?"modular-grid":purpose==="advertisement"||purpose==="product_explainer"?"split-vertical":"editorial-column";
 if(layoutId==="triptych"&&width/height<2.4)layoutId="editorial-column";
 const allKeys=new Set(structured.text.map(t=>t.key));
 const annotations=Array.isArray(request.blocks)?request.blocks.slice(0,40):[];
 const sections=content.sections.map((section,index)=>{
  const keys=section.items.map(t=>t.key);
  const matched=annotations.filter(a=>KINDS.has(a?.kind)&&Array.isArray(a.text_keys)&&a.text_keys.length===keys.length&&new Set(a.text_keys).size===keys.length&&a.text_keys.every(k=>allKeys.has(k)&&keys.includes(k)));
  return {...section,index,kind:matched.length===1?matched[0].kind:kindOf(section)};
 });
 const header=[...content.header];
 // A brand line preceding the first copy block belongs with the hero, not in
 // an empty standalone body column. Move it without changing or duplicating it.
 if(sections[0]?.items.every(t=>t.role==="label")&&sections[0].items.length===1){header.push(...sections.shift().items);}
 return {version:VERSION,styleId,layoutId,header,footer:content.footer,sections,matrix:content.matrix,
  artwork:{aspectRatio:library.layouts[layoutId].artworkAspect,placement:library.layouts[layoutId].hero},
  reason:valid?"validated_design_metadata":"compatible_content_selection"};
}
function designEnabled(policy,owner){return policy?.designEngine==="poster"&&(!Array.isArray(policy.designAccountIds)||policy.designAccountIds.includes(owner));}
module.exports={VERSION,library,planOf,kindOf,designEnabled};
