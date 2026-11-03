"use strict";

// Read the user's request at the chat boundary, before the Agent decorates its
// provider prompt with generic quality adjectives. Never reinterpret client high.
const QUALITY_TERMS = Object.freeze([
  "高质量", "高品质", "高精度", "最高质量", "最高精度", "专业级", "商业级", "印刷级",
  "精美", "精细排版", "精致排版", "正式印刷", "商业印刷", "高质量印刷", "high quality", "professional quality",
]);
function requestsQuality(text, terms = QUALITY_TERMS) {
  const clauses = String(text || "").toLowerCase().split(/[，。；！!;\n]|\bbut\b|但是|但要/);
  return terms.some(term => {
    const needle = term.toLowerCase();
    return clauses.some(clause => {
      let from = 0, at;
      while ((at = clause.indexOf(needle, from)) >= 0) {
        const before = clause.slice(Math.max(0, at - 16), at);
        if (!/(?:不需要|不用|无需|不要|不追求|不要求|不必|不做|取消|without|no need for)\s*(?:特别|太|这么|那么|的|very|a)?\s*$/.test(before)) return true;
        from = at + needle.length;
      }
      return false;
    });
  });
}
function requestsModel(text, model) {
  const clauses = String(text || "").toLowerCase().split(/[，。；！!;\n]|但是|但要/);
  const pattern = new RegExp("(?:必须|指定|使用|切到|改用|用)\\s*" + model + "\\b", "g");
  return clauses.some(clause => {
    pattern.lastIndex = 0;
    let match;
    while ((match = pattern.exec(clause))) {
      if (!/(?:不|别|不要|不用|无需|不必|禁止)\s*$/.test(clause.slice(0, match.index))) return true;
    }
    return false;
  });
}
// Last explicit instruction wins. A negated model is a real constraint, not
// merely the absence of a positive preference.
function modelPreference(text) {
  const value = String(text || "").toLowerCase();
  const pattern = /(?:(不要|不用|别|禁止|不许|无需)\s*(?:再|使用|用|切到|改用)?|(必须|指定|使用|切到|改用|换成|用)\s*)\s*(pro|flash)\b/g;
  let result = "auto", match;
  while ((match = pattern.exec(value))) {
    result = match[1] ? (match[3] === "pro" ? "flash" : "pro") : match[3];
  }
  return result;
}
function imageQualityReason(userText, fallback = "") {
  const text = String(userText || "");
  const feedback = /不满意|效果(?:很)?差|效果不好|(?:上次|上一张|刚才|这张|图片|人物|人脸|文字|排版|logo)[^，。\n]{0,16}(?:不好|不行|不像|不对|变形|扭曲|乱码|失败|太简单|过于简单|不够真实|信息太少)/i.test(text);
  if (feedback) return "quality_retry";
  if (/(?:保持|保留|不改变|不改|不要改变|不要改)[^，。\n]{0,12}(?:本人|长相|脸|身份)|(?:本人|长相|脸|身份)[^，。\n]{0,8}(?:不变|一致|原样)|把[^，。\n]{0,16}(?:人|人物)[^，。\n]{0,12}(?:放到|放进|合入|合成到|[pP]到)/.test(text)) return "identity_sensitive";
  return String(fallback || "");
}
module.exports = { QUALITY_TERMS, requestsQuality, requestsModel, modelPreference, imageQualityReason };
