"use strict";

/**
 * 模型工具调用标签解析（服务端）。
 *
 * 实测同一模型会随机输出四种形态，只有第一种是标准 OpenAI tool_calls：
 *   1) 标准 tool_calls（delta.tool_calls）
 *   2) <｜DSML｜ calls><｜DSML｜ invoke name="..."><｜DSML｜ parameter ...>
 *   3) <tool_call>{"name":...,"arguments":{...}}</tool_call>
 *   4) 混合体：<tool_call>{...} 但结尾是 </｜DSML｜ parameter>
 *
 * 2/3/4 若原样下发给客户端，用户会看到一屏标签且出不了图。
 * 这里把它们归一成与标准 tool_calls 等价的结构。
 */

/** 修复 JSON 字符串里的裸换行/制表符，让非法 JSON 可解析 */
function repairJson(src) {
  let out = "", inStr = false, esc = false;
  for (let i = 0; i < src.length; i++) {
    const ch = src[i];
    if (esc) { out += ch; esc = false; continue; }
    if (ch === "\\") { out += ch; esc = true; continue; }
    if (ch === '"') { inStr = !inStr; out += ch; continue; }
    if (inStr && ch === "\n") { out += "\\n"; continue; }
    if (inStr && ch === "\r") { continue; }
    if (inStr && ch === "\t") { out += "\\t"; continue; }
    out += ch;
  }
  return out;
}

function tryJson(src) {
  if (!src) return null;
  try { return JSON.parse(src); } catch {}
  try { return JSON.parse(repairJson(src)); } catch {}
  const last = src.lastIndexOf("}");
  if (last > 0) { try { return JSON.parse(repairJson(src.slice(0, last + 1))); } catch {} }
  return null;
}

/** 把对象/数组里的字符串抽成文本（模型有时给对象而不是字符串） */
function flattenText(v) {
  if (typeof v === "string") {
    const t = v.trim();
    if (/^\{[\s\S]*\}$/.test(t)) {
      const inner = tryJson(t);
      if (inner) return flattenText(inner);
    }
    return t;
  }
  if (Array.isArray(v)) return v.map(flattenText).filter(Boolean).join("\n");
  if (v && typeof v === "object") return Object.values(v).map(flattenText).filter(Boolean).join("\n");
  return "";
}

/** 字段级正则兜底，不依赖 JSON 合法性 */
function grabField(src, name) {
  const re = new RegExp('"' + name + '"\\s*:\\s*"((?:[^"\\\\]|\\\\.)*)"', "s");
  const m = re.exec(src);
  if (!m) return "";
  return m[1].replace(/\\n/g, "\n").replace(/\\"/g, '"').replace(/\\\\/g, "\\");
}

const CN_NUM = { 一: "1", 二: "2", 三: "3", 四: "4", 五: "5", 六: "6", 七: "7", 八: "8", 九: "9", 十: "10" };
const normNum = (s) => CN_NUM[s] || s;

/** 把标签里抓到的参数整理成标准 tool 参数对象 */
function buildArguments(params) {
  const args = {};
  if (params.prompt) args.prompt = params.prompt;
  const st = params.structured_text || params.structured;
  if (st != null && st !== "") {
    if (typeof st === "string" && /^\{[\s\S]*\}$/.test(st.trim())) {
      const o = tryJson(st);
      args.structured = o || { text: st };
    } else if (typeof st === "object") {
      args.structured = st;
    } else {
      args.structured = { text: String(st) };
    }
  }
  if (params.aspect_ratio) args.aspect_ratio = params.aspect_ratio;
  if (params.size) args.size = params.size;
  if (params.source) args.source = params.source;
  if (params.render_intent) args.render_intent = params.render_intent;
  if (params.task_kind) args.task_kind = params.task_kind;
  if (params.text_mode) args.text_mode = params.text_mode;
  for (const key of ["source_indexes", "reference_roles", "library_refs"]) {
    const value = typeof params[key] === "string" ? tryJson(params[key]) : params[key];
    if (Array.isArray(value)) args[key] = value;
  }
  const index = typeof params.source_index === "string" && /^\d+$/.test(params.source_index)
    ? Number(params.source_index) : params.source_index;
  if (Number.isSafeInteger(index)) args.source_index = index;
  return args;
}

/** 格式 2：<｜DSML｜ invoke> */
function parseDSML(text) {
  if (!/DSML/i.test(text)) return null;
  const norm = String(text).replace(/｜/g, "|");
  const inv = /<\|DSML\|[\s\S]{0,20}?invoke\s+name="([^"]+)"[^>]*>([\s\S]*?)<\/\|DSML\|\s*invoke>/.exec(norm);
  if (!inv) return null;
  const params = {};
  const re = /<\|DSML\|\s*parameter\s+name="([^"]+)"[^>]*>([\s\S]*?)<\/\|DSML\|\s*parameter>/g;
  let m;
  while ((m = re.exec(inv[2]))) params[m[1]] = m[2].trim();
  if (!params.prompt) return null;
  return { format: "dsml", name: inv[1], arguments: buildArguments(params) };
}

/** 格式 3/4：<tool_call>{json} */
function parseToolCallTag(text) {
  const src = String(text || "");
  let raw = "";
  const closed = /<tool_call>\s*([\s\S]*?)\s*<\/tool_call>/.exec(src);
  if (closed) raw = closed[1];
  else {
    const open = src.indexOf("<tool_call>");
    if (open < 0) return null;
    raw = src.slice(open + "<tool_call>".length).replace(/<\/?[｜|]?DSML[｜|]?[^>]*>/g, "").trim();
  }
  if (!raw) return null;
  const obj = tryJson(raw);
  if (obj && obj.arguments && obj.arguments.prompt) {
    return {
      format: closed ? "tool_call" : "tool_call_hybrid",
      name: obj.name || "image_generate",
      arguments: buildArguments(obj.arguments),
    };
  }
  const pr = grabField(raw, "prompt");
  if (!pr) return null;
  return {
    format: "tool_call_loose",
    name: "image_generate",
    arguments: buildArguments({
      prompt: pr,
      structured_text: grabField(raw, "structured_text"),
      aspect_ratio: grabField(raw, "aspect_ratio"),
      source: grabField(raw, "source"),
    }),
  };
}

/** 对外入口：返回 null 表示没有可解析的标签 */
function parseTaggedToolCall(text) {
  return parseDSML(text) || parseToolCallTag(text) || null;
}

/** 去掉文本里的所有工具标签，用于解析失败时降级成纯文本 */
function stripToolTags(text) {
  return String(text || "")
    .replace(/<\|?DSML\|?[^>]*>/g, "")
    .replace(/<tool_call>[\s\S]*?<\/tool_call>/g, "")
    .replace(/<\/?tool_calls?>/g, "")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

/** 这段文本是否出现工具标签迹象（用于决定是否转入缓冲） */
function looksLikeToolTag(text) {
  let s = String(text || "");
  // 上游/网关可能把尖括号转义，检测前先还原（只用于判断，不改原文）
  s = s.replace(/\\u003c/gi, "<").replace(/\\u003e/gi, ">");
  // 模型用的竖线是全角「｜」，两种都要覆盖
  if (/<[｜|]?DSML[｜|]?/i.test(s)) return true;
  if (/<tool_calls?>/i.test(s)) return true;
  // 半截标签：SSE 行里 content 后面紧跟 JSON 引号，不是行尾，
  // 旧写法用 /<[a-z_]*$/ 在整行上永远匹配不到。
  if (/<[a-z_]{0,12}"/i.test(s)) return true;
  return false;
}

module.exports = { parseTaggedToolCall, stripToolTags, looksLikeToolTag, tryJson, flattenText, grabField, repairJson };
