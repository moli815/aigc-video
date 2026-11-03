"use strict";

const VERSION = "commercial-image-guidance-v4";
const COMMERCIAL_TASK = /(?:海报|展会|展板|宣传图|主视觉|产品图|画册|商用图片|商业图片|广告图)/;
const IMAGE_TOOLS = new Set(["image_generate", "image_edit", "image_series"]);
const COMMERCIAL_BRIEF = [
  `[${VERSION}] 仅用于本轮商业图片任务。`,
  "先理解客户希望图片用于什么场合、给谁看、希望对方记住什么。写给图像工具的 prompt 要成为可执行的视觉简报：明确画面主体、真实使用场景、主体与环境的关系、材质/光线/景深、构图和视觉层级；让企业海报有足够的业务信息与可辨认的细节，而非纯背景加几个字。",
  "根据已有资料安排主标题、核心价值和支撑信息的层级；只把用户提供或已核实的准确文字放 structured.text，联系方式、数字、资质、承诺不能自行编造。能体现业务的产品、设施、人员或工作过程优先于无关的装饰图标。",
  "这不是固定模板。用户明确要极简、留白、草稿、局部编辑或保持原画面时，尊重其要求；编辑任务只改指定部分，保留其余内容。不要把数据来源、核实说明或作图指令画进作品。",
  "用户选方案或要求更真实、丰富、完整时，延续最近明确的设计任务，补足与业务相关的场景和信息层级，而非仅堆装饰。简约不等于删掉有用信息；不要默认每张都用蓝色科技风，也不要擅自把用户原文缩成口号。",
  "先识别交付目的再设计：参展攻略/行业走访/路线/决策指南，应交付能指导行动的信息图；现场预约/产品推广才是营销广告。不能把行动指南擅自改成泛泛的产品预约海报。若用户同时要宣传与攻略，明确主次，保留两部分的实用内容。",
  "对信息图，先在内部整理真实可用信息与读者决策顺序，再写图像简报：目标与适用人群、优先级/选择依据、具体行动或流程、对照/筛选/提问清单、下一步。只采用适合本任务的模块，用户只要三项就完整表达三项，不机械凑数量。每块有具体内容而非重复标题；未提供的馆号、路线图、日期、电话号码、资质、效果数字不能编造，可给不依赖这些事实的行动建议。",
  "版式按内容量设计而非把短句塞进发光节点：长竖幅可用清晰分区、编辑式卡片、对照矩阵、时间轴或图文穿插；主标题/栏目标题/正文有明确层级，相关图示服务信息。避免大块无意义空白、从下到上的倒序步骤、相同文案在主图和底栏重复、装饰器材图抢占信息区。用户要求极简时遵从，不强行高密度。",
  "structured.text与画面简报使用同一份定稿文案，保留用户原文中的电话/公司/产品名称；不要在prompt里写一套、text里再缩成另一套。交付前自检：用户每项需求都有落点、步骤不重不漏、准确字段逐字一致、图文对应；标题不能代替内容。不要把这份自检或构图指令写成可见文字。",
  'structured.text必须是数组，例如[{"key":"main_title","role":"title","text":"用户的准确标题"},{"key":"actions","role":"body","text":"第一步的具体动作\\n第二步的具体动作"},{"key":"phone","role":"contact","text":"用户提供的准确电话"}]。role只用title/subtitle/body/label/contact/footer，禁止输出字段字典。一个栏目内的相关正文可合为一个body的多行文字，不要把每个短句都拆成极小文本框。',
  "需要程序准确排字时，同时给出可执行的structured.layout：preset为editorial/centered/split，fontStyle为sans/serif/rounded；blocks逐项对应text的唯一key，不能缺项或重复。每块用x/y/width/height表示0到1的归一化区域，可带align(left/center/right)、color(#RRGGBB)、fontScale(0.75到1.5)、backdrop(boolean)。所有边界在0.02到0.98以内，width至少0.04、height至少0.025，块不相交；根据全文长度留足正文空间及标题区，不给所有条目同一坐标。背景构图与这些区域一致。只提供视觉prompt而不提供准确文案和布局，旧客户端只能退回默认排版。",
].join("\n");

function isCommercialTask(messages, userText) {
  if (COMMERCIAL_TASK.test(userText)) return true;
  const followup = /^(?:[1-9一二三四五六]|第?[一二三四五六1-9]个|继续|就这个|按这个|用这个|选这个|好|好的|可以|开始|生成|出图|再来|换个|改成|改为|更真实|再真实|丰富|再丰富|保持|只改|太简单|信息太少|不够真实|按刚才|重新|把|加上)/;
  if (userText.length > 140 || !followup.test(userText.trim())) return false;
  const userMessages = messages.filter(m => m?.role === "user").map(m =>
    typeof m.content === "string" ? m.content : (m.content || []).filter(p => p.type === "text").map(p => p.text || "").join("\n"));
  if (userMessages.at(-1) === userText) userMessages.pop();
  for (const previous of userMessages.slice(-3).reverse()) {
    if (COMMERCIAL_TASK.test(previous)) return true;
    if (!followup.test(previous.trim()) || /(?:天气|合同|发票|代码|法律|税|邮件)/.test(previous)) return false;
  }
  return false;
}
function injectCommercialImageGuidance(messages, tools, userText) {
  if (!Array.isArray(messages) || !Array.isArray(tools) || typeof userText !== "string") return messages;
  const hasImageTool = tools.some(tool => IMAGE_TOOLS.has(tool?.function?.name));
  const businessImage = isCommercialTask(messages, userText);
  if (!hasImageTool || !businessImage || messages.some(m => m?.role === "system" && typeof m.content === "string" && m.content.includes(VERSION))) return messages;
  return [...messages, { role: "system", content: COMMERCIAL_BRIEF }];
}

module.exports = { VERSION, COMMERCIAL_BRIEF, isCommercialTask, injectCommercialImageGuidance };
