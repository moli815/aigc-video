"use strict";
/**
 * overlay-pipeline —— 把「Seedream 出无字底图 + 服务端真字体文字层」接进生图链路。
 *
 * 与既有 commercial-composer 的区别：
 *   - commercial-composer 把底图当「主视觉照片」摆进 hero 区，文字另起分区（会错位）；
 *   - 这里版式由服务端先定，再让 Seedream 照着草图重绘，文字用同一份 layout 叠上去，
 *     所以底图与文字天然对齐。
 *
 * 开关：IMAGE_COMPOSITION_POLICY.overlay = { enabled, minChars, maxCards }
 * 默认关闭，避免影响现有客户。
 */

const overlay = require("./poster-overlay");
const { paletteOf } = require("./commercial-composer");

const MAX_CARDS = 9;

function policyOf(raw) {
  let p; try { p = typeof raw === "string" ? JSON.parse(raw) : raw; } catch { return null; }
  const o = p && p.overlay;
  if (!o || o.enabled !== true) return null;
  const accountIds = Array.isArray(o.accountIds) ? o.accountIds.filter(a => typeof a === "string").slice(0, 100) : null;
  return {
    accountIds,
    minChars: Math.max(0, Math.min(2000, Number.isFinite(Number(o.minChars)) ? Number(o.minChars) : 40)),
    maxCards: Math.max(1, Math.min(MAX_CARDS, Number.isFinite(Number(o.maxCards)) ? Number(o.maxCards) : MAX_CARDS)),
    audience: o.audience === "all" ? "all" : "allowlist",
  };
}

function enabled(raw, owner) {
  const p = policyOf(raw);
  if (!p) return false;
  if (p.audience === "all") return true;
  return Array.isArray(p.accountIds) && p.accountIds.includes(owner);
}

/** 只有「整张海报、单张、非改图、文案够结构化」才走真字体层 */
function eligible(raw, owner, input) {
  const p = policyOf(raw);
  if (!p || !enabled(raw, owner)) return false;
  if (!input || input.renderIntent === "mockup") return false;
  if (input.textMode === "overlay") return false;
  if (input.layerDecomposition === true) return false;
  if (Array.isArray(input.structured?.preserve_assets) && input.structured.preserve_assets.length) return false;
  if (!["generate", ""].includes(String(input.taskKind || ""))) return false;
  if (input.image) return false;
  const text = input.structured?.text;
  if (!Array.isArray(text) || text.length < 4) return false;
  const shaped = text.filter(t => t && typeof t.text === "string" && t.text.trim());
  if (shaped.length < 4) return false;
  const chars = shaped.reduce((n, t) => n + t.text.trim().length, 0);
  if (chars < p.minChars) return false;
  const { cards, head } = overlay.splitBlocks(shaped);
  if (cards.length < 2 || cards.length > p.maxCards) return false;
  if (!head.length && !cards.some(c => c.price)) return false;
  return true;
}

/** 版式推断：卡片数决定网格，行业气质决定配色；不是固定模板 */
function inferLayout(structured, prompt, width, height) {
  const { cards, head, foot } = overlay.splitBlocks(structured?.text);
  const n = Math.min(cards.length, MAX_CARDS);
  const cols = n <= 3 ? 1 : n <= 6 ? 2 : 3;
  const rows = Math.ceil(n / cols);
  const tall = height / width > 1.15;
  // 卡片越多，页头页脚越薄，给正文留空间
  const header = rows >= 4 ? 0.19 : tall ? 0.24 : 0.22;
  const footer = foot.length ? (rows >= 4 ? 0.10 : 0.14) : 0.06;
  const base = paletteOf(structured, prompt);
  const hero = base.ink;
  return overlay.mergeLayout({
    template: "grid-cards",
    header, footer,
    pad: 0.045,
    gap: cols === 1 ? 0.024 : 0.022,
    grid: { cols, rows },
    artSide: "right",
    palette: {
      hero, paper: base.paper, card: base.paper, ink: base.ink, accent: base.accent,
      heroInk: "#FFFFFF", muted: mixInk(base.ink),
    },
  });
}

/** 次要文字颜色：深墨色调淡，保证与纸色对比度但仍弱于标题 */
function mixInk(ink) {
  const m = /^#([0-9a-f]{6})$/i.exec(String(ink || ""));
  if (!m) return "#6B6259";
  const n = parseInt(m[1], 16);
  const r = (n >> 16) & 255, g = (n >> 8) & 255, b = n & 255;
  const to = c => Math.round(c + (245 - c) * 0.45);
  return "#" + [to(r), to(g), to(b)].map(v => v.toString(16).padStart(2, "0")).join("");
}

/** 底图提示词：草图约束 + 行业画面描述（不含任何文案） */
function baseImagePrompt(layout, structured, prompt) {
  const visual = String(prompt || structured?.artwork_prompt || "").trim();
  const sketch = overlay.sketchPrompt(layout);
  const scene = visual
    ? `画面题材：${visual.slice(0, 220)}`
    : "画面题材：与该行业相符的真实场景或手绘插画风格，材质真实、光线自然。";
  const arts = (overlay.splitBlocks(structured?.text).cards || [])
    .slice(0, layout.grid.cols * layout.grid.rows)
    .map(c => c.label).filter(Boolean);
  const artLine = arts.length
    ? `插画顺序（从左到右、从上到下）：${arts.join("、")}，每幅画成该条目的手绘线描小图，不要写字。`
    : "";
  return [sketch, scene, artLine].filter(Boolean).join("\n");
}

module.exports = { policyOf, enabled, eligible, inferLayout, baseImagePrompt, MAX_CARDS };
