"use strict";
const PURPOSES=new Set(["action_guide","advertisement","product_explainer","brand_identity","illustration","other"]);
function compileDesignBrief(brief,{taskKind="",textMode=""}={}) {
  if(!brief||typeof brief!=="object"||!["","generate","reference"].includes(String(taskKind)))return "";
  if(!PURPOSES.has(brief.purpose))return "";
  const fields={purpose:brief.purpose};
  for(const [key,limit]of [["audience",200],["goal",400],["visual_approach",400]]) {
    if(typeof brief[key]==="string"&&brief[key].length<=limit)fields[key]=brief[key];
  }
  if(Array.isArray(brief.reader_questions))fields.reader_questions=brief.reader_questions.filter(s=>typeof s==="string"&&s.length<=160).slice(0,12);
  if(["sparse","balanced","dense"].includes(brief.information_density))fields.information_density=brief.information_density;
  if(!fields.goal)return "";
  return "【内部设计执行简报，不是可见文案】"+JSON.stringify(fields)+"\n"+
    (textMode==="overlay"?"准确文字由后续排字完成，当前只生成与规划相配的无字底图。":"可见文字只使用本请求的定稿文案，不把简报字段或作图指令画进作品。")+
    "简报不授权改动用户明确指定的风格、品牌或内容。";
}
// Keep semantic copy roles at the provider boundary. A brand label must not
// silently replace a product title when all copy is flattened into plain lines.
function compileNativeCopy(items,{taskKind="",textMode=""}={}) {
  if(textMode==="overlay"||!["","generate","reference"].includes(String(taskKind))||!Array.isArray(items)||!items.length)return "";
  const roles=new Set(["title","subtitle","body","label","contact","footer"]);
  if(!items.every(t=>t&&roles.has(t.role)&&typeof t.text==="string"&&t.text.trim()))return "";
  const copy=items.map(t=>({role:t.role,text:t.text}));
  return "【画面定稿与文字层级】以下是完整可见文案，按role决定主次，不是备选清单。title是主标题；品牌label不能替代或挤掉主标题。body逐项保留，不能只画栏目名或只取前两句。禁止增加元数据字段名、作图指令或解释；不改变用户指定的版式风格。\n"+JSON.stringify(copy);
}
module.exports={compileDesignBrief,compileNativeCopy};
