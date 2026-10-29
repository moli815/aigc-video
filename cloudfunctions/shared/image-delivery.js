"use strict";
const { requestsQuality, requestsModel } = require("./image-quality-intent");

// The same boundary runs before tool arguments reach existing phones and before
// provider compilation. Never sanitize arbitrary chat/document content.
const IMAGE_TOOLS = new Set(["image_generate", "image_edit", "image_series", "image_decompose", "generate_image"]);
const BOUNDARY_VERSION = "IMAGE_DELIVERY_V2";
const DELIVERY_RULE = `【${BOUNDARY_VERSION}·图片交付边界】图片作品的可见文案只写用户需要的内容。系统自行补充的数据来源、检索出处、未核实项、核对过程写在聊天正文，不放进 image prompt 或 structured.text。用户明确要求展示的出处、免责声明、仅供参考、风险提示及正常日期、报名截止信息照常保留；不得为画面完整编造事实。image_generate 用于生成/重设计，image_edit 用于局部编辑。多图工具 source_indexes 按附件原始编号选择且底图在首位；执行 prompt 用“底图”“人物素材”“风格参考”等角色称呼，不能把用户附件编号混同重排后的输入槽位。通常推荐 fast；只有复杂身份/动作编辑、多参考精确融合、Flash 明确质量失败重试或用户明确要求 Pro 才建议 high，海报/Logo/最终稿这些品类名称本身不是升级理由。`;
const META_LABEL = /^(?:数据来源|资料来源|信息来源|来源|检索时间|未核实项|未核实|待确认项|整理自)(?:\s*[:：]|\s*[】\]])/;
const LABELS = ["数据来源", "资料来源", "信息来源", "来源", "检索时间", "未核实项", "未核实", "待确认项", "整理自"];
function labelOf(line) {
  const normalized = String(line || "").trim().replace(/^(?:[·•*\-]+\s*|\d+[.)、]\s*)/, "").replace(/^[【\[]/, "");
  if (!META_LABEL.test(normalized)) return "";
  return LABELS.find(label => normalized.startsWith(label)) || "";
}
function preserveLabels(userText) {
  const text = String(userText || "");
  return LABELS.filter(label => text.includes(label) && !new RegExp("(?:不要|不加|去掉|删除|不显示|不需要)[^，。\\n]{0,8}" + label).test(text));
}
function cleanText(text, allowed = []) {
  let removed = 0;
  const value = String(text || "").split("\n").filter(line => {
    const label = labelOf(line);
    if (!label || allowed.includes(label)) return true;
    removed++;
    return false;
  }).join("\n").trim();
  return { text: value, removed };
}
function cleanImageRequest({ prompt, structured }, userText) {
  const fields = structured && typeof structured === "object" && !Array.isArray(structured) ? { ...structured } : {};
  const existing = fields.delivery_policy && Array.isArray(fields.delivery_policy.preserve_labels)
    ? fields.delivery_policy.preserve_labels.filter(x => LABELS.includes(x)) : [];
  const allowed = userText === undefined ? existing : preserveLabels(userText);
  let removed = 0;
  const clean = value => { const result = cleanText(value, allowed); removed += result.removed; return result.text; };
  const cleanedPrompt = clean(prompt);
  const deletedKeys = new Set();
  if (Array.isArray(fields.text)) {
    fields.text = fields.text.flatMap(item => {
      if (!item || typeof item.text !== "string") return [item];
      const text = clean(item.text);
      if (!text) { if (item.key) deletedKeys.add(item.key); return []; }
      return [{ ...item, text }];
    });
  } else if (typeof fields.text === "string") fields.text = clean(fields.text);
  if (fields.layout && Array.isArray(fields.layout.blocks) && deletedKeys.size) {
    fields.layout = { ...fields.layout, blocks: fields.layout.blocks.filter(block => !deletedKeys.has(block.key)) };
  }
  fields.delivery_policy = { version: BOUNDARY_VERSION, preserve_labels: allowed };
  return { prompt: cleanedPrompt, structured: fields, removed };
}
function injectDeliveryRule(messages) {
  // This policy must remain independent of legacy client META_RULE de-duplication.
  const output = messages.slice();
  if (!output.some(m => m && m.role === "system" && typeof m.content === "string" && m.content.includes(BOUNDARY_VERSION))) {
    output.push({ role: "system", content: DELIVERY_RULE });
  }
  return output;
}
function latestUserText(messages) {
  const user = [...messages].reverse().find(m => m && m.role === "user");
  if (!user) return "";
  return typeof user.content === "string" ? user.content : (Array.isArray(user.content) ? user.content.filter(p => p.type === "text").map(p => p.text || "").join("\n") : "");
}
function sanitizeToolCall(call, userText, observe = () => {}) {
  if (!call || !call.function || !IMAGE_TOOLS.has(call.function.name)) return call;
  const args = JSON.parse(call.function.arguments || "{}");
  const result = cleanImageRequest(args, userText);
  args.prompt = result.prompt;
  args.structured = result.structured;
  const explicitPro = requestsModel(userText, "pro");
  const explicitFast = requestsModel(userText, "flash");
  const qualityFeedback = /不满意|效果(?:很)?差|效果不好|(?:上次|上一张|刚才|这张|人物|人脸|文字|排版|Logo)[^，。\n]{0,16}(?:不好|不行|不像|不对|变形|扭曲|乱码|失败)/i.test(userText);
  args.structured.routing = { reason: qualityFeedback ? "quality_retry" : String(args.quality_reason || ""),
    preference: explicitPro ? "pro" : explicitFast ? "flash" : "auto",
    user_quality: requestsQuality(userText) ? "high" : "auto" };
  // Resolve user attachment numbering before the App moves the base to slot 1.
  const indices = args.source_indexes;
  if (Array.isArray(indices) && indices.length > 1) {
    const roles = indices.map((_, i) => String((args.reference_roles || [])[i] || (i === 0 ? "底图" : "素材" + i)));
    const number = { "一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6 };
    args.prompt = args.prompt.replace(/第([一二三四五六1-6])张(?:图片|照片|图)?|图([一二三四五六1-6])/g, (full, a, b) => {
      const n = number[a || b] || Number(a || b), slot = indices.indexOf(n);
      return slot < 0 ? full : roles[slot];
    });
  }
  if (result.removed) observe({ removed: result.removed, tool: call.function.name });
  return { ...call, function: { ...call.function, arguments: JSON.stringify(args) } };
}
function sanitizeCompletion(data, userText, observe, finalizeCalls = calls => calls) {
  if (!data || !Array.isArray(data.choices)) return data;
  return { ...data, choices: data.choices.map(choice => {
    const message = choice.message;
    if (!message || !Array.isArray(message.tool_calls)) return choice;
    return { ...choice, message: { ...message, tool_calls: finalizeCalls(message.tool_calls.map(call => sanitizeToolCall(call, userText, observe))) } };
  }) };
}
class ToolCallStreamGuard {
  constructor(userText, observe, finalizeCalls = calls => calls) { this.userText = userText; this.observe = observe; this.finalizeCalls = finalizeCalls; this.pending = new Map(); this.bytes = 0; }
  flush(index) {
    const calls = this.pending.get(index);
    if (!calls) return [];
    this.pending.delete(index);
    return this.finalizeCalls([...calls.values()].map(call => sanitizeToolCall(call, this.userText, this.observe)));
  }
  pushLine(line) {
    if (!line.trim().startsWith("data:")) return line;
    const raw = line.trim().slice(5).trim();
    if (!raw) return line;
    if (raw === "[DONE]") {
      const frames = [...this.pending.keys()].map(index => "data: " + JSON.stringify({ choices: [{ index, delta: { tool_calls: this.flush(index) } }] }));
      return [...frames, line].join("\n\n");
    }
    let obj;
    try { obj = JSON.parse(raw); } catch { return line; }
    if (!Array.isArray(obj.choices)) return line;
    for (const choice of obj.choices) {
      const index = choice.index || 0, delta = choice.delta;
      if (delta && Array.isArray(delta.tool_calls)) {
        let calls = this.pending.get(index);
        if (!calls) this.pending.set(index, calls = new Map());
        for (const fragment of delta.tool_calls) {
          const slot = fragment.index || 0;
          let call = calls.get(slot);
          if (!call) calls.set(slot, call = { index: slot, type: "function", function: { name: "", arguments: "" } });
          if (fragment.id) call.id = fragment.id;
          if (fragment.function) {
            call.function.name += fragment.function.name || "";
            call.function.arguments += fragment.function.arguments || "";
            this.bytes += Buffer.byteLength(fragment.function.arguments || "");
            if (this.bytes > 2 * 1024 * 1024) throw new Error("TOOL_ARGUMENTS_TOO_LARGE");
          }
        }
        delete delta.tool_calls;
      }
      if (choice.finish_reason && this.pending.has(index)) {
        choice.delta = { ...(delta || {}), tool_calls: this.flush(index) };
      }
    }
    return "data: " + JSON.stringify(obj);
  }
  end() { if (this.pending.size) throw new Error("TOOL_ARGUMENTS_INCOMPLETE"); }
}
module.exports = { BOUNDARY_VERSION, DELIVERY_RULE, labelOf, cleanText, cleanImageRequest, injectDeliveryRule, latestUserText, sanitizeToolCall, sanitizeCompletion, ToolCallStreamGuard };
