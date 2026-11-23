"use strict";
/**
 * 「保数字」校验：生成后确认关键数字/成分/型号真的落在图上了。
 *
 * 背景（2026-11-22）：契约里写「北海道小麦粉 · 栗子泥 40 克」，模型画出来是
 * 「香甜栗子奶油，绵软细腻」——字形对了，硬参数被改写成卖点。文字层再准，
 * 客户要的规格没上画面就是错。这里在出图后做一次确定性比对：
 *   blocks 里抽出硬 token（价格、克数、百分比、年份、层数、型号）→ 视觉模型逐字转录 →
 *   归一化后做子串比对 → 缺了哪些一目了然。
 *
 * 边界：转录本身可能把错字按上下文读回正确字（与 poster-text-audit 同一限制），
 * 所以这里只回答「这些 token 有没有出现在转录里」，不能证明笔画完全正确。
 * 失败一律 fail-open：校验只是诊断，不允许因为它让出图中断。
 */

const DIGIT_TOKEN = /(?:[¥￥]\s?\d+(?:\.\d+)?|\d+(?:\.\d+)?\s?(?:克|g|G|kg|KG|ml|mL|毫升|升|年|层|度|°|%|元|寸|小时|分钟|天|个月|周|人|次))/g;

/** 从 structured.text（数组或字符串）里抽出必须出现在画面上的硬 token */
function tokensOf(blocks, limit = 16) {
  const parts = [];
  const push = (t) => { if (typeof t === "string" && t.trim()) parts.push(t); };
  if (Array.isArray(blocks)) {
    for (const b of blocks) {
      if (typeof b === "string") push(b);
      else if (b && typeof b.text === "string") push(b.text);
    }
  } else if (typeof blocks === "string") {
    push(blocks);
  }
  const set = new Set();
  for (const m of parts.join(" ").match(DIGIT_TOKEN) || []) {
    const token = m.replace(/\s+/g, "");
    if (token.length >= 2) set.add(token);
  }
  return [...set].slice(0, limit);
}

/** 只做不影响语义的归一：空白与标点 */
function normalize(text) {
  return String(text == null ? "" : text)
    .replace(/\s+/g, "")
    .replace(/[，,。.、·:：;；!！?？"'“”‘’()（）\[\]【】]/g, "");
}

/** tokens 是否都出现在转录里
 *  先按原样比；再退一步只比数字——
 *  契约写「4980 元」、图上印「¥4980」是同一件事，按原样比会全判成缺失（线上踩过）。
 */
function check(tokens, ocrText) {
  const hay = normalize(ocrText);
  const hayDigits = hay.replace(/[^0-9]/g, "");
  const list = Array.isArray(tokens) ? tokens : [];
  const missing = list.filter(t => {
    if (hay.includes(normalize(t))) return false;
    const digits = String(t).replace(/[^0-9]/g, "");
    if (digits.length >= 2 && hayDigits.includes(digits)) return false;
    return true;
  });
  return { checked: list.length, missing };
}

const OCR_PROMPT = [
  "逐字符转录这张图里所有可见文字。",
  "按从上到下、从左到右的顺序，一行输出一条。",
  "不要翻译、不要补全、不要纠正错字、不要解释；看不清就照抄你能看到的字形。",
].join("");

/** 用视觉模型转录整张图；失败返回空串（调用方按 fail-open 处理） */
async function transcribe({ cfg, imageUrl, fetchImpl = fetch, timeoutMs = 15000 }) {
  if (!cfg || !cfg.base || !cfg.apiKey || !cfg.model) throw Object.assign(Error("VISION_NOT_READY"), { code: "VISION_NOT_READY" });
  const url = String(imageUrl || "");
  if (!/^https:\/\//.test(url) && !/^data:image\//.test(url)) throw Object.assign(Error("VISION_IMAGE_UNSUPPORTED"), { code: "VISION_IMAGE_UNSUPPORTED" });
  const payload = {
    model: cfg.model,
    messages: [{
      role: "user",
      content: [
        { type: "image_url", image_url: { url } },
        { type: "text", text: OCR_PROMPT },
      ],
    }],
    max_tokens: 1200,
    temperature: 0,
  };
  const res = await fetchImpl(cfg.base.replace(/\/$/, "") + "/chat/completions", {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: "Bearer " + cfg.apiKey },
    body: JSON.stringify(payload),
    signal: AbortSignal.timeout(timeoutMs),
  });
  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw Object.assign(Error("VISION_HTTP_" + res.status), { code: "VISION_HTTP_" + res.status, detail: body.slice(0, 240) });
  }
  const data = await res.json().catch(() => null);
  const text = data && data.choices && data.choices[0] && data.choices[0].message && data.choices[0].message.content;
  if (typeof text === "string") return text;
  // 有些兼容层把内容放在 content 数组里
  const arr = data && data.choices && data.choices[0] && data.choices[0].message && data.choices[0].message.content;
  if (Array.isArray(arr)) return arr.map(x => (x && (x.text || x.content)) || "").join("\n");
  return "";
}


/**
 * 结构性关键项（2026-11-22 第 18 轮）
 *
 * 加这一层的直接原因：同一段需求连跑多次，模型的下限差距很大——有时六卡齐全、
 * 电话清楚，有时只画三张卡、把电话整个省掉。数字校验只能发现「规格被改写」，
 * 发现不了「整块内容没画」，所以需要一组结构项来判断这张图能不能交付。
 *
 * 只抽契约里带明确标记的字段（主标题「」/ 署名「」/ 报价「」），不猜。
 */
function structuralOf(sources) {
  const text = Array.isArray(sources) ? sources.filter(Boolean).join("\n") : String(sources || "");
  const quoted = seg => [...seg.matchAll(/「([^」]{1,40})」/g)].map(m => m[1].trim());

  // 主标题：契约里带「主标题」标记
  const tm = /主标题「([^」]{2,24})」/.exec(text);
  const title = tm ? tm[1].trim() : "";

  // 底部信息带：契约独立成段，电话与署名都在这一段里
  const footSeg = text.includes("底部信息带") ? text.split("底部信息带")[1] : "";
  const footQuoted = quoted(footSeg);
  const contact = footQuoted.find(v => /热线|电话|\d{7,}/.test(v)) || "";
  const footer = footQuoted.find(v => v !== contact) || "";

  // 产品名：产品卡一行是「名称」「价格」「说明」，只取每行第一个引号串
  const cardSeg = text.includes("产品卡") ? text.split("产品卡")[1].split("要点区")[0] : "";
  const names = [];
  for (const line of cardSeg.split("\n")) {
    const q = quoted(line);
    const name = q[0] || "";
    if (!name || /^[¥￥$]/.test(name) || !/[\u4e00-\u9fa5]/.test(name)) continue;
    if (!names.includes(name)) names.push(name);
  }

  // 署名叫比对用品牌词：OCR 常常只抄「麦禾堂」，不会连英文和地址一起抄，
  // 整串比对必然误报，所以只取第一段中文品牌名。
  const footerKey = (footer.match(/[\u4e00-\u9fa5]{2,8}/) || [""])[0];

  return { title, contact, footer, footerKey, names: names.slice(0, 10) };
}

function checkStructural(items, ocrText) {
  const hay = normalize(ocrText);
  const hayDigits = hay.replace(/[^0-9]/g, "");
  const miss = [];
  const has = v => {
    if (!v) return true;
    if (hay.includes(normalize(v))) return true;
    const d = String(v).replace(/[^0-9]/g, "");
    return d.length >= 4 && hayDigits.includes(d);
  };
  if (items.title && !has(items.title)) miss.push({ kind: "title", value: items.title });
  if (items.contact && !has(items.contact)) miss.push({ kind: "contact", value: items.contact });
  const footerKey = items.footerKey || items.footer;
  if (footerKey && !has(footerKey)) miss.push({ kind: "footer", value: footerKey });
  // 产品名缺失 1/3 就算硬伤（2026-11-22 实测校准）：
  // 六款产品只画四款时用户一眼就看出少了，但按「过半」判不触发重跑，废图直接发出去。
  // 缺一个算容量波动，缺两个就是结构塌了，重跑一次的收益远大于让用户重来。
  const names = items.names || [];
  const lost = names.filter(n => !has(n));
  const lostThreshold = Math.max(2, Math.ceil(names.length / 3));
  if (names.length >= 4 && lost.length >= lostThreshold) {
    miss.push({ kind: "names", value: lost.slice(0, 4).join("、"), lost: lost.length, total: names.length });
  }
  return { checked: names.length + 3, missing: miss };
}

module.exports = { tokensOf, normalize, check, structuralOf, checkStructural, transcribe, OCR_PROMPT, DIGIT_TOKEN };
