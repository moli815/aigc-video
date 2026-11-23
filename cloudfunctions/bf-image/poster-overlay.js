"use strict";
/**
 * poster-overlay —— 海报文字层（服务端真字体排版）
 *
 * 分工：Seedream 只画视觉（背景、插画、装饰），不写任何文字；
 *      文字层由这里用 satori 排版、resvg 栅格化，保证逐字正确、任意字号清晰。
 *
 * 版式真值只有一份：layout。草图生成（给 Seedream 当参考）与文字层渲染
 * 都读同一份 layout，所以两边不会错位。
 *
 * 每种 template 只描述「分区与网格」，不写死具体文案；颜色、字号由内容与
 * 画布尺寸推导，避免所有客户拿到同一张模板脸。
 */

const VERSION = "poster-overlay-v1";

function fail(code, extra) { return Object.assign(new Error(code), { code, ...extra }); }

const el = (type, style, children, props = {}) => ({ type, props: { ...props, style: { boxSizing: "border-box", ...style }, children } });

/** 把 blocks 折成「页头 + 卡片 + 页脚」 */
function splitBlocks(blocks) {
  const list = (Array.isArray(blocks) ? blocks : []).filter(b => b && typeof b.text === "string" && b.text.trim());
  const head = [];
  const cards = [];
  const foot = [];
  for (const b of list) {
    const role = String(b.role || "body");
    const text = b.text.trim();
    if (role === "title" || role === "subtitle") { head.push({ role, text }); continue; }
    if (role === "contact" || role === "footer") { foot.push({ role, text }); continue; }
    if (role === "label") { cards.push({ label: text, lines: [] }); continue; }
    if (cards.length) {
      const last = cards[cards.length - 1];
      if (/^[¥￥$]\s*\d/.test(text) || /^\d+(?:\.\d+)?\s*元/.test(text)) last.price = text;
      else last.lines.push(text);
    } else {
      cards.push({ label: "", lines: [text] });
    }
  }
  return { head, cards, foot };
}

const DEFAULT_LAYOUT = {
  template: "grid-cards",
  header: 0.24,
  footer: 0.14,
  pad: 0.045,
  gap: 0.022,
  grid: { cols: 2, rows: 3 },
  artSide: "right",
  palette: { hero: "#1E3A2E", paper: "#FBF6EF", card: "#FFFFFF", ink: "#2A1E14", accent: "#C0342B", heroInk: "#FFFFFF", muted: "#7B6A57" },
};

function mergeLayout(raw) {
  const l = raw && typeof raw === "object" ? raw : {};
  const p = { ...DEFAULT_LAYOUT.palette, ...(l.palette || {}) };
  const num = (v, d) => (Number.isFinite(Number(v)) ? Number(v) : d);
  const grid = l.grid && Number.isInteger(l.grid.cols) && Number.isInteger(l.grid.rows)
    ? { cols: Math.max(1, Math.min(4, l.grid.cols)), rows: Math.max(1, Math.min(6, l.grid.rows)) }
    : DEFAULT_LAYOUT.grid;
  return {
    template: "grid-cards",
    header: Math.max(0.12, Math.min(0.36, num(l.header, DEFAULT_LAYOUT.header))),
    footer: Math.max(0.08, Math.min(0.24, num(l.footer, DEFAULT_LAYOUT.footer))),
    pad: Math.max(0.02, Math.min(0.08, num(l.pad, DEFAULT_LAYOUT.pad))),
    gap: Math.max(0.01, Math.min(0.05, num(l.gap, DEFAULT_LAYOUT.gap))),
    grid, artSide: l.artSide === "left" ? "left" : "right", palette: p,
  };
}

/** 几何：一次算清，草图与文字层共用 */
function geometry(layout, width, height) {
  const L = mergeLayout(layout);
  const m = width * L.pad;
  const top = height * L.header;
  const bottom = height * (1 - L.footer);
  const bodyH = bottom - top;
  const gapX = width * L.gap;
  const gapY = height * L.gap;
  const cardW = (width - m * 2 - gapX * (L.grid.cols - 1)) / L.grid.cols;
  const cardH = (bodyH - m * 2 - gapY * (L.grid.rows - 1)) / L.grid.rows;
  if (!(cardW > 40 && cardH > 30)) throw fail("OVERLAY_GRID_TOO_DENSE");
  // 卡片内部分区：插画区 + 文字区，两者之和必须落在卡片内容宽内，否则文字会被压成 0 宽
  const cardPad = width * 0.016;
  const innerW = cardW - cardPad * 2;
  const artW = Math.min(cardH * 0.66, innerW * 0.30);
  const textW = innerW - artW - width * 0.008;
  if (!(textW > cardW * 0.35)) throw fail("OVERLAY_CARD_COPY_NARROW");
  return { L, m, top, bottom, bodyH, gapX, gapY, cardW, cardH, cardPad, innerW, artW, textW, width, height };
}

/** 版式草图：纯色块 + 插画占位，交给 Seedream 重绘（不含任何文字） */
function sketchTree(layout, width, height) {
  const g = geometry(layout, width, height);
  const { L, m, top, bottom, gapX, gapY, cardW, cardH, cardPad, artW } = g;
  const empty = el("div", { display: "flex", width: "1px", height: "1px" });
  const rows = [];
  for (let r = 0; r < L.grid.rows; r++) {
    const cells = [];
    for (let c = 0; c < L.grid.cols; c++) {
      // 插画占位：卡片靠 artSide 一侧的圆；另一侧完全留空（文字区）
      const art = el("div", { display: "flex", width: artW + "px", height: artW + "px", backgroundColor: "#D8CFC0", borderRadius: "50%" });
      cells.push(el("div", {
        display: "flex", flexDirection: "row", alignItems: "center",
        justifyContent: L.artSide === "right" ? "space-between" : "flex-start",
        width: cardW + "px", height: cardH + "px", backgroundColor: L.palette.card,
        borderRadius: width * 0.012 + "px", padding: cardPad + "px", flexShrink: 0,
      }, L.artSide === "right" ? [empty, art] : [art, empty]));
    }
    rows.push(el("div", { display: "flex", flexDirection: "row", gap: gapX + "px" }, cells));
  }
  return el("div", { display: "flex", flexDirection: "column", width: width + "px", height: height + "px", backgroundColor: L.palette.paper }, [
    el("div", { display: "flex", width: "100%", height: top + "px", backgroundColor: L.palette.hero }),
    el("div", { display: "flex", flexDirection: "column", gap: gapY + "px", padding: m + "px", height: g.bodyH + "px" }, rows),
    el("div", { display: "flex", width: "100%", height: height * L.footer + "px", backgroundColor: L.palette.hero }),
  ]);
}

/** 文字层：按同一 geometry 叠字 */
function overlayTree(layout, width, height, blocks, background, transparent) {
  const clear = !!background || transparent === true;
  const g = geometry(layout, width, height);
  const { L, m, top, bottom, gapX, gapY, cardW, cardH, cardPad, artW, textW } = g;
  const { head, cards, foot } = splitBlocks(blocks);

  const title = head.find(h => h.role === "title");
  const subtitle = head.find(h => h.role === "subtitle");
  const titleSize = Math.round(width * 0.058);
  const subSize = Math.round(width * 0.020);
  const cardTitleSize = Math.round(width * 0.0195);
  const cardBodySize = Math.round(width * 0.0128);
  const priceSize = Math.round(width * 0.0245);
  const footSize = Math.round(width * 0.021);

  // 头部：标题 + 副标题，左对齐，垂直居中
  const headerBg = clear ? "transparent" : L.palette.hero;
  const header = el("div", {
    display: "flex", flexDirection: "column", justifyContent: "center",
    width: "100%", height: top + "px", backgroundColor: headerBg, backgroundImage: clear ? "linear-gradient(180deg, rgba(8,18,13,0.72) 0%, rgba(8,18,13,0.46) 62%, rgba(8,18,13,0.10) 100%)" : undefined,
    padding: m + "px", gap: width * 0.012 + "px",
  }, [
    title ? el("div", { display: "flex", fontSize: titleSize + "px", fontWeight: 700, color: L.palette.heroInk, lineHeight: 1.14, letterSpacing: "-0.02em" }, title.text) : el("div", { display: "flex" }, ""),
    subtitle ? el("div", { display: "flex", fontSize: subSize + "px", fontWeight: 400, color: L.palette.heroInk, opacity: 0.82, lineHeight: 1.5 }, subtitle.text) : el("div", { display: "flex" }, ""),
  ]);

  // 卡片网格
  const rows = [];
  const shown = Math.min(cards.length, L.grid.cols * L.grid.rows);
  for (let r = 0; r < L.grid.rows; r++) {
    const cells = [];
    for (let c = 0; c < L.grid.cols; c++) {
      const idx = r * L.grid.cols + c;
      const card = cards[idx];
      const inner = card ? el("div", {
        display: "flex", flexDirection: "column", justifyContent: "center",
        width: textW + "px", height: card ? (cardH - cardPad * 2) + "px" : "1px", gap: width * 0.004 + "px", flexShrink: 0,
      }, [
        el("div", { display: "flex", fontSize: cardTitleSize + "px", fontWeight: 700, color: L.palette.ink, lineHeight: 1.25 }, card.label || ""),
        card.lines.length
          ? el("div", { display: "flex", fontSize: cardBodySize + "px", color: L.palette.muted, lineHeight: 1.5, whiteSpace: "pre-wrap", wordBreak: "break-word" }, card.lines.join("　"))
          : el("div", { display: "flex" }, ""),
        card.price
          ? el("div", { display: "flex", fontSize: priceSize + "px", fontWeight: 700, color: L.palette.accent, lineHeight: 1.2, marginTop: width * 0.004 + "px" }, card.price)
          : el("div", { display: "flex" }, ""),
      ]) : el("div", { display: "flex", width: "1px", height: "1px" });
      cells.push(el("div", {
        display: "flex", flexDirection: "row", alignItems: "center",
        justifyContent: L.artSide === "right" ? "space-between" : "flex-start",
        width: cardW + "px", height: cardH + "px",
        backgroundColor: !clear && card ? L.palette.card : "transparent",
        borderRadius: width * 0.012 + "px", padding: cardPad + "px", flexShrink: 0,
        border: !clear && card ? "1px solid rgba(30,58,46,0.08)" : "0px solid transparent",
      }, L.artSide === "right" ? [inner, el("div", { display: "flex", width: artW + "px", height: "1px", flexShrink: 0 })] : [el("div", { display: "flex", width: artW + "px", height: "1px", flexShrink: 0 }), inner]));
    }
    rows.push(el("div", { display: "flex", flexDirection: "row", gap: gapX + "px" }, cells));
  }
  const body = el("div", {
    display: "flex", flexDirection: "column", gap: gapY + "px",
    padding: m + "px", height: g.bodyH + "px", backgroundColor: "transparent",
  }, rows);

  // 页脚：电话优先，其余并排
  const contact = foot.filter(f => f.role === "contact");
  const rest = foot.filter(f => f.role !== "contact");
  const footer = el("div", {
    display: "flex", flexDirection: "row", alignItems: "center", justifyContent: "space-between",
    width: "100%", height: height * L.footer + "px", backgroundColor: clear ? "transparent" : L.palette.hero, backgroundImage: clear ? "linear-gradient(0deg, rgba(8,18,13,0.78) 0%, rgba(8,18,13,0.42) 100%)" : undefined,
    padding: "0 " + m + "px", gap: width * 0.02 + "px",
  }, [
    el("div", { display: "flex", flexDirection: "column", justifyContent: "center", gap: width * 0.004 + "px" },
      contact.map(t => el("div", { display: "flex", fontSize: footSize + "px", fontWeight: 700, color: L.palette.heroInk }, t.text)).concat(
        contact.length ? [] : [el("div", { display: "flex", width: "1px", height: "1px" })])),
    rest.length
      ? el("div", { display: "flex", flexDirection: "column", alignItems: "flex-end", justifyContent: "center", gap: width * 0.003 + "px" },
          rest.map(t => el("div", { display: "flex", fontSize: Math.round(footSize * 0.72) + "px", color: L.palette.heroInk, opacity: 0.8 }, t.text)))
      : el("div", { display: "flex", width: "1px", height: "1px" }),
  ]);

  const stack = background
    ? [el("div", { display: "flex", position: "absolute", top: 0, left: 0, width: width + "px", height: height + "px" },
        [el("img", { width: "100%", height: "100%", objectFit: "cover" }, undefined, { src: background })]), header, body, footer]
    : [header, body, footer];

  return {
    tree: el("div", {
      display: "flex", flexDirection: "column", position: "relative",
      width: width + "px", height: height + "px", backgroundColor: clear ? "transparent" : L.palette.paper, fontFamily: "Noto CJK",
    }, stack),
    stats: { cards: cards.length, shown, titleSize, subSize, cardTitleSize, cardBodySize, priceSize },
  };
}

/**
 * 渲染文字层 SVG（透明背景），调用方再与底图合成。
 * @returns {{svg:string, stats:object, geometry:object}}
 */
function renderOverlay({ layout, width, height, blocks, satori, background }) {
  if (!satori) throw fail("OVERLAY_SATORI_REQUIRED");
  const { tree, stats } = overlayTree(layout, width, height, blocks, background);
  const g = geometry(layout, width, height);
  return { tree, stats, geometry: g };
}

async function overlaySvg({ layout, width, height, blocks, satori, fonts, background }) {
  const { tree, stats, geometry: g } = renderOverlay({ layout, width, height, blocks, satori, background });
  const svg = await satori(tree, { width, height, fonts });
  return { svg, stats, geometry: g };
}

/** 给 Seedream 的草图提示词：把 layout 翻译成人话，保证两边同源 */
function sketchPrompt(layout) {
  const L = mergeLayout(layout);
  const pct = n => `${Math.round(n * 100)}%`;
  const art = L.artSide === "right" ? "右侧" : "左侧";
  const blank = L.artSide === "right" ? "左侧" : "右侧";
  return [
    "参考图1是一张版式草图（色块示意图）。请把它重绘成一张商业海报的背景画面，严格保持草图的区块位置、大小与比例，不要移动、缩放或增减任何区块。",
    `① 顶部色块（约 ${pct(L.header)} 高）→ 行业氛围背景，可以有极淡的工具或场景线稿，不要放主体；`,
    `② 中部 ${pct(1 - L.header - L.footer)} 的区域 → 干净的浅色背景，可以有极淡的材质纹理；`,
    `③ ${L.grid.cols} 列 ${L.grid.rows} 行共 ${L.grid.cols * L.grid.rows} 块卡片保持原有位置和大小，改成带细微纹理与圆角的纸质卡片；`,
    `④ 每块卡片${art}的圆形占位 → 换成与该条目内容对应的手绘线描插画；`,
    `⑤ 每块卡片${blank}保持完全空白，不要画任何东西——这里要放文字；`,
    `⑥ 底部色块（约 ${pct(L.footer)} 高）→ 深色信息带，可以有极淡的装饰线稿。`,
    "禁止：任何文字、汉字、字母、数字、价签、包装字符、标签、水印、签名、logo。整张画面不能出现任何可识别的文字或符号。",
  ].join("\n");
}

/** 叠字颜色安全：底图对应区域偏暗就用浅色字（用于 Seedream 没听话时兜底） */
function pickInk(sampleLuma, layout) {
  const L = mergeLayout(layout);
  return sampleLuma === null || sampleLuma === undefined
    ? L.palette.heroInk
    : sampleLuma < 0.5 ? "#FFFFFF" : L.palette.ink;
}

/**
 * 纯 JS alpha 合成：base（Seedream 底图）上叠 layer（文字层 RGBA）。
 * 不走 satori 的 <img>——实测内嵌大图会把后续文字层吞掉。
 */
function blend(base, layer) {
  if (base.width !== layer.width || base.height !== layer.height) throw fail("OVERLAY_SIZE_MISMATCH");
  const out = Buffer.alloc(base.width * base.height * 4);
  for (let i = 0; i < out.length; i += 4) {
    const a = layer.data[i + 3] / 255;
    if (a === 0) {
      out[i] = base.data[i]; out[i + 1] = base.data[i + 1]; out[i + 2] = base.data[i + 2];
    } else if (a >= 0.999) {
      out[i] = layer.data[i]; out[i + 1] = layer.data[i + 1]; out[i + 2] = layer.data[i + 2];
    } else {
      out[i] = Math.round(layer.data[i] * a + base.data[i] * (1 - a));
      out[i + 1] = Math.round(layer.data[i + 1] * a + base.data[i + 1] * (1 - a));
      out[i + 2] = Math.round(layer.data[i + 2] * a + base.data[i + 2] * (1 - a));
    }
    out[i + 3] = 255;
  }
  return out;
}

/**
 * 一步到位：底图 + 文字层 → 成品 PNG。
 * @param {Buffer} backgroundPng Seedream 出的无字底图（PNG）
 */
async function composeOnBackground({ layout, width, height, blocks, satori, resvg, fonts, backgroundPng, PNG }) {
  if (!satori || !resvg || !PNG) throw fail("OVERLAY_ENGINE_REQUIRED");
  const tree = overlayTree(layout, width, height, blocks, null, true).tree;
  const svg = await satori(tree, { width, height, fonts });
  const layerPng = Buffer.from(new resvg.Resvg(svg, { fitTo: { mode: "width", value: width } }).render().asPng());
  const layer = PNG.sync.read(layerPng);
  const base = PNG.sync.read(backgroundPng);
  if (base.width !== width || base.height !== height) throw fail("OVERLAY_CANVAS_MISMATCH", { got: `${base.width}x${base.height}` });
  return PNG.sync.write({ width, height, data: blend(base, layer) });
}

/**
 * 把底图裁切/缩放到目标画布（Seedream 偶发返回近似尺寸时用）。
 * 复用 resvg 的 <image> 渲染，不引入新的图像库。
 */
function fitToCanvas(bytes, width, height, { resvg }) {
  if (!resvg) throw fail("OVERLAY_RESVG_REQUIRED");
  const mime = bytes[0] === 137 ? "image/png" : "image/jpeg";
  const href = `data:${mime};base64,${bytes.toString("base64")}`;
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}"><image x="0" y="0" width="${width}" height="${height}" preserveAspectRatio="xMidYMid slice" xlink:href="${href}"/></svg>`;
  return Promise.resolve(Buffer.from(new resvg.Resvg(svg, { fitTo: { mode: "width", value: width } }).render().asPng()));
}

/**
 * 长文版式（longform）：用户给的是一整篇文章时的排版。
 *
 * 不做「卡片网格」，改做「标题带 + 多栏流式正文 + 页脚」，像杂志内页／信息长图。
 * 文字全部由 satori 用真实字体渲染，500–1500 字都能逐字清晰，不受 Seedream
 * 单张 12–15 个文字块的上限约束。
 */
function longformTree(layout, width, height, opts, background) {
  const { title, subtitle, body, footer: footerText, pageNo } = opts || {};
  const L = mergeLayout(layout);
  const m = width * 0.072;
  const pad = width * 0.030;
  const inner = width - m * 2;
  const text = String(body || "").replace(/\r\n/g, "\n").trim();
  const chars = text.length;

  const cols = chars > 900 ? 3 : chars > 420 ? 2 : 1;
  const lineHeight = 1.9;
  // 字号按「能不能填满可用高度」反推，再受上下限约束：短文放大填满、长文缩小保清晰。
  // 推导：每行字数 = 栏宽/字号，行数 = 字数×字号/栏宽，总高 = 行数×字号×行高 ≤ 可用高。
  const colW = (inner - width * 0.028 * (cols - 1)) / cols;
  const availH = height * 0.715;
  const fitSize = Math.sqrt((colW * availH * 0.72) / (Math.max(1, chars) * lineHeight));
  const bodySize = Math.max(18, Math.min(Math.round(width * 0.0218), Math.round(fitSize)));

  const paragraphs = text.split(/\n{2,}/).map(s => s.trim()).filter(Boolean);
  const colTexts = Array.from({ length: cols }, () => []);
  const weights = Array.from({ length: cols }, () => 0);
  for (const p of paragraphs) {
    const idx = weights.indexOf(Math.min(...weights));
    colTexts[idx].push(p);
    weights[idx] += p.length;
  }

  const headerH = height * (title ? 0.20 : 0.09);
  const footerH = height * 0.085;
  const heroInk = background ? L.palette.ink : L.palette.heroInk;

  const header = el("div", {
    display: "flex", flexDirection: "column", justifyContent: "flex-end", position: "relative",
    width: "100%", height: headerH + "px", padding: m + "px", paddingBottom: pad + "px",
    backgroundColor: background ? "transparent" : L.palette.hero, gap: width * 0.010 + "px",
  }, [
    el("div", {
      display: "flex", position: "absolute", top: m * 0.62 + "px", left: m + "px", right: m + "px",
      flexDirection: "row", alignItems: "center", justifyContent: "space-between",
    }, [
      el("div", { display: "flex", fontSize: Math.round(width * 0.0122) + "px", letterSpacing: "0.32em", color: heroInk, opacity: 0.62 }, "MAIHE BAKERY · SINCE 2015"),
      el("div", { display: "flex", fontSize: Math.round(width * 0.0122) + "px", color: heroInk, opacity: 0.62 }, pageNo || ""),
    ]),
    title ? el("div", { display: "flex", fontSize: Math.round(width * 0.062) + "px", fontWeight: 700, color: heroInk, lineHeight: 1.12, letterSpacing: "-0.02em" }, title) : el("div", { display: "flex" }, ""),
    el("div", { display: "flex", flexDirection: "row", alignItems: "center", gap: width * 0.012 + "px" }, [
      el("div", { display: "flex", width: width * 0.055 + "px", height: width * 0.0045 + "px", backgroundColor: L.palette.accent }),
      subtitle ? el("div", { display: "flex", fontSize: Math.round(width * 0.0185) + "px", color: heroInk, opacity: 0.86, lineHeight: 1.5 }, subtitle) : el("div", { display: "flex" }, ""),
    ]),
  ]);

  const headingOf = p => p.length <= 18 && !/[。！？；]$/.test(p);
  const quoteOf = p => /^[「“"]/.test(p) && /[」”"]$/.test(p);

  const renderPara = (p, isFirst) => {
    if (headingOf(p)) {
      return el("div", { display: "flex", flexDirection: "row", alignItems: "stretch", gap: bodySize * 0.55 + "px", marginTop: bodySize * 0.18 + "px" }, [
        el("div", { display: "flex", width: width * 0.006 + "px", backgroundColor: L.palette.accent }),
        el("div", { display: "flex", fontSize: Math.round(bodySize * 1.22) + "px", fontWeight: 700, color: L.palette.accent, lineHeight: 1.45 }, p),
      ]);
    }
    if (quoteOf(p)) {
      return el("div", {
        display: "flex", padding: bodySize * 0.8 + "px " + bodySize * 0.9 + "px",
        borderLeft: width * 0.006 + "px solid " + L.palette.accent, backgroundColor: "rgba(0,0,0,0.035)",
        fontSize: bodySize * 1.04 + "px", color: L.palette.ink, lineHeight: lineHeight,
        whiteSpace: "pre-wrap", wordBreak: "break-word",
      }, p);
    }
    if (isFirst && cols === 1 && p.length > 12) {
      const head = p.slice(0, 1);
      const rest1 = p.slice(1, 26);
      const rest2 = p.slice(26);
      return el("div", { display: "flex", flexDirection: "column", gap: bodySize * 0.2 + "px" }, [
        el("div", { display: "flex", flexDirection: "row", alignItems: "flex-start", gap: bodySize * 0.25 + "px" }, [
          el("div", { display: "flex", fontSize: Math.round(bodySize * 2.5) + "px", fontWeight: 700, color: L.palette.accent, lineHeight: 1.0, marginTop: bodySize * 0.15 + "px" }, head),
          el("div", { display: "flex", width: "1px", height: "1px" }),
          el("div", { display: "flex", flex: 1, fontSize: bodySize + "px", color: L.palette.ink, lineHeight: lineHeight, whiteSpace: "pre-wrap", wordBreak: "break-word" }, rest1),
        ]),
        rest2 ? el("div", { display: "flex", fontSize: bodySize + "px", color: L.palette.ink, lineHeight: lineHeight, whiteSpace: "pre-wrap", wordBreak: "break-word" }, rest2) : el("div", { display: "flex" }, ""),
      ]);
    }
    return el("div", {
      display: "flex", fontSize: bodySize + "px", color: L.palette.ink, lineHeight: lineHeight,
      textIndent: bodySize * 1.9 + "px", whiteSpace: "pre-wrap", wordBreak: "break-word",
    }, p);
  };

  const bodyZone = el("div", {
    display: "flex", flexDirection: "row", gap: width * 0.028 + "px",
    width: "100%", height: (height - headerH - footerH) + "px",
    padding: pad + "px " + m + "px", backgroundColor: background ? "transparent" : L.palette.paper,
  }, colTexts.map((col, ci) => el("div", {
    display: "flex", flexDirection: "column", gap: bodySize * 0.58 + "px",
    width: (inner - width * 0.028 * (cols - 1)) / cols + "px",
  }, col.map((p, pi) => renderPara(p, ci === 0 && pi === 0)))));

  const footer = el("div", {
    display: "flex", flexDirection: "column", justifyContent: "center",
    width: "100%", height: footerH + "px", padding: "0 " + m + "px",
    backgroundColor: background ? "transparent" : L.palette.hero, gap: width * 0.008 + "px",
  }, [
    el("div", { display: "flex", width: "100%", height: "1px", backgroundColor: L.palette.heroInk, opacity: 0.22 }),
    el("div", { display: "flex", flexDirection: "row", alignItems: "center", justifyContent: "space-between", width: "100%" }, [
      el("div", { display: "flex", fontSize: Math.round(width * 0.0185) + "px", fontWeight: 700, color: heroInk }, String(footerText || "")),
      el("div", { display: "flex", fontSize: Math.round(width * 0.0135) + "px", color: heroInk, opacity: 0.6, letterSpacing: "0.24em" }, "GOOD BREAD · WARMER DAYS"),
    ]),
  ]);

  const stack = background
    ? [el("div", { display: "flex", position: "absolute", top: 0, left: 0, width: width + "px", height: height + "px" },
        [el("img", { width: "100%", height: "100%", objectFit: "cover" }, undefined, { src: background })]), header, bodyZone, footer]
    : [header, bodyZone, footer];

  return {
    tree: el("div", {
      display: "flex", flexDirection: "column", position: "relative",
      width: width + "px", height: height + "px",
      backgroundColor: background ? "transparent" : L.palette.paper, fontFamily: "Noto CJK",
    }, stack),
    stats: { mode: "longform", chars, cols, bodySize, paragraphs: paragraphs.length },
  };
}

module.exports = {
  VERSION, DEFAULT_LAYOUT, mergeLayout, geometry, splitBlocks,
  sketchTree, sketchPrompt, overlayTree, longformTree, overlaySvg, renderOverlay, pickInk,
  blend, composeOnBackground, fitToCanvas,
};
