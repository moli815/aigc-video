"use strict";
/**
 * 海报文字审计：确定性比对，不让模型下结论。
 *
 * 边界：视觉模型可能把错误字形按上下文读成正确文字。本模块只比较
 * 转录和契约，无法证明笔画清晰、未扭曲，也不能替代独立识别或视觉验收。
 * 不在这里引用无可复核来源的社区准确率数字。
 *
 * 实现要点：**先拼接再定位**。
 * 转录会把一段正文按视觉换行切成两三行，逐行比对会把全部正文误判成「多出」。
 * 所以先把所有行拼成一条无空白长串，用子串定位，再把命中的字符区间标记为「已解释」，
 * 只有落在已解释区间之外的行才算「多出」。
 */

const PUNCT_MAP = [
  [/\u00b7|\u2027|\u30fb/g, "·"],
  [/[（(]/g, "("],
  [/[）)]/g, ")"],
  [/[：:]/g, ":"],
  [/[，,]/g, ","],
  [/[。.]/g, "."],
  [/[！!]/g, "!"],
  [/[？?]/g, "?"],
  [/[“”"']/g, '"'],
  [/[—–－]/g, "-"],
  [/[　\u3000]/g, " "],
];

/** 只做「不影响语义」的归一：全半角、常见标点、空白。绝不做同义替换。 */
function normalize(s) {
  let t = String(s ?? "");
  for (const [re, to] of PUNCT_MAP) t = t.replace(re, to);
  return t.replace(/\s+/g, "");
}

function levenshtein(a, b) {
  if (a === b) return 0;
  if (!a.length) return b.length;
  if (!b.length) return a.length;
  let prev = new Array(b.length + 1);
  for (let j = 0; j <= b.length; j++) prev[j] = j;
  for (let i = 1; i <= a.length; i++) {
    const cur = [i];
    for (let j = 1; j <= b.length; j++) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      cur[j] = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost);
    }
    prev = cur;
  }
  return prev[b.length];
}

function findAll(hay, needle) {
  const out = [];
  if (!needle) return out;
  let i = hay.indexOf(needle);
  while (i !== -1) { out.push(i); i = hay.indexOf(needle, i + needle.length); }
  return out;
}

/** 在拼接串里找与 target 编辑距离最小的窗口。
 *  长度允许 L-1 / L / L+1：转录漏字或多字时长度会变，只比对等长窗口会漏判，
 *  进而把「少了 1 个字」误报成「缺失 + 多出」两条。 */
function bestWindow(hay, target, maxD) {
  const L = target.length;
  if (L < 2 || hay.length < L - 1) return null;
  let best = { d: Infinity, at: -1, text: "" };
  for (const W of [L, L - 1, L + 1]) {
    if (W < 2 || W > hay.length) continue;
    for (let i = 0; i + W <= hay.length; i++) {
      const seg = hay.slice(i, i + W);
      if (seg[0] !== target[0] && seg[W - 1] !== target[L - 1]) continue;
      const d = levenshtein(seg, target);
      if (d < best.d) { best = { d, at: i, text: seg }; if (d === 0) return best; }
    }
  }
  return best.d <= maxD ? best : null;
}

/**
 * @param {Array<{key?:string,text:string,role?:string,duplicable?:boolean}>} expected 契约文案
 * @param {string[]} transcribed 模型严格转录出的各行文字
 * @param {{nearThreshold?:number}} opts
 */
function audit(expected, transcribed, opts = {}) {
  const nearT = Number.isInteger(opts.nearThreshold) ? opts.nearThreshold : 1;
  const exp = (Array.isArray(expected) ? expected : [])
    .filter(b => b && typeof b.text === "string" && b.text.trim())
    .map(b => ({ key: b.key || "", role: b.role || "", text: b.text, n: normalize(b.text), duplicable: b.duplicable === true }));

  const lines = (Array.isArray(transcribed) ? transcribed : [])
    .filter(s => typeof s === "string")
    .map(s => ({ raw: s, n: normalize(s) }));

  let joined = "";
  const ranges = [];
  for (const ln of lines) {
    const start = joined.length;
    joined += ln.n;
    ranges.push({ start, end: joined.length, raw: ln.raw, n: ln.n });
  }

  const explained = new Array(joined.length).fill(false);
  const items = [];

  // Long copy claims its span first. A heading contained in body copy is not
  // evidence that the separate heading was printed. Identical contracts also
  // need separate occurrences rather than all claiming the same pixels.
  const groups = new Map();
  exp.forEach((b, index) => {
    if (!groups.has(b.n)) groups.set(b.n, []);
    groups.get(b.n).push({ ...b, index });
  });
  for (const group of [...groups.values()].sort((a, b) => b[0].n.length - a[0].n.length)) {
    const b = group[0];
    const hits = findAll(joined, b.n).filter(at => !explained.slice(at, at + b.n.length).some(Boolean));
    if (hits.length) {
      hits.forEach(at => { for (let k = at; k < at + b.n.length; k++) explained[k] = true; });
      const allowed = group.reduce((n, row) => n + (row.duplicable ? 2 : 1), 0);
      group.forEach((row, i) => items.push({ key: row.key, text: row.text,
        status: i >= hits.length ? "missing" : hits.length > allowed && i === 0 ? "duplicate" : "exact",
        occurrences: i === 0 ? hits.length : i < hits.length ? 1 : 0, index: row.index }));
      continue;
    }
    for (const row of group) {
      // Prevent a near match from swallowing an already accepted neighbour.
      const available = joined.split("").map((c, i) => explained[i] ? "\u0000" : c).join("");
      const w = bestWindow(available, row.n, nearT);
      if (w && !w.text.includes("\u0000")) {
        for (let k = w.at; k < w.at + w.text.length; k++) explained[k] = true;
        items.push({ key: row.key, text: row.text, status: "near", distance: w.d, actual: w.text, index: row.index });
      } else {
        items.push({ key: row.key, text: row.text, status: "missing", index: row.index });
      }
    }
  }
  items.sort((a, b) => a.index - b.index).forEach(i => { delete i.index; });

  // Every unexplained letter, number or unreadable placeholder is reported.
  // Wrapping has already been resolved by exact spans; no coverage exemption.
  const extras = [];
  for (const r of ranges) {
    // Wrapping is already accounted for by joined spans. Sharing four letters
    // or 70% of a line must not excuse an invented claim or a changed number.
    let unmatched = "";
    for (let k = r.start; k < r.end; k++) if (!explained[k]) unmatched += joined[k];
    if (/[\p{L}\p{N}?]/u.test(unmatched)) extras.push(unmatched);
  }

  const summary = {
    total: items.length,
    exact: items.filter(i => i.status === "exact").length,
    near: items.filter(i => i.status === "near").length,
    duplicate: items.filter(i => i.status === "duplicate").length,
    missing: items.filter(i => i.status === "missing").length,
    extras: extras.length,
  };
  const pass = exp.length > 0 && summary.near === 0 && summary.duplicate === 0 && summary.missing === 0 && summary.extras === 0;
  return { pass, summary, items, extras };
}

/** 严格转录用的系统提示。刻意写死「不要纠正」，因为模型默认会帮你改对。 */
const TRANSCRIBE_SYSTEM =
  "你是严格的 OCR 引擎。逐字符转录这张图里每一处可见文字，按视觉位置从上到下、从左到右，一行输出一条。\n" +
  "禁止纠正拼写，禁止补全，禁止润色，禁止合并不同区域的行。图上写错了就照错的输出。\n" +
  "看不清的字符用 ? 代替，不要猜。\n" +
  "只输出 JSON：{\"texts\":[\"第一行\",\"第二行\"]}";

module.exports = { audit, normalize, levenshtein, findAll, bestWindow, TRANSCRIBE_SYSTEM };
