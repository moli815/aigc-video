"use strict";
/**
 * 局部修复：只改错的那一处，其余像素保持不动。
 *
 * 依据：官方 5.5 支持坐标定位编辑（<bbox> 0–999 归一化框选），实测「只改副标题两个字」
 * 能保持画面其余部分不变；整张重出反而会把已经对的地方改错。
 */

/** 归一化 [x,y,w,h] → 官方 <bbox> 语法，坐标取 0–999。 */
function bboxTag(box) {
  if (!Array.isArray(box) || box.length !== 4 || box.some(n => !Number.isFinite(n))) return "";
  const [x, y, w, h] = box;
  const clamp = n => Math.max(0, Math.min(999, Math.round(n)));
  return `<bbox>${clamp(x * 999)} ${clamp(y * 999)} ${clamp((x + w) * 999)} ${clamp((y + h) * 999)}</bbox>`;
}

/**
 * @param {{wrong:string, right:string, box?:number[]}} p
 */
function repairPrompt({ wrong, right, box }) {
  if (!wrong || !right) throw Object.assign(new Error("REPAIR_INPUT_INVALID"), { code: "REPAIR_INPUT_INVALID" });
  const tag = box ? bboxTag(box) : "";
  return [
    tag ? `只修改 ${tag} 框住的这一处文字。` : "只修改图中这一处文字。",
    `把「${wrong}」改为「${right}」。`,
    "画面其他所有内容——包括其他文字、数字、图形、图片、配色、光效、排版位置——必须完整保留，不得重绘、不得移动、不得增删。",
    "修改后的文字要与原来的字体、字号、字重、颜色、倾斜和光照保持一致。",
  ].join("");
}

/** 从审计结果里挑出需要修的条目（near / missing 且能匹配到契约原文）。 */
function planRepairs(auditResult, blocks, boxes = {}) {
  if (!auditResult || !Array.isArray(auditResult.items)) return [];
  const byText = new Map();
  for (const b of Array.isArray(blocks) ? blocks : []) {
    if (b && typeof b.text === "string") byText.set(b.text, b);
  }
  const out = [];
  for (const it of auditResult.items) {
    if (it.status !== "near" && it.status !== "missing") continue;
    const target = byText.get(it.text);
    if (!target) continue;
    out.push({
      key: it.key || "",
      right: it.text,
      wrong: it.status === "near" ? it.actual || "" : "",
      status: it.status,
      box: boxes[it.key] || boxes[it.text] || null,
    });
  }
  return out;
}

module.exports = { bboxTag, repairPrompt, planRepairs };
