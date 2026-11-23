"use strict";
const PURPOSES=new Set(["action_guide","advertisement","product_explainer","brand_identity","illustration","other"]);
const FORMS=["主视觉","关系图","流程图","场景群像","对比","清单","文字","行动入口"];
function visualMapOf(brief,items){
 if(!brief||!Array.isArray(brief.visual_map)||!Array.isArray(items)||brief.visual_map.length>16)return null;
 if(!PURPOSES.has(brief.purpose)||typeof brief.goal!=="string"||!brief.goal.trim()||brief.goal.length>400||typeof brief.visual_approach!=="string"||!brief.visual_approach.trim()||brief.visual_approach.length>400||typeof brief.audience!=="string"||brief.audience.length>200)return null;
 if(!["current_user","context","default"].includes(brief.density_source)||!["dense","balanced","sparse"].includes(brief.information_density))return null;
 const keys=new Set(items.map(t=>t?.key)),used=new Set();if(keys.size!==items.length||items.some(t=>typeof t?.key!=="string"))return null;
 const map=[];for(const e of brief.visual_map){
  if(!e||!FORMS.includes(e.form)||!Array.isArray(e.text_keys)||!e.text_keys.length||e.text_keys.some(k=>!keys.has(k)||used.has(k))||new Set(e.text_keys).size!==e.text_keys.length||typeof e.expression!=="string"||!e.expression.trim()||e.expression.length>120)return null;
  e.text_keys.forEach(k=>used.add(k));map.push({form:e.form,text_keys:e.text_keys,expression:e.expression});
 }
 if(used.size!==keys.size)return null;
 if(brief.information_density==="dense"&&brief.density_source==="default"&&items.length>3&&new Set(map.map(e=>e.form)).size<2)return null;
 return map;
}
function compileDesignBrief(brief,{taskKind="",textMode="",visualExecution=false,items=[]}={}) {
  if(!brief||typeof brief!=="object"||!["","generate","reference"].includes(String(taskKind)))return "";
  if(!PURPOSES.has(brief.purpose))return "";
  const fields={purpose:brief.purpose};
  for(const [key,limit]of [["audience",200],["goal",400],["visual_approach",400]]) {
    if(typeof brief[key]==="string"&&brief[key].length<=limit)fields[key]=brief[key];
  }
  if(Array.isArray(brief.reader_questions))fields.reader_questions=brief.reader_questions.filter(s=>typeof s==="string"&&s.length<=160).slice(0,12);
  if(["sparse","balanced","dense"].includes(brief.information_density))fields.information_density=brief.information_density;
  if(!fields.goal)return "";
  if(visualExecution&&textMode!=="overlay"&&brief.visual_map!==undefined){const map=visualMapOf(brief,items);if(!map)return "";
   return "【本轮设计目标】用途："+fields.purpose+"；受众："+(fields.audience||"")+"；目标："+fields.goal+"。信息量："+fields.information_density+"，以本轮用户要求优先。\n【视觉方向·制作要求，不是画面文字】"+(fields.visual_approach||"")+"。这里决定整幅表现语言，不从真实产品截图的配色或历史广告机械推断；本轮明确风格优先。\n【信息与印刷原文】下面每项的表达形式和说明是制作意图，只印双引号内的原文，每份原文只印一次，不增加额外小字、字段名或事实。由你整体设计构图与图文融合，避免把所有信息退回正文段落。\n"+map.map(e=>e.form+"（"+e.expression+"）："+e.text_keys.map(k=>JSON.stringify(items.find(t=>t.key===k).text)).join("；")).join("\n");
  }
  return "【内部设计执行简报，不是可见文案】"+JSON.stringify(fields)+"\n"+
    (textMode==="overlay"?"准确文字由后续排字完成，当前只生成与规划相配的无字底图。":"可见文字只使用本请求的定稿文案，不把简报字段或作图指令画进作品。")+
    "简报不授权改动用户明确指定的风格、品牌或内容。";
}
// Keep semantic copy roles at the provider boundary. A brand label must not
// silently replace a product title when all copy is flattened into plain lines.
function compileNativeCopy(items,{taskKind="",textMode="",literalLines=false,compact=false}={}) {
  if(textMode==="overlay"||!["","generate","reference"].includes(String(taskKind))||!Array.isArray(items)||!items.length)return "";
  const roles=new Set(["title","subtitle","body","label","contact","footer"]);
  if(!items.every(t=>t&&roles.has(t.role)&&typeof t.text==="string"&&t.text.trim()))return "";
  const copy=items.map(t=>({role:t.role,text:t.text}));
  if(literalLines){
    const label={title:"主标题",subtitle:"副标题",body:"正文",label:"栏目",contact:"联系方式",footer:"页脚"};
    // 5.5 without a visual_map has no consumer for internal key IDs. Keep the
    // full canonical words but avoid teaching the image model to print those IDs.
    if(compact){
      const groups=new Map();items.forEach(t=>{const m=/^(.+?)[_-](\d+)$/.exec(t.key||'');if(!m||t.role!=='body')return;const rows=groups.get(m[1])||[];rows.push(t);groups.set(m[1],rows);});
      const hints=[...groups.values()].filter(rows=>rows.length>=3).map(rows=>{const names=rows.map(t=>/^([^：:\n]{1,18})[：:\n]/.exec(t.text)?.[1]);return names.every(Boolean)?'同组'+rows.length+'项：'+names.join('、'):'';}).filter(Boolean).join('；');
      return '【画面定稿】只把双引号内原文印入画面，行首层级标签不印刷。共'+copy.length+'段；标题、正文、电话逐字保留，不删段、不补字。'+(hints?'覆盖核对（不印刷）：'+hints+'。':'')+'用户未指定字体效果时，正文使用清晰常规字重，复杂汉字不描边、不做发光或纹理字；按内容组织可读层级，空间不足不能把字缩成装饰性小字。\n'+copy.map(t=>label[t.role]+'：'+JSON.stringify(t.text)).join('\n');
    }
    // 同一层级出现 3 项以上时，明确写死条数。实测模型会为了凑成 3×2 网格悄悄删掉两条。
    const byRole=new Map();copy.forEach(t=>byRole.set(t.role,(byRole.get(t.role)||0)+1));
    const countLine=[...byRole].filter(([,n])=>n>=3).map(([r,n])=>label[r]+"共 "+n+" 条").join("、");
    const total=[...copy].reduce((s,t)=>s+[...t.text.replace(/\s+/g,"")].length,0);
    // 品牌名与联系方式在页眉页脚各出现一次是行业惯例；禁止它反而会让模型在别处找补。
    const dupRole=new Set(["contact","footer"]);
    const dupItems=copy.filter(t=>dupRole.has(t.role)||/品牌|公司|logo|商号/i.test(t.text));
    return "【印刷原文】只印刷下面各行双引号内的文字，左侧key与层级标签不是画面文字。key对应visual_map，只是同一份内容的索引，不要重复印刷。"+
      "共 "+copy.length+" 段、合计 "+total+" 字"+(countLine?"（"+countLine+"，条数不得增删）":"")+"。\n"+
      copy.map((t,i)=>(typeof items[i].key==="string"?"[key="+JSON.stringify(items[i].key)+"] ":"")+label[t.role]+"："+JSON.stringify(t.text)).join("\n")+
      "\n"+(dupItems.length?"品牌名与联系方式允许在页眉、页脚各出现一次，其余各段只印一次；":"每段只印一次，不得重复；")+
      "不要给区块起小标题或栏目名，区块直接由内容开始；"+
      "除以上文字外，画面不得出现任何其他文字，包括装饰性小字、伪英文、角标、页码、水印。"+
      "逐字照搬，不改字、不漏字、不多字；括号、间隔号、连字符必须保留。";
  }
  return "【画面定稿与文字层级】以下是完整可见文案，按role决定主次，不是备选清单。title是主标题；品牌label不能替代或挤掉主标题。body逐项保留，不能只画栏目名或只取前两句。禁止增加元数据字段名、作图指令或解释；不改变用户指定的版式风格。\n"+JSON.stringify(copy);
}
function compileNativeReferenceConstraints(roles,image){
 const count=Array.isArray(image)?image.length:image?1:0;
 if(!count||!Array.isArray(roles)||roles.length!==count||roles.some(r=>typeof r!=="string"||!r.trim()))return "";
 const protectedSlots=roles.flatMap((r,i)=>/风格|样式|style/i.test(r)?[]:/logo|品牌原|商标|真实.*(?:平台|界面)|平台.*(?:原件|首页)|实际.*(?:平台|界面)|\bui\b/i.test(r)?[i+1]:[]);
 if(!protectedSlots.length)return "";
 return "【重新设计的范围】重做的是整幅商业作品的构图与视觉风格，不是其中的原始素材内部。图"+protectedSlots.join("、图")+"是已标明的实际产品/品牌原件，应完整采用，允许按构图等比例缩放与合理透视，不换成相似屏幕、图标或品牌，不增改其内部数据和文字。风格参考只借本轮允许的表现手段，不移植其品牌或事实。让原件与场景、图解和印刷文案自然融合；用户明确不改的内容仍须保留。本段是制作约束，不得印在作品里。";
}
module.exports={compileDesignBrief,compileNativeCopy,visualMapOf,FORMS,compileNativeReferenceConstraints};
