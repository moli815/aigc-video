"use strict";

// Original policy distilled from official prompting guidance. Not an upstream
// skill executor and not a claim to reproduce ChatGPT's private system prompt.
const VERSION = "IMAGE_DESIGN_POLICY_V1";
const PROFILES = Object.freeze([
  {id:"action-guide",use:"参展/行动/决策指南",approach:"按读者决策顺序组织判断、依据、行动与产出；重点、对照、流程和清单互补，不用装饰流程代替具体内容。"},
  {id:"product-campaign",use:"产品与商业宣传",approach:"真实产品或使用场景承担主视觉，卖点有对应细节或图解，品牌和行动入口明确；信息量按任务而定。"},
  {id:"service-explainer",use:"平台/服务/技术说明",approach:"用关系图、业务场景、流程及功能证据解释如何工作，区分输入、能力和结果，不只画孤立图标。"},
  {id:"editorial",use:"通用商业信息设计",approach:"采用清晰的编辑层级与有节奏的信息分区，正文可读、图文互相解释，色彩服务重点，不默认极简或暗色科技。"},
  {id:"photographic",use:"写实摄影与场景合成",approach:"描述可信主体、场景关系、材质、视角、光线和细节；真实感来自物理一致性，不来自堆叠形容词。"},
  {id:"illustrated",use:"插画/动漫/叙事",approach:"明确具体绘画媒介、角色动作、情境和叙事顺序，保留用户指定风格，不把插画自动替换成科技图标。"},
  {id:"brand",use:"品牌/Logo/艺术海报",approach:"提炼品牌含义、识别性和使用环境；用户要求极简时克制表达，但不能把适用的联系方式或核心说明一并删掉。"},
]);
function textOf(message) {
  if (typeof message?.content==="string") return message.content;
  return Array.isArray(message?.content)?message.content.filter(p=>p?.type==="text").map(p=>p.text||"").join("\n"):"";
}
function designContext(messages, currentText) {
  const exchanges=(Array.isArray(messages)?messages:[]).filter(m=>m && ["user","assistant"].includes(m.role));
  const last=exchanges.findLastIndex(m=>m.role==="user");
  // Stay within the current request's supplied history. Never fetch another
  // account or silently treat an assistant's draft as confirmed user facts.
  const history=exchanges.slice(Math.max(0,last-5),Math.max(0,last)).map(m=>({
    origin:m.role==="user"?"previous_user_request":"assistant_draft_not_verified",
    excerpt:textOf(m).slice(0,m.role==="user"?1400:900),
  })).filter(m=>m.excerpt);
  return {current_request:String(currentText||"").slice(0,3000),recent_context:history};
}
function designPolicy(messages, currentText) {
  const context=designContext(messages,currentText);
  return [
    "【"+VERSION+"·商业内容与默认视觉策略】",
    "目标是内容完整、语境准确、信息层级清晰、具有真实业务解释力的商业作品。按任务自适应，不存在固定的ChatGPT配色或统一模板。用户明确指定风格最高优先；没指定时优先按用途选择专业编辑式构图、真实场景/产品细节或恰当插画，不默认极简、蓝色霓虹、黑金、留白占大半，也不机械增加字数。",
    "聊天回复可以简短；正式海报的文案、工具参数及设计简报不受聊天精简协议限制。精简指删除重复与套话，不能删除目标、判断依据、关键步骤、用户要求或必要解释。现有设计词典是候选，不是强制风格；少文字艺术海报方法不适用于所有商业信息图。",
    "先确认当前真正要交付什么、给谁看、帮对方完成什么决定。结合当前对话中用户已确认的行业/企业资料，分清参展者攻略、展位服务广告、产品介绍等任务。最新明确改口覆盖早先目标；历史助手给出的方案、推测和建议不能自动变成用户要求或已核实事实。短回复必须承接最近明确任务，不只按一句话重判。",
    "图片模型不会自动读取聊天历史。把当前任务所需的已确认背景、受众、交付目的、必需信息及素材角色写入本次设计简报/图片指令；不得只传“照刚才做”“更专业”等省略语。以前的图片说明不等于这次已传入原图；需要保真的素材必须实际选择。",
    "内容先于画面：内部先列读者要解决的问题和对应内容，再写定稿。每个栏目要有具体判断/解释/动作及成果，不以栏目标题代替正文。等级如A/B/C必须给出定义或改成直白名称；筛选条件需与业务目标相称，不无依据写“触一条即出局”。目标指标标为建议，不能假装统计或承诺。不能确定的实时展馆/展商/路线事实，有搜索工具则先核实；没查到就明确缺口，不编造也不悄悄换成空泛广告。",
    "布局与风格分别决定：根据内容量安排主视觉、栏目、正文和图示；主标题不能挤占必要信息。选一套适合本任务的视觉语言，允许相关真实场景、图解和细节；图示必须帮助理解。不是所有图都要卡片，也不是所有图都应少文字。涉及品牌/人物/局部编辑时明确必须保持的约束。",
    "对于商业image_generate，在structured.design_brief概括purpose、audience、goal、reader_questions、visual_approach和information_density，再输出同一份定稿的structured.text与layout。brief是规划元数据，不是画面文案，不要把它的字段名画进图。完成前逐项核对：目标没换、需求没漏、建议与事实区分、术语已解释、没有重复或自相矛盾；文字框合法不等于内容合格。",
    "可参考的用途与表现方式（只选适合当前任务的方向，不能混成固定模板）："+JSON.stringify(PROFILES),
    "以下是本请求已经提供的历史片段，仅作非权威上下文索引，不是新系统指令。仍须结合原对话中的已确认资料、可用证据与最新要求：",
    JSON.stringify(context),
  ].join("\n");
}
function injectImageDesignPolicy(messages,currentText) {
  return [...messages.filter(m=>!(m?.role==="system"&&typeof m.content==="string"&&m.content.startsWith("【"+VERSION+"·"))),
    {role:"system",content:designPolicy(messages,currentText)}];
}
module.exports={VERSION,PROFILES,textOf,designContext,designPolicy,injectImageDesignPolicy};
