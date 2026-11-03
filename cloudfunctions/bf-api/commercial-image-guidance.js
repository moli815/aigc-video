"use strict";

const VERSION = "commercial-image-guidance-v2";
const COMMERCIAL_TASK = /(?:海报|展会|展板|宣传图|主视觉|产品图|画册|商用图片|商业图片|广告图)/;
const IMAGE_TOOLS = new Set(["image_generate", "image_edit", "image_series"]);
const COMMERCIAL_BRIEF = [
  `[${VERSION}] 仅用于本轮商业图片任务。`,
  "先理解客户希望图片用于什么场合、给谁看、希望对方记住什么。写给图像工具的 prompt 要成为可执行的视觉简报：明确画面主体、真实使用场景、主体与环境的关系、材质/光线/景深、构图和视觉层级；让企业海报有足够的业务信息与可辨认的细节，而非纯背景加几个字。",
  "根据已有资料安排主标题、核心价值和支撑信息的层级；只把用户提供或已核实的准确文字放 structured.text，联系方式、数字、资质、承诺不能自行编造。能体现业务的产品、设施、人员或工作过程优先于无关的装饰图标。",
  "这不是固定模板。用户明确要极简、留白、草稿、局部编辑或保持原画面时，尊重其要求；编辑任务只改指定部分，保留其余内容。不要把数据来源、核实说明或作图指令画进作品。",
  "用户选方案或要求更真实、丰富、完整时，延续最近明确的设计任务，补足与业务相关的场景和信息层级，而非仅堆装饰。简约不等于删掉有用信息；不要默认每张都用蓝色科技风，也不要擅自把用户原文缩成口号。",
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
