"use strict";

const VERSION = "commercial-image-guidance-v1";
const IMAGE_TOOLS = new Set(["image_generate", "image_edit", "image_series"]);
const COMMERCIAL_BRIEF = [
  `[${VERSION}] 仅用于本轮商业图片任务。`,
  "先理解客户希望图片用于什么场合、给谁看、希望对方记住什么。写给图像工具的 prompt 要成为可执行的视觉简报：明确画面主体、真实使用场景、主体与环境的关系、材质/光线/景深、构图和视觉层级；让企业海报有足够的业务信息与可辨认的细节，而非纯背景加几个字。",
  "根据已有资料安排主标题、核心价值和支撑信息的层级；只把用户提供或已核实的准确文字放 structured.text，联系方式、数字、资质、承诺不能自行编造。能体现业务的产品、设施、人员或工作过程优先于无关的装饰图标。",
  "这不是固定模板。用户明确要极简、留白、草稿、局部编辑或保持原画面时，尊重其要求；编辑任务只改指定部分，保留其余内容。不要把数据来源、核实说明或作图指令画进作品。",
].join("\n");

function injectCommercialImageGuidance(messages, tools, userText) {
  if (!Array.isArray(messages) || !Array.isArray(tools) || typeof userText !== "string") return messages;
  const hasImageTool = tools.some(tool => IMAGE_TOOLS.has(tool?.function?.name));
  const businessImage = /(?:海报|展会|展板|宣传图|主视觉|产品图|画册|商用图片|商业图片|广告图)/.test(userText);
  if (!hasImageTool || !businessImage || messages.some(m => m?.role === "system" && typeof m.content === "string" && m.content.includes(VERSION))) return messages;
  return [...messages, { role: "system", content: COMMERCIAL_BRIEF }];
}

module.exports = { VERSION, COMMERCIAL_BRIEF, injectCommercialImageGuidance };
