/**
 * 模型工具调用格式归一化。
 * 实测同一模型会随机输出四种形态，线上只认第一种，其余三种都会变成乱码文本：
 *   1) 标准 tool_calls（delta.tool_calls）
 *   2) <｜DSML｜ calls><｜DSML｜ invoke name="..."><｜DSML｜ parameter ...>
 *   3) <tool_call>{"name":...,"arguments":{...}}</tool_call>
 *   4) <tool_call>{...}</tool_call>，JSON 内含裸换行（非法 JSON）
 */

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
  try { return JSON.parse(src); } catch {}
  try { return JSON.parse(repairJson(src)); } catch {}
  const last = src.lastIndexOf("}");
  if (last > 0) { try { return JSON.parse(repairJson(src.slice(0, last + 1))); } catch {} }
  return null;
}

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

function build(prompt, structuredText, aspect, source) {
  return {
    prompt,
    structured: { text: flattenText(structuredText || "") },
    aspect_ratio: aspect || "3:4",
    source: source || "attached",
  };
}

/** DSML 格式 */
function parseDSML(text) {
  if (!/DSML/.test(text)) return null;
  const norm = String(text).replace(/｜/g, "|");
  const inv = /<\|DSML\| invoke name="([^"]+)">([\s\S]*?)<\/\|DSML\| invoke>/.exec(norm);
  if (!inv) return null;
  const params = {};
  const re = /<\|DSML\| parameter name="([^"]+)"[^>]*>([\s\S]*?)<\/\|DSML\| parameter>/g;
  let m;
  while ((m = re.exec(inv[2]))) params[m[1]] = m[2].trim();
  if (!params.prompt) return null;
  return {
    format: "dsml",
    name: inv[1],
    tool: build(params.prompt, params.structured_text, params.aspect_ratio, params.source),
  };
}

/** <tool_call>{json}</tool_call> */
function parseXmlToolCall(text) {
  const src = String(text || "");
  let raw = "";
  const closed = /<tool_call>\s*([\s\S]*?)\s*<\/tool_call>/.exec(src);
  if (closed) raw = closed[1];
  else {
    const open = src.indexOf("<tool_call>");
    if (open < 0) return null;
    // 混合格式：<tool_call>{json} + </｜DSML｜ parameter></｜DSML｜ invoke>
    raw = src.slice(open + "<tool_call>".length).replace(/<\/?[｜|]?DSML[｜|]?[^>]*>/g, "").trim();
  }
  if (!raw) return null;
  const obj = tryJson(raw);
  const a = (obj && obj.arguments) || null;
  if (a && a.prompt) {
    const st = a.structured_text || (a.structured && a.structured.text) || a.structured;
    return { format: "xml", name: obj.name || "image_generate", tool: build(a.prompt, st, a.aspect_ratio, a.source) };
  }
  const pr = grabField(raw, "prompt");
  if (!pr) return null;
  return {
    format: "xml-loose",
    name: "image_generate",
    tool: build(pr, grabField(raw, "structured_text"), grabField(raw, "aspect_ratio"), grabField(raw, "source")),
  };
}

function parseAnyToolCall(text) {
  return parseDSML(text) || parseXmlToolCall(text) || null;
}

module.exports = { parseAnyToolCall, parseDSML, parseXmlToolCall, tryJson, repairJson, flattenText, grabField };
