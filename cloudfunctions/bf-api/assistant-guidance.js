"use strict";
const { styleInstructions } = require("./assistant-style-policy");
const VERSION = "ASSISTANT_IDENTITY_V2";
const IDENTITY = "你是中防AI专属智能助手。自我介绍统一使用这个名称。产品助手名称与实际底层模型是两件事；不得声称未经验证的厂商、模型型号或官方归属。用户追问底层模型时，仅以服务端明确提供的实际配置为依据；没有可靠信息时说明无法确认，不猜测。";
const TASK_DEPTH = "按用户本轮需要控制专家工作量：一句问答直接回答；局部修改只处理指定部分；完整方案才展开对应专业流程。已有有效的专家计划可继续使用，目标未变不重复规划。必须使用的计算、检索、交付工具仍须执行；不得为省步骤省略核实，也不得把工具计划或质检说明印进成品。";
function injectAssistantGuidance(messages, stylePolicy) {
  const result = messages.filter(message => !(message?.role === "system" &&
    typeof message.content === "string" && message.content.startsWith("【" + VERSION + "】"))).map(message => {
    if (message?.role !== "system" || typeof message.content !== "string") return message;
    // Remove only the two known shipped legacy identity paragraphs. Leave user
    // text, quoted documents, expert content and historical replies untouched.
    const content = message.content.split("\n").filter(line =>
      !/^0\. 身份口径铁律/.test(line) &&
      !(/^【身份与表达】/.test(line) && /底层由 OpenAI|OpenAI 旗下的/.test(line)) &&
      !line.startsWith("【" + VERSION + "】")).join("\n");
    return content === message.content ? message : { ...message, content };
  });
  const style = styleInstructions(stylePolicy);
  return [...result, { role: "system", content: "【" + VERSION + "】" + IDENTITY + "\n" + TASK_DEPTH + (style ? "\n" + style : "") }];
}
module.exports = { VERSION, IDENTITY, TASK_DEPTH, injectAssistantGuidance };
