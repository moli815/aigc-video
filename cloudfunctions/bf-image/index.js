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

const {
  ALLOWED_FETCH_SUFFIXES, isPrivateHost, safeFetchURL,
  clampExplicitSize, probeImageSize, decodedSizeAllowed, inferQualityTier,
} = require("./media-guards");
const { publicError, CATALOG } = require("./error-catalog");
const { AsyncLocalStorage } = require("async_hooks");
const reqStore = new AsyncLocalStorage();
function currentRequestId() {
  const st = reqStore.getStore();
  return (st && st.requestId) || "";
}

const PORT = 9000;   // 云函数 HTTP 固定 9000（不要读 process.env.PORT，SCF 可能注入其他值）
const IMAGE_BASE = "https://ark.cn-beijing.volces.com/api/v3";

// ── 10-23：运行时配置统一入口 ─────────────────────────────────────────────
// 此前 bf-image 只读 process.env，并把 optimize_prompt_options 硬编码成 fast；
// 管理端改的是 bf-api 的 bf_config/runtime，于是"管理端显示已生效，实际出图没变"。
// 现在与 bf-api 读同一份 bf_config/runtime（30s TTL），DB 异常时沿用当前值，不影响出图。
const RT = {
  // 10-24 混合路由：三个档位分开配置。IMAGE_MODEL 保留为兼容别名（等同于 PRO），
  // 迁移期后管理台应只展示新的三个键。
  IMAGE_MODEL: process.env.IMAGE_MODEL || "doubao-seedream-5-0-pro-260628",
  IMAGE_MODEL_FAST: process.env.IMAGE_MODEL_FAST || "",
  IMAGE_MODEL_PRO: process.env.IMAGE_MODEL_PRO || "",
  IMAGE_MODEL_SERIES: process.env.IMAGE_MODEL_SERIES || "",
  IMAGE_ROUTING_MODE: process.env.IMAGE_ROUTING_MODE || "auto",
  IMAGE_FAST_MODE: process.env.IMAGE_FAST_MODE || "1",
  IMAGE_PROMPT_ENHANCE: process.env.IMAGE_PROMPT_ENHANCE || "1",
  IMAGE_SIZE: process.env.IMAGE_SIZE || "1.5K",
  IMAGE_PRICE_FAST: process.env.IMAGE_PRICE_FAST || "0.3",   // Flash ≤1.5K（官方成本 0.12）
  IMAGE_PRICE_SMALL: process.env.IMAGE_PRICE_SMALL || "0.45", // Pro ≤1.5K（官方成本 0.30）
  IMAGE_PRICE_2K: process.env.IMAGE_PRICE_2K || "0.9",        // Pro >1.5K（官方成本 0.60）
  RATE_IMAGE_PER_HOUR: process.env.RATE_IMAGE_PER_HOUR || "120",
  IMAGE_API_KEY: process.env.IMAGE_API_KEY || "",
  CHAT_API_KEY: process.env.CHAT_API_KEY || "",
  CHAT_BASE_URL: process.env.CHAT_BASE_URL || "",
  CHAT_MODEL_UTILITY_LITE: process.env.CHAT_MODEL_UTILITY_LITE || "",
};
// 注意：IMAGE_API_KEY 是主链路密钥，只认环境变量，**不参与** DB 覆盖——
// 避免 bf_config 里遗留的旧值把线上出图整体打挂。其余为非敏感调参项，可从 DB 覆盖。
const RT_KEYS = [
  "IMAGE_MODEL", "IMAGE_MODEL_FAST", "IMAGE_MODEL_PRO", "IMAGE_MODEL_SERIES", "IMAGE_ROUTING_MODE",
  "IMAGE_FAST_MODE", "IMAGE_PROMPT_ENHANCE", "IMAGE_SIZE",
  "IMAGE_PRICE_FAST", "IMAGE_PRICE_SMALL", "IMAGE_PRICE_2K", "RATE_IMAGE_PER_HOUR",
  "CHAT_API_KEY", "CHAT_BASE_URL", "CHAT_MODEL_UTILITY_LITE",
];
/**
 * 10-24 模型能力表。**未知 model ID 一律走保守默认**（不传 fast、不支持组图/图层），
 * 这样即使 Lite 的 ID 变了或管理员填错，最坏结果是"该能力不可用并明确报错"，
 * 而不是发出一个必然被上游拒绝的请求。
 *
 * 来源：火山方舟 Seedream 5.0 文档（2026-10 核实）：
 *   Pro   — 支持 fast 提示词优化、交互编辑、图层拆分；不支持组图
 *   Flash — 只支持 standard（禁止传 fast）、交互编辑、图层拆分；不支持组图
 *   Lite  — 只支持 standard、组图、联网搜索；不支持交互编辑与图层拆分
 */
const MODEL_CAPS = {
  "doubao-seedream-5-0-pro-260628":   { fastPromptMode: true,  series: false, edit: true,  layers: true  },
  "doubao-seedream-5-0-flash-260915": { fastPromptMode: false, series: false, edit: true,  layers: true  },
  "doubao-seedream-5-0-260128":       { fastPromptMode: false, series: true,  edit: false, layers: false },
  "doubao-seedream-5-0-lite-260128":  { fastPromptMode: false, series: true,  edit: false, layers: false },
  "doubao-seedream-4-0-250828":       { fastPromptMode: true,  series: false, edit: true,  layers: false },
};

/// 能力查询：未登记的模型按"保守可用"处理（能文生图，不给 fast/组图/图层）。
function capsOf(model) {
  return MODEL_CAPS[String(model || "")] || {
    fastPromptMode: false, series: false, edit: true, layers: false, unknown: true,
  };
}

/// 三个档位解析：新键优先，旧 IMAGE_MODEL 作为 PRO 的兼容别名。
function modelsOf() {
  const legacy = String(RT.IMAGE_MODEL || "").trim();
  return {
    fast: String(RT.IMAGE_MODEL_FAST || "").trim() || legacy,
    pro: String(RT.IMAGE_MODEL_PRO || "").trim() || legacy,
    series: String(RT.IMAGE_MODEL_SERIES || "").trim(),
  };
}

/**
 * 服务端唯一的模型选择入口。App 不传 model ID，只传 task_kind / quality_tier。
 * 能力限制优先于"快/贵"偏好：series 只有 series 模型能做，decompose 只有 layers 模型能做。
 */
function selectImageRoute({ taskKind, qualityTier, prompt, renderIntent }) {
  const m = modelsOf();
  const mode = String(RT.IMAGE_ROUTING_MODE || "auto").trim();
  const kind = String(taskKind || "generate").trim();
  const rawTier = String(qualityTier || "").trim();
  // 10-24：区分"用户/App 明确指定"与"没说"。只有没说时才走智能推断，
  // 否则会覆盖掉 App 已经判断好的意图。
  const explicit = rawTier && rawTier !== "auto" && rawTier !== "balanced";
  const tier = explicit ? rawTier : "auto";

  // 运维强制档：用于止损（比如 Pro 故障时全量切 Flash）
  if (mode === "flash_only") return { model: m.fast, reason: "routing=flash_only" };
  if (mode === "pro_only") return { model: m.pro, reason: "routing=pro_only" };

  if (kind === "series") {
    if (m.series && capsOf(m.series).series) return { model: m.series, reason: "task=series" };
    // 没配组图模型 / 配的模型不支持组图 → 明确拒绝，绝不发一个必然失败的请求
    return { model: "", reason: "series-unsupported", unsupported: true };
  }
  if (kind === "decompose") {
    if (capsOf(m.pro).layers) return { model: m.pro, reason: "task=decompose" };
    if (capsOf(m.fast).layers) return { model: m.fast, reason: "task=decompose(fallback-fast)" };
    return { model: "", reason: "decompose-unsupported", unsupported: true };
  }
  if (tier === "high") return { model: m.pro, reason: "tier=high" };
  if (tier === "fast") return { model: m.fast, reason: "tier=fast" };

  // auto：先从 prompt 做保守推断（明显是印刷物料才升 Pro）
  const inferred = inferQualityTier(prompt, renderIntent);
  if (inferred === "high") return { model: m.pro, reason: "inferred=print" };
  if (inferred === "fast") return { model: m.fast, reason: "inferred=draft" };

  // 推断不出：默认 Flash（没有配 Flash 就回落 Pro，保证可用性）
  return { model: m.fast, reason: "tier=auto" };
}

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
/**
 * 10-24 定价修复：价格必须跟着**模型**走，不能只看尺寸。
 *
 * 官方成本（火山方舟 2026-10）：
 *   Flash ≤1.5K  0.12 / Pro ≤1.5K  0.30 / Pro >1.5K  0.60 / Lite 0.22
 *
 * 旧实现只看尺寸：Flash 7.9 秒出图、成本 0.12，和 Pro 24 秒出图、成本 0.30
 * 扣用户一样的钱 —— "快速档更省"在账上完全没有体现。
 *
 * 现行售价（用户 2026-10-24 拍板）：
 *   Flash ≤1.5K 0.30（2.5×成本） / Pro ≤1.5K 0.45（1.5×） / Pro >1.5K 0.90（1.5×）
 */
function priceForSize(size, model) {
  const s = String(size || RT.IMAGE_SIZE || "1.5K").toUpperCase();
  const mdl = String(model || "");

  // 先判像素档
  let px = 2_250_000;                        // 1.5K 视为约 225 万像素
  if (s === "2K") px = 4_000_000;
  else {
    const m = /^(\d+)\s*[X×]\s*(\d+)$/.exec(s);
    if (m) px = Number(m[1]) * Number(m[2]);
  }
  if (px > 2_360_000) return Number(RT.IMAGE_PRICE_2K);

  // 再判模型：Flash 单独一档
  if (/seedream-5-0-flash/i.test(mdl)) return Number(RT.IMAGE_PRICE_FAST);
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
    // 10-24 安全修复：授权/额度检查必须 fail-closed。
    // 旧实现 catch 里返回 exhausted:false —— /me 挂掉时所有人都能免费出图（成本敞口）。
    if (!r.ok) {
      logStage("quota_check_http", { status: r.status });
      // 401/403：会话失效，直接拒绝；5xx：服务不可用，也无法确认额度，一律拒绝
      return { exhausted: true, unavailable: true, reason: "auth-unavailable", resetAt: null };
    }
    const j = await r.json().catch(() => null);
    if (!j || j.ok === false) {
      logStage("quota_check_bad_body", { ok: j && j.ok });
      return { exhausted: true, unavailable: true, reason: "bad-response", resetAt: null };
    }
    const month = j && j.limits && j.limits.month;
    const pct = month && month.remainingPct;
    const usedCny = j && j.usage && j.usage.pool && j.usage.pool.usedCny;
    const capCny = j && j.usage && j.usage.pool && j.usage.pool.capCny;
    if (month && month.enabled && typeof pct === "number" && pct <= 0) {
      return { exhausted: true, resetAt: month.resetAt || null, usedCny, capCny };
    }
    // 有额度池但拿不到剩余比例：无法确认，按不可用处理（不放行）
    if (typeof capCny === "number" && capCny > 0 && typeof pct !== "number") {
      logStage("quota_check_missing_pct", { capCny });
      return { exhausted: true, unavailable: true, reason: "missing-quota", resetAt: null };
    }
    return { exhausted: false, remainingPct: pct, usedCny, capCny };
  } catch (e) {
    // 超时 / 网络异常：无法确认授权与额度 → 拒绝，避免成本敞口
    logStage("quota_check_failed", { err: String((e && e.message) || e).slice(0, 120) });
    return { exhausted: true, unavailable: true, reason: "unreachable", resetAt: null };
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
/**
 * 10-24 账务修复：必须向调用方返回「是否真的记上了」。
 * 旧实现两个写入都吞异常且无返回值，flushJobs 无法判断成败，一律把任务标成
 * costCommitted=true —— 账号累计或 usage 写失败时这笔钱就永久丢了。
 * 现在只有两处都成功才返回 true；部分成功也算失败（下次重试会重复累加账户，
 * 但 usage 有唯一可识别行，可通过审计发现并补偿，优于静默丢失）。
 */
async function addImageCost(accountId, costCny, meta) {
  let accountOk = false;
  try {
    await getDb().collection(C.accounts).doc(accountId).update({
      imageUsedCny: getDb().command.inc(Math.max(0, costCny)),
      dayUsedCny: getDb().command.inc(Math.max(0, costCny)),
      weekUsedCny: getDb().command.inc(Math.max(0, costCny)),
    });
    accountOk = true;
  } catch (e) {
    logStage("billing_account_failed", { accountId: String(accountId).slice(0, 24), costCny, err: String((e && e.message) || e).slice(0, 120) });
  }
  const row = { accountId, kind: "image", costCny, ts: new Date(), model: meta.model, estimated: false, source: "bf-image" };
  let usageOk = false;
  try { await getDb().collection(C.usage).add(row); usageOk = true; }
  catch (e) {
    try { await getDb().collection(C.usage).add(row); usageOk = true; } catch (e2) {
      logStage("billing_usage_failed", { accountId: String(accountId).slice(0, 24), costCny, err: String((e2 && e2.message) || e2).slice(0, 120) });
    }
  }
  return accountOk && usageOk;
}

// ── 幂等 + 任务台账（10-23 改为"原子占位"模型）──
// 旧实现：先查缓存 → 生成 → 写缓存。两个并发同 requestId 请求会同时未命中、各生成一次、各扣一次费。
// 现在用 bf_image_jobs 的 _id 抢占：add(_id=rid) 成功才算拿到执行权，重复请求直接复用或返回进行中。
const IDEM_TTL_MS = 5 * 60 * 1000;
const JOB_COLL = "bf_image_jobs";

/**
 * 10-24 安全修复：幂等键必须按账号隔离。
 * 旧实现直接把客户端传入的 rid 当 _id —— 账户 A 用过的 rid，账户 B 传同一个值
 * 会命中 A 的 done 记录并拿到 A 的图片 URL（跨账号越权 + 免费复用）。
 * 现在统一走 hash(accountId + ":" + rid)，并在命中时二次校验归属。
 */
function idemKey(rid, accountId) {
  return crypto.createHash("sha256").update(String(accountId) + ":" + String(rid)).digest("hex").slice(0, 48);
}

async function claimIdem(rid, accountId) {
  // 10-24：缺 requestId 时不再返回 "none" 放行——那等于绕过整个任务台账与幂等。
  // 由服务端生成一个，保证每次调用都有可追溯的任务记录。
  if (!rid) rid = "srv-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 10);
  const key = idemKey(rid, accountId);
  const col = getDb().collection(JOB_COLL);
  try {
    await col.add({ _id: key, clientRequestId: String(rid).slice(0, 120), state: "processing", accountId, ts: Date.now() });
    return { state: "new", key };
  } catch (e) {
    try {
      const r = await col.doc(key).get();
      const d = (r && r.data && r.data[0]) || null;
      // 归属校验：即使 hash 碰撞或旧数据异常，也绝不把别人的结果交出去
      const sameOwner = !d || String(d.accountId || "") === String(accountId);
      if (sameOwner && d && d.state === "done" && d.url && Date.now() - Number(d.ts || 0) < IDEM_TTL_MS) {
        return { state: "done", url: d.url, key };
      }
      // 90 秒内仍是 processing：判为并发重复，不重复生成
      if (sameOwner && d && d.state === "processing" && Date.now() - Number(d.ts || 0) < 90 * 1000) {
        return { state: "busy", key };
      }
      // 失败或超时：接管这条任务
      await col.doc(key).set({ clientRequestId: String(rid).slice(0, 120), state: "processing", accountId, ts: Date.now(), retried: true });
      return { state: "new", key };
    } catch (e2) {
      // 台账不可用时仍允许出图（可用性），但不再声称"命中幂等"
      return { state: "none", key };
    }
  }
}
/**
 * 10-24 关键修复：finishIdem / abortIdem 必须用与 claimIdem **同一个** key。
 *
 * claimIdem 把 _id 改成了 hash(accountId:rid) 之后，这两个函数仍在用裸 rid 作为 _id ——
 * 更新一个不存在的文档，异常被 catch 吞掉。后果：
 *   · 任务永远停在 processing → 重放返回 409 而不是 cached
 *   · 90 秒后被"接管"→ 可能重复生成、重复扣费
 *   · state 不是 done → flushJobs 永远扫不到 → **这笔钱不计账**
 */
async function finishIdem(rid, accountId, url, costCny, model) {
  if (!rid) return;
  const key = idemKey(rid, accountId);
  try {
    await getDb().collection(JOB_COLL).doc(key).update({
      state: "done", url, costCny, model, accountId,
      ts: Date.now(), costCommitted: false,
    });
  } catch (e) { logStage("idem_finish_failed", { key: key.slice(0, 16), err: String((e && e.message) || e).slice(0, 120) }); }
}
async function abortIdem(rid, accountId, reason) {
  if (!rid) return;
  const key = idemKey(rid, accountId);
  try { await getDb().collection(JOB_COLL).doc(key).update({ state: "failed", reason: String(reason || "").slice(0, 120), ts: Date.now() }); }
  catch (e) { /* 忽略 */ }
}

/// 记账补投（outbox）：已完成但未记账的任务，下次请求时补记，最多 3 条，避免长期漏账。
async function flushJobs() {
  try {
    const col = getDb().collection(JOB_COLL);
    const r = await col.where({ state: "done", costCommitted: false }).limit(3).get();
    for (const d of (r && r.data) || []) {
      const id = d._id || d.id;
      if (!id) continue;
      const cost = Number(d.costCny || 0);
      // 零成本任务（命中缓存 / 管理员豁免）直接确认，不需要账本
      const billed = cost <= 0 ? true : await addImageCost(d.accountId, cost, { model: d.model || "unknown" });
      if (!billed) {
        // 记账失败：保留 costCommitted=false，下一轮重试；同时累加重试次数供告警
        const tries = Number(d.costTries || 0) + 1;
        await col.doc(id).update({ costTries: tries, costLastErrorAt: Date.now() }).catch(() => {});
        logStage("billing_commit_retry", { jobId: String(id).slice(0, 24), tries, costCny: cost });
        continue;
      }
      await col.doc(id).update({ costCommitted: true, committedAt: Date.now() }).catch(() => {});
    }
  } catch (e) { /* outbox 失败不影响主流程 */ }
}

// ── 编辑结果廉价自检：像素级比对原图与结果图，抓「整图重绘」（0 token / <100ms）──
/**
 * 10-24 IMG-02 补强：解码前先读图片头拿宽高。
 * 压缩后只有几十 KB、解码后却是 30000×30000（约 3.6GB 内存）的"图片炸弹"，
 * 仅靠请求体大小限制拦不住 —— 必须在 decode 之前按**解码后像素**拒绝。
 */
function decodeImage(buf) {
  if (!buf || buf.length < 8) return null;
  // 解码前按"解码后像素"拦截：压缩包很小、解码后巨大的图片炸弹在这里被挡住
  if (!decodedSizeAllowed(probeImageSize(buf))) return null;
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

/**
 * 10-24 安全修复（IMG-01）：出站抓图必须限定目标。
 * 旧实现直接 fetch 任何 URL —— sourceRef 来自客户端，可指向内网、云元数据
 * （169.254.169.254）、localhost 或超大响应，构成 SSRF + 资源耗尽。
 * 现在：只允许 https + 明确域名后缀 + 拒绝私网/回环/link-local + 禁止重定向 + 限大小。
 */
const FETCH_MAX_BYTES = 8 * 1024 * 1024;

async function fetchBinary(url, timeoutMs, maxBytes) {
  const limit = Number(maxBytes || FETCH_MAX_BYTES);
  const u = safeFetchURL(url);
  if (!u) {
    // 只记录 host，不记录完整 URL（可能含签名参数）
    let host = "?";
    try { host = new URL(String(url)).hostname.slice(0, 60); } catch (e) { host = "?"; }
    logStage("fetch_blocked", { host });
    return null;
  }
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeoutMs || 8000);
  try {
    // redirect: error —— 不跟随跳转，避免"白名单域名 302 到内网"绕过
    const r = await fetch(u.toString(), { signal: ctrl.signal, redirect: "error", headers: { Accept: "image/*" } });
    if (!r.ok) return null;
    const ct = String(r.headers.get("content-type") || "").toLowerCase();
    if (ct && !ct.startsWith("image/") && !ct.startsWith("application/octet-stream")) return null;
    const declared = Number(r.headers.get("content-length") || 0);
    if (declared > limit) return null;
    const buf = Buffer.from(await r.arrayBuffer());
    if (buf.length > limit) return null;
    return buf;
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

function readBody(req, maxBytes) {
  const limit = Number(maxBytes || 20 * 1024 * 1024);
  return new Promise((resolve) => {
    // 10-24 修复：按**字节**累积。旧实现用 string.length 判断 20MB，
    // 中文/emoji 一个字符 3~4 字节，实际可收到 60~80MB，等于上限形同虚设。
    const chunks = [];
    let total = 0;
    let done = false;
    req.on("data", (c) => {
      if (done) return;
      total += c.length;
      if (total > limit) {
        done = true;
        try { req.destroy(); } catch (e) { /* ignore */ }
        resolve(null);
        return;
      }
      chunks.push(c);
    });
    req.on("end", () => {
      if (done) return;
      try { resolve(JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}")); }
      catch (e) { resolve(null); }
    });
    req.on("error", () => { if (!done) { done = true; resolve(null); } });
    // 客户端提前断开：不处理会一直挂着 Promise 直到函数超时
    req.on("aborted", () => { if (!done) { done = true; resolve(null); } });
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
/**
 * 10-24 安全修复（IMG-02）：显式像素尺寸必须有上限。
 * 旧实现只做格式正则，`99999x99999` 也能通过 —— 上游会拒或产生巨额像素账单。
 * 现在：单边 512~4096，总像素不超过 4.2MP，超限时按比例缩到预算内（保持宽高比）。
 */
function resolveSize(size, aspectRatio) {
  const ar = String(aspectRatio || "").trim();
  if (ar && ASPECT_SIZES[ar]) return ASPECT_SIZES[ar];
  const s = String(size || RT.IMAGE_SIZE || "1.5K").trim();
  if (/^(1K|1\.5K|2K)$/i.test(s)) return s.toUpperCase();
  const fixed = clampExplicitSize(s);
  if (fixed) return fixed;
  // 非法/超限：回落默认档位，而不是把危险值透传给上游
  return "1.5K";
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

async function generate({ prompt, image, size, structured, renderIntent, aspectRatio, layerDecomposition, taskKind, qualityTier, model, requestedCount }) {
  const apiKey = String(RT.IMAGE_API_KEY || "");
  if (!apiKey) return { ok: false, code: 503, msg: "IMAGE_API_KEY 未配置" };

  // 10-24 混合路由：模型由服务端决定，App 只表达任务类型与质量偏好。
  const route = model ? { model, reason: "explicit" } : selectImageRoute({ taskKind, qualityTier, prompt, renderIntent });
  if (route.unsupported) {
    logStage("route_unsupported", { taskKind: taskKind || "generate", reason: route.reason });
    return { ok: false, code: 422, msg: "当前配置的模型不支持该任务", unsupported: true, reason: route.reason };
  }
  const selectedModel = String(route.model || "").trim() || String(RT.IMAGE_MODEL || "").trim();
  if (!selectedModel) return { ok: false, code: 503, msg: "未配置生图模型" };
  const caps = capsOf(selectedModel);

  // 能力前置拦截：发出去必然失败的请求，不发。
  if (layerDecomposition === true && !caps.layers) {
    logStage("route_unsupported", { taskKind: "decompose", model: selectedModel });
    return { ok: false, code: 422, msg: "当前配置的生图模型不支持图层拆分", unsupported: true, reason: "layers-unsupported" };
  }
  if (image && !caps.edit) {
    logStage("route_unsupported", { taskKind: "edit", model: selectedModel });
    return { ok: false, code: 422, msg: "当前配置的生图模型不支持参考图编辑", unsupported: true, reason: "edit-unsupported" };
  }
  if (String(taskKind || "") === "series" && !caps.series) {
    logStage("route_unsupported", { taskKind: "series", model: selectedModel });
    return { ok: false, code: 422, msg: "当前配置的生图模型不支持组图", unsupported: true, reason: "series-unsupported" };
  }

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
  const payload = {
    model: selectedModel,
    prompt: finalPrompt,
    size: resolvedSize,
    response_format: "url",
    watermark: false,
  };
  // 10-24 参数兼容修复：只有 Pro / 4.0 支持 fast 提示词优化。
  // Flash / Lite 只支持 standard，此前无条件传 fast 会被上游拒绝或行为不符预期。
  // 未知模型走保守默认（不传），保持官方 standard 语义。
  if (caps.fastPromptMode && String(RT.IMAGE_FAST_MODE) !== "0") {
    payload.optimize_prompt_options = { mode: "fast" };
  }
  if (image) payload.image = image;
  // 10-23 图层拆分（Seedream 5.0 pro 原生能力）：仅支持 1 张图，返回底图 + 最多 16 个透明 PNG 图层
  if (layerDecomposition === true) payload.layer_decomposition = true;
  // 组图：只有 Lite 支持（Pro/Flash 明确不支持，前面已拦截）
  if (String(taskKind || "") === "series" && caps.series) {
    payload.sequential_image_generation = "auto";
    const n = Number(requestedCount);
    if (Number.isFinite(n) && n > 1) payload.max_images = Math.min(8, Math.max(2, Math.floor(n)));
  }

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
    return { ok: true, url, model: selectedModel, routeReason: route.reason, caps };
  } catch (e) {
    return { ok: false, code: 504, msg: String((e && e.message) || e).slice(0, 200) };
  } finally {
    clearTimeout(timer);
  }
}

// ── HTTP 服务 ──
const server = http.createServer(async (req, res) => {
  // 10-24：requestId 贯穿 + 错误响应统一规范化
  const inboundRid = String(req.headers["x-request-id"] || "").trim().slice(0, 64);
  const rid = inboundRid || ("req_" + crypto.randomBytes(6).toString("hex"));
  reqStore.enterWith({ requestId: rid });
  res.setHeader("X-Request-Id", rid);

  const send = (code, obj) => {
    let body = obj;
    if (code >= 400 && obj && obj.ok === false) {
      // 把内部码映射成自然语言，同时保留旧字段（error / code / msg）供旧 App 读取
      const rawCode = String(obj.error || "INTERNAL");
      // catalog 里有专门文案的（如 TASK_UNSUPPORTED）优先用它 —— 那是设计过、带 actions 的；
      // 只有落到 INTERNAL 兜底时才保留调用方原文。
      const hasDedicated = !!CATALOG[rawCode] && rawCode !== "INTERNAL";
      const pub = publicError(rawCode, {
        message: hasDedicated ? "" : obj.msg,
        requestId: rid,
        stage: String(obj.stage || ""),
        partialResult: obj.partialResult,
      });
      body = Object.assign({}, obj, {
        ok: false,
        requestId: rid,
        error: pub.error,                 // 字符串，保持旧语义
        errorDetail: pub.errorDetail,     // 新增结构化字段
        msg: pub.message,                 // 旧 App 读 msg
        message: pub.message,             // 新 App 读 message
        actions: pub.actions,
      });
      if (!pub.actions.includes("retry")) delete body.retryable;
      // 内部诊断字段绝不进响应（reason/detail/status/raw 可能含模型名、上游原文）
      delete body.reason;
      delete body.detail;
      delete body.status;
      delete body.raw;
      console.log(JSON.stringify({
        tag: "image_error", fn: "bf-image", requestId: rid,
        httpStatus: code, code: pub.error, category: pub.errorDetail.category,
        retryable: pub.errorDetail.retryable, detail: String(obj.msg || "").slice(0, 200),
      }));
    }
    res.writeHead(code, { "Content-Type": "application/json; charset=utf-8" });
    res.end(JSON.stringify(body));
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
    if (!prompt && !hasStructured) { await abortIdem(rid, auth.sub, "missing_prompt"); return send(400, { ok: false, code: 400, error: "BAD_REQUEST", msg: "缺少 prompt" }); }
    if (prompt.length > 1500) { await abortIdem(rid, auth.sub, "prompt_too_long"); return send(400, { ok: false, code: 400, error: "BAD_REQUEST", msg: "描述过长，请精简到 1500 字以内" }); }

    // 限流：原子自增后判超限；被拒时释放占位，允许用户稍后重试同一个 requestId
    const rl = await claimRate(auth.sub);
    if (rl) {
      logStage("rate_limited", { sub: auth.sub });
      await abortIdem(rid, auth.sub, "rate_limited");
      return send(429, { ok: false, code: 429, error: "RATE_LIMITED", msg: rl });
    }
    const renderIntent = String(body.render_intent || body.renderIntent || "");
    const aspectRatio = String(body.aspect_ratio || body.aspectRatio || "");
    // 10-24 路由契约：App 只传业务意图，模型 ID 由服务端决定。
    const taskKind = String(body.task_kind || body.taskKind || "").trim()
      || (body.layer_decomposition === true ? "decompose" : (body.image ? "edit" : "generate"));
    const qualityTier = String(body.quality_tier || body.qualityTier || "auto").trim();
    const requestedCount = Number(body.requested_count || body.requestedCount || 1);
    let out = await generate({
      prompt: body.prompt, image: body.image, size: body.size, structured: body.structured,
      renderIntent, aspectRatio, layerDecomposition: body.layer_decomposition === true,
      taskKind, qualityTier, requestedCount,
    });
    // 能力不支持：任务已在路由阶段被拦下，这里不再重试、不再吞成 502
    if (!out.ok && out.unsupported) {
      await abortIdem(rid, auth.sub, out.reason || "unsupported");
      return send(422, {
        ok: false, code: 422, error: "TASK_UNSUPPORTED",
        msg: out.msg, reason: out.reason,
        task_kind: taskKind, quality_tier: qualityTier,
        ms: Date.now() - t0,
      });
    }

    let retried = false;
    // 编辑场景：像素相似度 < 0.60 判定「整图重绘」，自动重试一次（0 token，仅 +一次生成）
    if (out.ok && body.image) {
      const sim = await editSimilarity(Array.isArray(body.image) ? body.image[0] : body.image, out.url);
      if (sim !== null) {
        logStage("edit_similarity", { sim: Number(sim.toFixed(3)) });
        if (sim < 0.60) {
          logStage("edit_over_redraw_retry", { sim: Number(sim.toFixed(3)) });
          // 重试必须沿用首轮选定的模型：换模型会让相似度对比失真，成本口径也会漂
          const retry = await generate({
            prompt: String(body.prompt || "") + "\n\n【重要】仅修改用户指定的区域，画面其余部分必须与原图逐像素保持一致，禁止整体重绘。",
            image: body.image, size: body.size, structured: body.structured,
            renderIntent, aspectRatio, layerDecomposition: body.layer_decomposition === true,
            taskKind, qualityTier, requestedCount,
            model: out.model,
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
      // 10-24：台账记录**实际使用的模型**（此前写死 RT.IMAGE_MODEL，混合路由后会导致成本归因错误）
      const usedModel = String(out.model || RT.IMAGE_MODEL || "");
      const price = priceForSize(resolveSize(body.size, aspectRatio), usedModel);
      await finishIdem(rid, auth.sub, out.url, price, usedModel);
      await flushJobs();
      logStage("image_route", {
        sub: auth.sub, taskKind, qualityTier, model: usedModel,
        reason: out.routeReason || "", retried,
      });
      return send(200, {
        ok: true, url: out.url, ms: Date.now() - t0, hadImage: !!body.image,
        cost: price, retried, size: resolveSize(body.size, aspectRatio),
        renderIntent: renderIntent || "default",
        model: usedModel, route_reason: out.routeReason || "",
        task_kind: taskKind, quality_tier: qualityTier,
      });
    }
    await abortIdem(rid, auth.sub, out.msg);
    return send(out.code || 502, Object.assign({ ms: Date.now() - t0, hadImage: !!body.image }, out));
  }

  return send(404, { ok: false, msg: "not found" });
});

server.listen(PORT, () => console.log("[bf-image] listening on " + PORT));

// 仅用于契约测试的纯函数导出（不影响云函数运行）
module.exports.__test = { decodeImage, resolveSize, ...require("./media-guards") };
