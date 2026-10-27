"use strict";
const crypto = require("crypto");
// Never log an upstream message/body: validation errors can echo user input.
function chatRejection(status, detail, request) {
  let parsed; try { parsed = JSON.parse(detail); } catch { parsed = {}; }
  const error = parsed && parsed.error || {};
  const token = value => typeof value === "string" && /^[A-Za-z0-9_.:[\]-]{1,100}$/.test(value) ? value : "";
  const content = String(error.message || parsed.message || detail || "").toLowerCase();
  const rules = [
    ["image_unsupported", /(?:not support|unsupported|text.only).*(?:image|vision)|(?:image|vision).*(?:not support|unsupported)/],
    ["image_invalid", /invalid.*image|image.*(?:invalid|decode|format|download)/],
    ["thinking_parameter", /enable_thinking|reasoning_effort|thinking/],
    ["token_limit", /max_tokens|max_completion_tokens|token.*limit|context.*length/],
    ["tool_schema", /tool_choice|tools|function.*(?:schema|parameter)/],
    ["model_unavailable", /model.*(?:not found|does not exist|not exist|invalid)/],
    ["credential", /api.key|unauthorized|authentication/],
  ];
  const messages = request.messages || [];
  return { upstreamStatus: status, upstreamCode: token(error.code), upstreamType: token(error.type),
    parameter: token(error.param), category: (rules.find(([, re]) => re.test(content)) || ["unclassified"])[0],
    responseHash: crypto.createHash("sha256").update(String(detail || "")).digest("hex").slice(0,16),
    model: String(request.model || "").slice(0,100), messageCount: messages.length,
    imageCount: messages.reduce((n,m)=>n+(Array.isArray(m.content)?m.content.filter(p=>p&&p.type==="image_url").length:0),0),
    toolCount: Array.isArray(request.tools) ? request.tools.length : 0,
    maxTokens: Number(request.max_tokens) || 0, thinkingEnabled: request.enable_thinking === true };
}
module.exports = { chatRejection };
