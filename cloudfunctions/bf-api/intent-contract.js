"use strict";

/**
 * 前置意图契约（Intent Contract）
 *
 * 解决的问题：模型每一轮都要重新猜「横版还是竖版、要不要重绘、必须带什么」，
 * 于是同一个需求能出 0.845 / 0.75 / 4.1:1 三种比例。
 *
 * 做法：在生图参数定稿（finalizeImageCalls）之前，把
 *   ① 用户本轮原话 ② 最近几轮对话 ③ 长期记忆
 * 里的硬约束抽出来，做两件事：
 *   - 返回一段极短的 system 提示，让模型自己就按这个计划（不是写死画面）
 *   - 对模型给出的 tool_calls 做**确定性校正**（比例冲突才改，不冲突不动）
 *
 * 原则：只校正「用户明确说过」或「记忆里明确写过」的项；没有依据一律不动。
 * 不编造文案、不编造号码、不改 prompt 的创作内容。
 */

const ORIENT = {
  portrait: /竖版|竖向|竖屏|竖图|立式|纵向/,
  landscape: /横版|横向|横屏|横图|横幅|宽幅/,
};
const RATIO = /(\d{1,2}(?:\.\d+)?)\s*[:：]\s*(\d{1,2}(?:\.\d+)?)/g;
// 400/800 热线、固话、手机号；只认用户或记忆里真正出现过的
const CONTACT = /(?:400|800)[-\s]?\d{3,4}[-\s]?\d{3,4}|0\d{2,3}[-\s]?\d{7,8}|1[3-9]\d{9}/;

/** 把「不要横版」这类否定说法先规范化，避免竖/横互相抵消 */
function normalizeDirection(src) {
  return String(src || "").replace(
    /(?:不要|别|不是|拒绝|无需|不用)[^，。；\n]{0,4}?(横版|横向|横屏|横图|竖版|竖向|竖屏|竖图)/g,
    (m, kw) => (/^横/.test(kw) ? "竖版" : "横版")
  );
}

function textOf(message) {
  const c = message && message.content;
  if (typeof c === "string") return c;
  if (Array.isArray(c)) return c.filter(p => p && p.type === "text").map(p => p.text || "").join("\n");
  return "";
}

function ratioValue(text) {
  RATIO.lastIndex = 0;
  const m = RATIO.exec(String(text || ""));
  if (!m) return null;
  const a = Number(m[1]), b = Number(m[2]);
  if (!(a > 0 && b > 0)) return null;
  const v = a / b;
  return v >= 0.25 && v <= 4 ? { label: `${m[1]}:${m[2]}`, value: v } : null;
}

/**
 * 解析意图。
 * @param {{messages:Array, memories:Array<string>}} input
 */
function resolve({ messages = [], memories = [] } = {}) {
  const users = messages.filter(m => m && m.role === "user");
  const recent = users.slice(-3).map(textOf).filter(Boolean);
  const latest = recent[recent.length - 1] || "";
  const memoryText = memories.filter(t => typeof t === "string" && t).join("\n");

  // 比例：本轮原话 > 最近几轮 > 记忆（越新的越优先）
  let ratio = null, ratioSource = "";
  for (const src of [latest, ...recent.slice(0, -1).reverse(), memoryText]) {
    const r = ratioValue(src);
    if (r) { ratio = r; ratioSource = "explicit"; break; }
  }

  // 方向：同上，取最新一次明确表述
  let orientation = null, orientSource = "";
  for (const raw of [latest, ...recent.slice(0, -1).reverse(), memoryText]) {
    const src = normalizeDirection(raw);
    const p = ORIENT.portrait.test(src), l = ORIENT.landscape.test(src);
    if (p && !l) { orientation = "portrait"; orientSource = "explicit"; break; }
    if (l && !p) { orientation = "landscape"; orientSource = "explicit"; break; }
  }
  if (!orientation && ratio) orientation = ratio.value >= 1 ? "landscape" : "portrait";

  // 联系方式：优先本轮给过的，其次近几轮，最后记忆
  let contact = "";
  for (const src of [latest, ...recent.slice(0, -1).reverse(), memoryText]) {
    const m = CONTACT.exec(src);
    if (m) { contact = m[0].replace(/\s+/g, ""); break; }
  }

  // 公司全称：从记忆里取最长的「…有限公司」，没有就留空（不编造）
  let company = "";
  const names = memoryText.match(/[\u4e00-\u9fa5（）()·]{2,30}有限公司/g) || [];
  if (names.length) company = names.sort((a, b) => b.length - a.length)[0];

  // 任务性质：重绘/重新设计 vs 只加元素
  const redesign = /重(?:新)?(?:设)?计|重绘|重做|再设计|改版|美化|提升美观|重新生成一版|做成海报|做一张海报/.test(latest);
  const additive = /只(?:要|需)?(?:加|贴|放)|基础(?:之)?上(?:直接)?(?:加|增)|不改(?:动)?(?:原|底)图|保持原图/.test(latest);

  return {
    orientation, orientSource, ratio, ratioSource, contact, company,
    redesign, additive,
    hasAny: !!(orientation || contact || company),
  };
}

/** 按文字量给一个与方向相符的默认比例（只在模型给的比例与方向冲突时使用） */
function fallbackRatio(intent, blocks) {
  const chars = Array.isArray(blocks)
    ? blocks.reduce((n, b) => n + String((b && b.text) || "").replace(/\s/g, "").length, 0)
    : 0;
  if (intent.orientation === "landscape") return chars > 600 ? "16:9" : "4:3";
  if (chars > 600) return "9:16";
  if (chars > 260) return "3:4";
  return "4:5";
}

const PLACEHOLDER = /^(?:品牌名称|公司名称|公司名字|待补充|待填写|XXX+|×+|logo|Logo|LOGO|示例|示例文字|您好)$/;

/** 占位文字处理：有公司名就替换，没有就删掉这条，避免"品牌名称"印在成品上 */
function cleanPlaceholders(blocks, company) {
  if (!Array.isArray(blocks)) return { blocks, changed: false };
  let changed = false;
  const out = [];
  for (const b of blocks) {
    const raw = String((b && b.text) || "").trim();
    if (!raw) { out.push(b); continue; }
    const isCompanySlot = /^(?:品牌名称|公司名称|公司名字)$/.test(raw);
    const isPlaceholder = PLACEHOLDER.test(raw) || /待补充|待填写|品牌名称|公司名称/.test(raw);
    if (isCompanySlot) {
      changed = true;
      if (company) out.push({ ...b, text: company });   // 有全称就写实
      continue;                                          // 没有就删掉这条占位
    }
    if (isPlaceholder) { changed = true; continue; }     // 其他占位（待补充/XXX/您好）一律删掉
    out.push(b);
  }
  return { blocks: out, changed };
}

function blocksOf(args) {
  const t = args && args.structured && args.structured.text;
  return Array.isArray(t) ? t : null;
}

function hasContact(blocks, contact) {
  if (!Array.isArray(blocks) || !contact) return false;
  const digits = contact.replace(/\D/g, "");
  return blocks.some(b => String((b && b.text) || "").replace(/\D/g, "").includes(digits));
}

/**
 * 对生图 tool_calls 做确定性校正。
 * @param {Array} calls
 * @param {ReturnType<resolve>} intent
 * @param {(fields:object)=>void} [observe]
 */
function apply(calls, intent, observe) {
  if (!Array.isArray(calls) || !intent) return calls;
  const touched = [];
  const out = calls.map(call => {
    const fn = call && call.function;
    if (!fn || (fn.name !== "image_generate" && fn.name !== "image_edit")) return call;
    let args;
    try { args = JSON.parse(fn.arguments); } catch { return call; }

    const blocks = blocksOf(args);
    let changed = null;

    // ① 比例：只有「方向明显冲突」或「用户明确给了比例但模型没用」才改
    const current = ratioValue(String(args.aspect_ratio || ""));
    const explicit = intent.ratio;
    const wrongDirection = intent.orientation && current &&
      ((intent.orientation === "portrait" && current.value > 1) ||
       (intent.orientation === "landscape" && current.value < 1));
    const missing = !current && (intent.orientation || explicit);
    if (explicit && (!current || Math.abs(current.value - explicit.value) / explicit.value > 0.08)) {
      args.aspect_ratio = explicit.label;
      changed = changed || {};
      changed.aspect_ratio = { from: current ? current.label : "(未给)", to: explicit.label, why: "用户明确指定" };
    } else if (wrongDirection || missing) {
      const to = fallbackRatio(intent, blocks);
      args.aspect_ratio = to;
      changed = changed || {};
      changed.aspect_ratio = { from: current ? current.label : "(未给)", to, why: wrongDirection ? "方向与要求相反" : "未给比例" };
    }

    // ② 占位文字：有公司名就写实，没有就删掉
    if (blocks) {
      const r = cleanPlaceholders(blocks, intent.company);
      if (r.changed) {
        args.structured = { ...(args.structured || {}), text: r.blocks };
        changed = changed || {};
        changed.placeholder = { company: intent.company || "(已删除)" };
      }
    }

    // ③ 联系方式：用户/记忆给过、而模型漏了，就补一条（不改其他文案）
    if (intent.contact && blocks && !hasContact(blocks, intent.contact)) {
      blocks.push({ key: "contact_hotline", role: "contact", text: `全国服务热线 ${intent.contact}` });
      changed = changed || {};
      changed.contact = { added: intent.contact };
    }

    if (!changed) return call;
    touched.push({ tool: fn.name, ...changed });
    return { ...call, function: { ...fn, arguments: JSON.stringify(args) } };
  });

  if (touched.length && typeof observe === "function") {
    try { observe({ tag: "intent_contract_applied", changes: touched }); } catch { /* ignore */ }
  }
  return touched.length ? out : calls;
}

/** 给模型的一段极短计划提示（不进入画面文案） */
function guidance(intent) {
  if (!intent || !intent.hasAny) return "";
  const parts = [];
  if (intent.orientation === "portrait") parts.push("版式必须是竖版（高大于宽）");
  if (intent.orientation === "landscape") parts.push("版式必须是横版（宽大于高）");
  if (intent.ratio) parts.push(`画布比例用 ${intent.ratio.label}`);
  if (intent.contact) parts.push(`必须原样印出全国服务热线 ${intent.contact}`);
  if (intent.company) parts.push(`公司全称是「${intent.company}」`);
  if (!parts.length) return "";
  return [
    `【本轮硬约束】${parts.join("；")}。这些是从用户历史里确认过的要求，不是让你重写画面内容。`,
    "【照抄规则】参考图里已有的栏目名、接口名、型号、参数必须逐字照抄，不得换成近义术语（例如 PGM 接口不能写成 PWM/PoE，多防区接口不能写成多协议接口）；拿不准就保留原图文字。",
    "【禁占位】画面不得出现「品牌名称」「公司名称」「待补充」「XXX」「您好」这类占位或示例文字；已知信息直接写实，未知信息就留空不写字。",
  ].join("\n");
}

module.exports = { resolve, apply, guidance, fallbackRatio, ratioValue, normalizeDirection, cleanPlaceholders, CONTACT };
