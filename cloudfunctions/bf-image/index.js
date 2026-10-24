/**
 * bf-image：独立生图云函数（正式版）
 *
 * 为什么独立：实测 bf-api 的 /api/image 路径在网关层有特殊策略——同代码在
 * /api/test-upstream 稳定 39s，在 /api/image 超时 >320s；新函数新路由 /img/image 正常（25-42s）。
 *
 * 能力：文生图 / 图生图编辑（服务端强制五段式约束）、鉴权、限流、按次记账。
 * 依赖：@cloudbase/node-sdk（与 bf-api 共用同一套 DB 与 tokenSecret）。
 */
const http = require("http");
const crypto = require("crypto");
const tcb = require("@cloudbase/node-sdk");
const jpeg = require("jpeg-js");
const { PNG } = require("pngjs");

// 懒加载：模块顶层 init 在部分运行时会导致实例初始化失败（443），改到首次使用时初始化
let __APP = null;
let __db = null;
function getDb() {
  if (!__db) {
    __APP = tcb.init({ env: process.env.TCB_ENV });
    __db = __APP.database();
  }
  return __db;
}

const PORT = 9000;   // 云函数 HTTP 固定 9000（不要读 process.env.PORT，SCF 可能注入其他值）
const IMAGE_BASE = "https://ark.cn-beijing.volces.com/api/v3";

// ── 10-23：运行时配置统一入口 ─────────────────────────────────────────────
// 此前 bf-image 只读 process.env，并把 optimize_prompt_options 硬编码成 fast；
// 管理端改的是 bf-api 的 bf_config/runtime，于是"管理端显示已生效，实际出图没变"。
// 现在与 bf-api 读同一份 bf_config/runtime（30s TTL），DB 异常时沿用当前值，不影响出图。
const RT = {
  IMAGE_MODEL: process.env.IMAGE_MODEL || "doubao-seedream-5-0-pro-260628",
  IMAGE_FAST_MODE: process.env.IMAGE_FAST_MODE || "1",
  IMAGE_PROMPT_ENHANCE: process.env.IMAGE_PROMPT_ENHANCE || "1",
  IMAGE_SIZE: process.env.IMAGE_SIZE || "1.5K",
  IMAGE_PRICE_SMALL: process.env.IMAGE_PRICE_SMALL || "0.45",
  IMAGE_PRICE_2K: process.env.IMAGE_PRICE_2K || "0.80",
  RATE_IMAGE_PER_HOUR: process.env.RATE_IMAGE_PER_HOUR || "120",
  IMAGE_API_KEY: process.env.IMAGE_API_KEY || "",
  CHAT_API_KEY: process.env.CHAT_API_KEY || "",
  CHAT_BASE_URL: process.env.CHAT_BASE_URL || "",
  CHAT_MODEL_UTILITY_LITE: process.env.CHAT_MODEL_UTILITY_LITE || "",
};
// 注意：IMAGE_API_KEY 是主链路密钥，只认环境变量，**不参与** DB 覆盖——
// 避免 bf_config 里遗留的旧值把线上出图整体打挂。其余为非敏感调参项，可从 DB 覆盖。
const RT_KEYS = [
  "IMAGE_MODEL", "IMAGE_FAST_MODE", "IMAGE_PROMPT_ENHANCE", "IMAGE_SIZE",
  "IMAGE_PRICE_SMALL", "IMAGE_PRICE_2K", "RATE_IMAGE_PER_HOUR",
  "CHAT_API_KEY", "CHAT_BASE_URL", "CHAT_MODEL_UTILITY_LITE",
];
let _rtLoadedAt = 0;

/** 与 bf-api 同源拉取运行时配置；失败不抛、沿用当前值。 */
async function refreshRuntime() {
  if (Date.now() - _rtLoadedAt < 30000) return;
  _rtLoadedAt = Date.now();
  try {
    const r = await getDb().collection(C.config).doc("runtime").get();
    const doc = (r && r.data && r.data[0]) || null;
    if (doc && doc.data) {
      for (const k of RT_KEYS) {
        const v = doc.data[k];
        if (v !== undefined && v !== null && v !== "") RT[k] = v;
      }
    }
  } catch (e) { /* DB 异常：沿用当前值 */ }
}

// 单价与官方成本对齐（2026-10-21 核实：1.5K 及以下 0.30/张，2K 0.60/张）
// 支持 "2K" 档位与 "1536x1024" 显式像素两种写法，按实际像素判价，避免高分辨率按低价记账。
function priceForSize(size) {
  const s = String(size || RT.IMAGE_SIZE || "1.5K").toUpperCase();
  if (s === "2K") return Number(RT.IMAGE_PRICE_2K);
  const m = /^(\d+)\s*[X×]\s*(\d+)$/.exec(s);
  if (m) {
    const px = Number(m[1]) * Number(m[2]);
    return px > 2360000 ? Number(RT.IMAGE_PRICE_2K) : Number(RT.IMAGE_PRICE_SMALL);
  }
  return Number(RT.IMAGE_PRICE_SMALL);
}

const C = { accounts: "bf_accounts", usage: "bf_usage_logs", config: "bf_config" };

// ── 鉴权（与 bf-api 同一套 HMAC token）──
let SECRETS = null;
async function loadSecrets() {
  if (SECRETS) return SECRETS;
  if (process.env.TOKEN_SECRET) {
    SECRETS = { tokenSecret: process.env.TOKEN_SECRET };
    return SECRETS;
  }
  try {
    const r = await getDb().collection(C.config).doc("secrets").get();
    const doc = (r && r.data && r.data[0]) || null;
    if (doc && doc.tokenSecret) SECRETS = { tokenSecret: doc.tokenSecret };
  } catch (e) {
    SECRETS = null;
  }
  return SECRETS;
}

function bearer(req) {
  const raw = req.headers["authorization"] || "";
  return raw.startsWith("Bearer ") ? raw.slice(7).trim() : "";
}

function verifyToken(token, secret) {
  if (!token || !secret || token.indexOf(".") < 0) return null;
  const parts = token.split(".");
  if (parts.length !== 2) return null;
  const body = parts[0];
  const sig = parts[1];
  const expect = crypto.createHmac("sha256", secret).update(body).digest("base64url");
  const a = Buffer.from(sig);
  const b = Buffer.from(expect);
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return null;
  try {
    const payload = JSON.parse(Buffer.from(body, "base64url").toString("utf8"));
    if (!payload.exp || Date.now() > payload.exp) return null;
    return payload;
  } catch (e) {
    return null;
  }
}

async function requireMember(req) {
  const secrets = await loadSecrets();
  if (!secrets) return null;
  const payload = verifyToken(bearer(req), secrets.tokenSecret);
  if (!payload || payload.t !== "member") return null;
  return payload;
}

// ── 结构化日志：每次请求一条可检索的 JSON，排障不再靠猜 ──
function logStage(stage, extra) {
  try {
    console.log(JSON.stringify(Object.assign({ ts: new Date().toISOString(), fn: "bf-image", stage }, extra || {})));
  } catch (e) { /* 日志失败不影响主流程 */ }
}

// ── 额度拦截：向 bf-api /me 查剩余百分比（复用唯一真相，避免两处各算一套）──
const BF_API_BASE = process.env.BF_API_BASE || "https://xmy-test-d5g8c0xcifcefcfd5-1449098021.ap-shanghai.app.tcloudbase.com/api";
async function quotaExhausted(req) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), 4000);
  try {
    const r = await fetch(BF_API_BASE + "/me", {
      headers: { Authorization: "Bearer " + bearer(req) },
      signal: ctrl.signal,
    });
    const j = await r.json().catch(() => null);
    const month = j && j.limits && j.limits.month;
    const pct = month && month.remainingPct;
    const usedCny = j && j.usage && j.usage.pool && j.usage.pool.usedCny;
    const capCny = j && j.usage && j.usage.pool && j.usage.pool.capCny;
    if (month && month.enabled && typeof pct === "number" && pct <= 0) {
      return { exhausted: true, resetAt: month.resetAt || null, usedCny, capCny };
    }
    return { exhausted: false, remainingPct: pct, usedCny, capCny };
  } catch (e) {
    // 额度服务不可用时不阻断出图（可用性优先），但留日志便于发现异常
    logStage("quota_check_failed", { err: String((e && e.message) || e).slice(0, 120) });
    return { exhausted: false };
  } finally {
    clearTimeout(timer);
  }
}

// ── 限流（10-23 改为"先原子自增再判超限"）──
// 旧实现是"先读计数 → 比较 → 再写 count+1"，N 个并发请求会同时读到旧值、同时放行。
// 现在先 inc 再读回：自增本身是原子操作，超限请求会被稳定拦下（代价是超限也计 1 次，
// 但只影响被拒请求，不会让用户白白消耗额度）。
const RATE_COLL = "bf_rate";
async function claimRate(accountId) {
  const limit = Number(RT.RATE_IMAGE_PER_HOUR || 0);
  if (!(limit > 0)) return null;
  const bucket = Math.floor(Date.now() / 3600000);
  const id = `${accountId}_${bucket}`;
  try {
    const col = getDb().collection(RATE_COLL);
    const cmd = getDb().command;
    let updated = 0;
    try {
      const res = await col.doc(id).update({ count: cmd.inc(1), updatedAt: Date.now() });
      updated = Number((res && (res.updated ?? res.updatedCount)) || 0);
    } catch (e) { updated = 0; }
    if (!updated) {
      try {
        await col.doc(id).set({ windowStart: Date.now(), bucket, count: 1, updatedAt: Date.now() });
      } catch (e) {
        // 并发创建撞车：说明文档已存在，补一次自增
        try { await col.doc(id).update({ count: cmd.inc(1), updatedAt: Date.now() }); } catch (e2) { /* 忽略 */ }
      }
    }
    const r = await col.doc(id).get().catch(() => null);
    const n = Number((r && r.data && r.data[0] && r.data[0].count) || 0);
    if (n > limit) return `生图太频繁（本小时上限 ${limit} 张），请稍后再试`;
    return null;
  } catch (e) {
    return null;   // 限流基础设施异常不阻断出图（可用性优先）
  }
}

// ── 记账（写 accounts 累计 + usage_logs 明细，与 bf-api 同表）──
async function addImageCost(accountId, costCny, meta) {
  try {
    await getDb().collection(C.accounts).doc(accountId).update({
      imageUsedCny: getDb().command.inc(Math.max(0, costCny)),
      dayUsedCny: getDb().command.inc(Math.max(0, costCny)),
      weekUsedCny: getDb().command.inc(Math.max(0, costCny)),
    });
  } catch (e) { /* 累计失败不阻断出图 */ }
  const row = { accountId, kind: "image", costCny, ts: new Date(), model: meta.model, estimated: false, source: "bf-image" };
  try { await getDb().collection(C.usage).add(row); }
  catch (e) { try { await getDb().collection(C.usage).add(row); } catch (e2) { /* 忽略 */ } }
}

// ── 幂等 + 任务台账（10-23 改为"原子占位"模型）──
// 旧实现：先查缓存 → 生成 → 写缓存。两个并发同 requestId 请求会同时未命中、各生成一次、各扣一次费。
// 现在用 bf_image_jobs 的 _id 抢占：add(_id=rid) 成功才算拿到执行权，重复请求直接复用或返回进行中。
const IDEM_TTL_MS = 5 * 60 * 1000;
const JOB_COLL = "bf_image_jobs";
async function claimIdem(rid, accountId) {
  if (!rid) return { state: "none" };
  const col = getDb().collection(JOB_COLL);
  try {
    await col.add({ _id: rid, state: "processing", accountId, ts: Date.now() });
    return { state: "new" };
  } catch (e) {
    try {
      const r = await col.doc(rid).get();
      const d = (r && r.data && r.data[0]) || null;
      if (d && d.state === "done" && d.url && Date.now() - Number(d.ts || 0) < IDEM_TTL_MS) {
        return { state: "done", url: d.url };
      }
      // 90 秒内仍是 processing：判为并发重复，不重复生成
      if (d && d.state === "processing" && Date.now() - Number(d.ts || 0) < 90 * 1000) {
        return { state: "busy" };
      }
      // 失败或超时：接管这条任务
      await col.doc(rid).set({ state: "processing", accountId, ts: Date.now(), retried: true });
      return { state: "new" };
    } catch (e2) {
      return { state: "none" };   // 台账不可用时不阻断出图
    }
  }
}
async function finishIdem(rid, accountId, url, costCny, model) {
  if (!rid) return;
  try {
    await getDb().collection(JOB_COLL).doc(rid).update({
      state: "done", url, costCny, model, accountId,
      ts: Date.now(), costCommitted: false,
    });
  } catch (e) { /* 台账写失败不影响本次结果 */ }
}
async function abortIdem(rid, reason) {
  if (!rid) return;
  try { await getDb().collection(JOB_COLL).doc(rid).update({ state: "failed", reason: String(reason || "").slice(0, 120), ts: Date.now() }); } catch (e) { /* 忽略 */ }
}

/// 记账补投（outbox）：已完成但未记账的任务，下次请求时补记，最多 3 条，避免长期漏账。
async function flushJobs() {
  try {
    const col = getDb().collection(JOB_COLL);
    const r = await col.where({ state: "done", costCommitted: false }).limit(3).get();
    for (const d of (r && r.data) || []) {
      const id = d._id || d.id;
      if (!id) continue;
      await addImageCost(d.accountId, Number(d.costCny || 0), { model: d.model || "unknown" });
      await col.doc(id).update({ costCommitted: true, committedAt: Date.now() }).catch(() => {});
    }
  } catch (e) { /* outbox 失败不影响主流程 */ }
}

// ── 编辑结果廉价自检：像素级比对原图与结果图，抓「整图重绘」（0 token / <100ms）──
function decodeImage(buf) {
  if (!buf || buf.length < 8) return null;
  try {
    if (buf[0] === 0xFF && buf[1] === 0xD8) return jpeg.decode(buf, { useTArray: true });
    if (buf[0] === 0x89 && buf[1] === 0x50) return PNG.sync.read(buf);
  } catch (e) { /* 解码失败视为无法判断 */ }
  return null;
}

function thumbGray(img, n) {
  const size = n || 24;
  const width = img.width, height = img.height;
  const ch = img.channels || 4;
  const data = img.data;
  const out = new Array(size * size).fill(0);
  for (let gy = 0; gy < size; gy++) {
    for (let gx = 0; gx < size; gx++) {
      const sx = Math.min(width - 1, Math.floor((gx + 0.5) * width / size));
      const sy = Math.min(height - 1, Math.floor((gy + 0.5) * height / size));
      const i = (sy * width + sx) * ch;
      out[gy * size + gx] = data[i] * 0.299 + data[i + 1] * 0.587 + data[i + 2] * 0.114;
    }
  }
  return out;
}

function graySimilarity(a, b) {
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff += Math.abs(a[i] - b[i]);
  return Math.max(0, 1 - (diff / a.length) / 255);
}

async function fetchBinary(url, timeoutMs) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeoutMs || 8000);
  try {
    const r = await fetch(url, { signal: ctrl.signal });
    if (!r.ok) return null;
    return Buffer.from(await r.arrayBuffer());
  } catch (e) {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

/** 返回 0~1 相似度；无法判断时返回 null（不阻断主流程） */
async function editSimilarity(sourceRef, resultUrl) {
  try {
    const src = String(sourceRef || "");
    const srcBuf = src.startsWith("data:") ? Buffer.from(src.split(",")[1] || "", "base64") : await fetchBinary(src, 8000);
    const outBuf = await fetchBinary(resultUrl, 8000);
    const a = decodeImage(srcBuf), b = decodeImage(outBuf);
    if (!a || !b) return null;
    return graySimilarity(thumbGray(a, 24), thumbGray(b, 24));
  } catch (e) {
    return null;
  }
}

// ── 生图（服务端强制五段式约束）──
const EDIT_CONSTRAINTS =
  "\n\n【一致性】光照方向、色温、景深与透视必须与原图完全一致；\n" +
  "【阴影】新增或替换的主体必须在地面或相邻物体上产生与现有光照方向一致的接触阴影，阴影软硬程度与原图匹配；\n" +
  "【保持】原图的构图、人物、背景、色调、光线和所有文字必须完全不变，画面其余部分保持原样；\n" +
  "【排除】禁止抠图感、悬浮、生硬粘贴；不要添加任何未提及的元素；不要出现水印或额外文字。";

function readBody(req) {
  return new Promise((resolve) => {
    let data = "";
    let done = false;
    req.on("data", (c) => {
      if (done) return;
      data += c;
      if (data.length > 20 * 1024 * 1024) {
        done = true;
        try { req.destroy(); } catch (e) { /* ignore */ }
        resolve(null);
      }
    });
    req.on("end", () => {
      if (done) return;
      try { resolve(JSON.parse(data || "{}")); } catch (e) { resolve(null); }
    });
    req.on("error", () => resolve(null));
  });
}

/** 结构化字段 → 专业 prompt（字段顺序固定，内容全部来自模型对用户需求的理解） */
function assembleStructured(structured) {
  if (!structured || typeof structured !== "object") return "";
  const order = ["subject", "setting", "composition", "lighting", "material", "text", "negative"];
  const parts = order.map((k) => String(structured[k] || "").trim()).filter(Boolean);
  if (!parts.length) return "";
  return parts.join("。") + "。";
}

/** 显式宽高比 → 1.5K 档位的画布像素（与 1K 同价区间，避免动辄 2K 计费） */
const ASPECT_SIZES = {
  "1:1": "1024x1024",
  "3:4": "1152x1536",
  "4:3": "1536x1152",
  "9:16": "864x1536",
  "16:9": "1536x864",
  "1.7:1": "1536x904",   // 横版名片常用比例
};
function resolveSize(size, aspectRatio) {
  const ar = String(aspectRatio || "").trim();
  if (ar && ASPECT_SIZES[ar]) return ASPECT_SIZES[ar];
  const s = String(size || RT.IMAGE_SIZE || "1.5K").trim();
  return /^(\d+\s*[xX×]\s*\d+|1K|1\.5K|2K)$/i.test(s) ? s.toUpperCase() : "1.5K";
}

/** 出图形态：决定是"可直接印刷的平面稿"还是"带场景的展示稿"。
 *  名片/海报/封面被画成"白纸上的一张卡片"，通常就是缺了 flat_artwork 这条约束。 */
const RENDER_INTENT_RULES = {
  flat_artwork:
    "【输出形态：平面成稿】直接输出可交付的平面设计稿：设计内容填满整张画布并按比例留出安全边距；" +
    "禁止出现桌面、台面、纸张、相框、手部、投影、展厅等外部展示场景；" +
    "禁止在作品外围添加白色或浅色衬底/外边框；不要把作品再画成『放在白纸上的一张图』。",
  mockup:
    "【输出形态：展示稿】允许把作品置于真实场景（桌面、纸张、材质、环境光）中展示，保留合理投影与景深。",
};

/** 模型没传 render_intent 时的兜底：印刷类物料默认走平面成稿，避免再生成"白纸上的名片"。 */
function inferRenderIntent(text) {
  const p = String(text || "");
  if (/名片|海报|封面|传单|宣传单|易拉宝|展架|证书|logo|标志|门头|菜单|包装|贴纸/i.test(p)) return "flat_artwork";
  return "";
}

/** 生图提示词增强：仅在配置了 CHAT_API_KEY 与轻量模型时启用，失败原样返回（增强不是依赖）。 */
async function enhancePrompt(raw) {
  const key = String(RT.CHAT_API_KEY || "");
  const model = String(RT.CHAT_MODEL_UTILITY_LITE || "");
  if (!key || !model) return raw;   // 不猜模型名：未配置就跳过
  const base = String(RT.CHAT_BASE_URL || IMAGE_BASE).replace(/\/+$/, "");
  const sys = "你是资深视觉设计师与 AI 生图提示词工程师。把用户需求改写为高质量生图提示词：" +
    "①保留原意与所有指定细节（文字/品牌名/数字/颜色原样保留，不得改动）" +
    "②按需补全构图、光影、材质、色彩、画质，宁少勿滥" +
    "③只输出改写后的提示词本身，不要解释，长度 120-280 字。";
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 20000);
  try {
    const r = await fetch(base + "/chat/completions", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: "Bearer " + key },
      body: JSON.stringify({ model, messages: [{ role: "system", content: sys }, { role: "user", content: raw }], max_tokens: 500, temperature: 0.7 }),
      signal: controller.signal,
    });
    if (!r.ok) return raw;
    const j = await r.json().catch(() => null);
    const out = j && j.choices && j.choices[0] && j.choices[0].message && j.choices[0].message.content;
    const text = typeof out === "string" ? out.trim() : "";
    return text.length >= 30 ? text : raw;
  } catch (e) {
    return raw;
  } finally {
    clearTimeout(timer);
  }
}

async function generate({ prompt, image, size, structured, renderIntent, aspectRatio, layerDecomposition }) {
  const apiKey = String(RT.IMAGE_API_KEY || "");
  if (!apiKey) return { ok: false, code: 503, msg: "IMAGE_API_KEY 未配置" };

  // 文生图：优先用结构化字段拼装（A 方案）；编辑：在用户指令后叠加五段式约束
  const structPrompt = assembleStructured(structured);
  let basePrompt = structPrompt || String(prompt || "");
  const isEdit = !!image;

  // 10-23：structured 非空时不再直接丢弃原始 prompt——用户硬约束（联系方式、指定文字、禁止项）
  // 往往只写在 prompt 里，丢掉就会让模型自由发挥。两条都保留，去重后拼接。
  if (structPrompt && String(prompt || "").trim()) {
    const raw = String(prompt).trim();
    if (!structPrompt.includes(raw)) basePrompt = raw + "。" + structPrompt;
  }

  // 短提示词增强：只对"纯文生图 + 无结构化字段 + 描述很短"的场景生效，避免拖慢精确改图。
  if (!isEdit && !structPrompt && RT.IMAGE_PROMPT_ENHANCE === "1" && basePrompt.length > 0 && basePrompt.length < 120) {
    basePrompt = await enhancePrompt(basePrompt);
  }

  const intentRule = RENDER_INTENT_RULES[String(renderIntent || "") || inferRenderIntent(basePrompt)] || "";
  if (intentRule) basePrompt = basePrompt + "\n\n" + intentRule;
  const finalPrompt = isEdit ? basePrompt + EDIT_CONSTRAINTS : basePrompt;

  const resolvedSize = resolveSize(size, aspectRatio);
  const mode = String(RT.IMAGE_FAST_MODE) === "0" ? "standard" : "fast";
  const payload = {
    model: String(RT.IMAGE_MODEL || "doubao-seedream-5-0-pro-260628"),
    prompt: finalPrompt,
    size: resolvedSize,
    response_format: "url",
    watermark: false,
    optimize_prompt_options: { mode },
  };
  if (image) payload.image = image;
  // 10-23 图层拆分（Seedream 5.0 pro 原生能力）：仅支持 1 张图，返回底图 + 最多 16 个透明 PNG 图层
  // 注意：此前这行误写在 generate() 里却引用外层 body，会直接抛 ReferenceError；改为显式入参。
  if (layerDecomposition === true) payload.layer_decomposition = true;

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 280000);   // 与云端 APP_IMAGE_TIMEOUT=300 对齐
  try {
    const r = await fetch(IMAGE_BASE + "/images/generations", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: "Bearer " + apiKey },
      body: JSON.stringify(payload),
      signal: controller.signal,
    });
    const j = await r.json().catch(() => null);
    const url = j && j.data && j.data[0] && j.data[0].url;
    if (!r.ok || !url) {
      return { ok: false, code: 502, msg: "上游失败", status: r.status, detail: JSON.stringify(j).slice(0, 300) };
    }
    return { ok: true, url };
  } catch (e) {
    return { ok: false, code: 504, msg: String((e && e.message) || e).slice(0, 200) };
  } finally {
    clearTimeout(timer);
  }
}

// ── HTTP 服务 ──
const server = http.createServer(async (req, res) => {
  const send = (code, obj) => {
    res.writeHead(code, { "Content-Type": "application/json; charset=utf-8" });
    res.end(JSON.stringify(obj));
  };

  const u = String(req.url || "");

  if (req.method === "GET" && u.indexOf("/ping") >= 0) {
    return send(200, { ok: true, fn: "bf-image" });
  }

  if (req.method === "POST" && u.indexOf("/image") >= 0) {
    const t0 = Date.now();

    const tReq = Date.now();
    logStage("request_in", { ua: String(req.headers["user-agent"] || "").slice(0, 60) });

    // 10-23：先同步一次运行时配置（30s TTL，通常无网络开销），
    // 让管理端改的模型/尺寸/价格/提速模式对这条路径真正生效。
    await refreshRuntime();

    const auth = await requireMember(req);
    if (!auth) { logStage("auth_fail"); return send(401, { ok: false, code: 401, error: "UNAUTHORIZED", msg: "请重新登录" }); }

    // 记账补投：上次已完成但未记账的任务在这里补上（最多 3 条）
    await flushJobs();

    const q = await quotaExhausted(req);
    if (q.exhausted) {
      logStage("quota_exhausted", { sub: auth.sub });
      return send(429, { ok: false, code: 429, error: "POOL_EXHAUSTED", msg: "本月额度已用完，续费后立即恢复。", resetAt: q.resetAt });
    }

    let body = null;
    try { body = await readBody(req); } catch (e) { body = null; }
    if (!body) return send(400, { ok: false, code: 400, error: "BAD_REQUEST", msg: "请求体解析失败" });

    const prompt = String(body.prompt || "").trim();
    const hasStructured = !!(body.structured && typeof body.structured === "object" && Object.keys(body.structured).length);

    // 幂等占位：add(_id=rid) 成功才拿到执行权；重复请求复用结果或返回"进行中"。
    const rid = String(body.requestId || "").slice(0, 64);
    const claim = await claimIdem(rid, auth.sub);
    if (claim.state === "done") {
      logStage("idempotent_hit", { sub: auth.sub, rid });
      return send(200, { ok: true, url: claim.url, cached: true, cost: 0, ms: Date.now() - tReq });
    }
    if (claim.state === "busy") {
      logStage("idempotent_busy", { sub: auth.sub, rid });
      return send(409, { ok: false, code: 409, error: "IN_PROGRESS", msg: "同一张图还在生成中，请稍候再试" });
    }
    if (!prompt && !hasStructured) { await abortIdem(rid, "missing_prompt"); return send(400, { ok: false, code: 400, error: "BAD_REQUEST", msg: "缺少 prompt" }); }
    if (prompt.length > 1500) { await abortIdem(rid, "prompt_too_long"); return send(400, { ok: false, code: 400, error: "BAD_REQUEST", msg: "描述过长，请精简到 1500 字以内" }); }

    // 限流：原子自增后判超限；被拒时释放占位，允许用户稍后重试同一个 requestId
    const rl = await claimRate(auth.sub);
    if (rl) {
      logStage("rate_limited", { sub: auth.sub });
      await abortIdem(rid, "rate_limited");
      return send(429, { ok: false, code: 429, error: "RATE_LIMITED", msg: rl });
    }
    const renderIntent = String(body.render_intent || body.renderIntent || "");
    const aspectRatio = String(body.aspect_ratio || body.aspectRatio || "");
    let out = await generate({
      prompt: body.prompt, image: body.image, size: body.size, structured: body.structured,
      renderIntent, aspectRatio, layerDecomposition: body.layer_decomposition === true,
    });

    let retried = false;
    // 编辑场景：像素相似度 < 0.60 判定「整图重绘」，自动重试一次（0 token，仅 +一次生成）
    if (out.ok && body.image) {
      const sim = await editSimilarity(Array.isArray(body.image) ? body.image[0] : body.image, out.url);
      if (sim !== null) {
        logStage("edit_similarity", { sim: Number(sim.toFixed(3)) });
        if (sim < 0.60) {
          logStage("edit_over_redraw_retry", { sim: Number(sim.toFixed(3)) });
          const retry = await generate({
            prompt: String(body.prompt || "") + "\n\n【重要】仅修改用户指定的区域，画面其余部分必须与原图逐像素保持一致，禁止整体重绘。",
            image: body.image, size: body.size, structured: body.structured,
            renderIntent, aspectRatio, layerDecomposition: body.layer_decomposition === true,
          });
          if (retry.ok) {
            const sim2 = await editSimilarity(Array.isArray(body.image) ? body.image[0] : body.image, retry.url);
            if (sim2 === null || sim2 > sim) { out = retry; retried = true; }
            logStage("edit_retry_result", { sim2: sim2 === null ? null : Number(sim2.toFixed(3)), adopted: out === retry });
          }
        }
      }
    }
    logStage("generate_done", { sub: auth.sub, ok: !!out.ok, hadImage: !!body.image, size: body.size, ms: Date.now() - tReq, err: out.ok ? undefined : String(out.msg || "").slice(0, 120) });

    if (out.ok) {
      const price = priceForSize(resolveSize(body.size, aspectRatio));
      // 先落台账（含成本），再由 outbox 补投记账：即使这里崩溃，下次请求也会补记，不会漏账。
      await finishIdem(rid, auth.sub, out.url, price, RT.IMAGE_MODEL);
      await flushJobs();
      return send(200, { ok: true, url: out.url, ms: Date.now() - t0, hadImage: !!body.image, cost: price, retried, size: resolveSize(body.size, aspectRatio), renderIntent: renderIntent || "default" });
    }
    await abortIdem(rid, out.msg);
    return send(out.code || 502, Object.assign({ ms: Date.now() - t0, hadImage: !!body.image }, out));
  }

  return send(404, { ok: false, msg: "not found" });
});

server.listen(PORT, () => console.log("[bf-image] listening on " + PORT));
