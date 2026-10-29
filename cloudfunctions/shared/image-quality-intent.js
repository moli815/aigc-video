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
module.exports = { QUALITY_TERMS, requestsQuality, requestsModel };
