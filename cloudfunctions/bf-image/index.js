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
// 10-24 P1：日志 PII 打码（与 bf-api 同一份 log-safe.js）。所有日志先过 scrub 再输出：
// 账号 ID → 稳定短哈希；手机号/邮箱/证件/卡号/密钥 → 打码；用户 prompt 原文 → 只留长度+哈希。
const { logSafe, maskText, scrub } = require("./log-safe");
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
  } catch (e) {
    // 10-24 P1-8：配置刷新失败不能静默 —— 意味着这一轮用的是旧模型/旧价格
    logStage("runtime_refresh_failed", { err: String((e && e.message) || e).slice(0, 120) });
  }
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

/**
 * 10-24 组图编排器（计划 P0-8）。
 *
 * 现状：`sequential_image_generation` 是原生组图能力，只有 Lite 支持；当前环境未配置 Lite，
 * 所以 series 请求原本直接 422。用户说"生成 4 张"得到"做不到"，体验不成立。
 *
 * 这里改成**服务端串行编排**：拆成 N 个独立单图子任务，每张有独立 requestId 与独立记账。
 * 代价：风格一致性靠提示词约束，不如原生组图；N 上限 4（4×25s 仍在云函数超时内）。
 * 收益：功能从"不可用"变成"可用且可部分成功"。
 */
const SERIES_MAX = 4;

function seriesPrompt(base, index, total) {
  const b = String(base || "").trim();
  return b + `\n\n【系列图第 ${index}/${total} 张】` +
    `同一组系列图必须保持统一的配色、光线、材质与视觉风格；` +
    `但每张的构图要有明显差异（视角、主体位置、景别至少变一项），禁止重复构图。` +
    (index === 1 ? `这一张作为整套的基准，请把风格定准。` : `请严格延续整套的统一风格。`);
}

/**
 * 10-24 组图子任务执行器（首跑与「只重试失败项」共用同一条路径）。
 *
 * 契约（P0-1）：先 claim 再 generate 再 finish/abort。
 * 旧实现跳过 claim 直接 finish —— 更新一个不存在的文档，异常被吞，
 * 任务永远不是 done，flushJobs 永远扫不到，于是这一张既不进账本也不进账务。
 */
async function runSeriesChild(opts) {
  const { parentRid, index, total, accountId, prompt, image, size, structured,
          renderIntent, aspectRatio, qualityTier, resolved } = opts;
  const subRid = parentRid + "::s" + index;
  const claim = await claimIdem(subRid, accountId);

  // 已成功的子任务直接复用：重试时绝不重新生成、也不重复扣费
  if (claim.state === "done" && claim.url) {
    return {
      index, ok: true, url: claim.url, model: String(claim.model || ""),
      cost: 0, reused: true, costState: "committed",
    };
  }
  if (claim.state === "busy") {
    return { index, ok: false, message: "这一张还在生成中，请稍后重试。", errorCategory: "in_progress" };
  }

  const r = await generate({
    prompt: seriesPrompt(prompt, index, total),
    image, size, structured, renderIntent, aspectRatio,
    layerDecomposition: false,
    taskKind: "generate",          // 子任务一律按单图生成，路由走 generate 规则
    qualityTier,
    requestedCount: 1,
  });

  if (!r.ok) {
    await abortIdem(subRid, accountId, String(r.reason || "upstream").slice(0, 40));
    logStage("series_item_failed", {
      index, reason: String(r.reason || "").slice(0, 40), msg: String(r.msg || "").slice(0, 120),
    });
    // 用户文案固定；技术原因只进日志（P1-3）
    return {
      index, ok: false,
      message: "这一张没有生成成功，可以单独重试。",
      errorCategory: String(r.reason || "upstream").slice(0, 40),
    };
  }

  const model = String(r.model || RT.IMAGE_MODEL || "");
  const price = priceForSize(resolved, model);
  const persisted = await finishIdem(subRid, accountId, r.url, price, model, {
    kind: "series_child", parentJobId: parentRid, index,
  });
  let costState = persisted ? "queued" : "pending";
  if (!persisted) {
    // 台账写不进去：直接走幂等账务事件（事件 ID 同样由 subRid 派生），避免漏账
    const direct = await addImageCost(accountId, price, {
      model, jobKey: subRid, kind: "series_child", parentJobId: parentRid, index,
    });
    costState = direct ? "committed" : "pending";
  }
  return { index, ok: true, url: r.url, model, cost: price, costState };
}

// ── 10-24 P1-12：额度预留（reserve / release）──
// 说明：这不是数据库事务级的原子预留，而是「带 TTL 的登记 + 读侧扣减」：
//   · start 时登记一笔 amountCny，30 分钟有效；
//   · quotaExhausted 把生效中的预留从余额里扣掉，避免并发两次组图各自都通过预检；
//   · 任务结束（done/partial/failed）或取消时释放。
// 残余风险：进程在「登记成功、任务未开始」之间被杀，预留会占额度到 TTL 过期（最多 30 分钟），
// 不会造成少收或多收。
const RESERVE_COLL = "bf_quota_reservations";
const SERIES_COLL = "bf_image_series";
const RESERVE_TTL_MS = 30 * 60 * 1000;

function authSubOf(req) {
  try {
    const payload = verifyToken(bearer(req));
    return (payload && payload.sub) || "";
  } catch (e) { return ""; }
}

async function activeReservedCny(accountId) {
  if (!accountId) return 0;
  try {
    const r = await getDb().collection(RESERVE_COLL)
      .where({ accountId, state: "active" }).limit(50).get();
    const now = Date.now();
    let sum = 0;
    for (const d of (r && r.data) || []) {
      if (Number(d.expiresAt || 0) > now) sum += Number(d.amountCny || 0);
    }
    return Number(sum.toFixed(4));
  } catch (e) {
    logStage("reserve_read_failed", { err: String((e && e.message) || e).slice(0, 120) });
    return 0;   // 读不到预留时按 0 处理（宁可放行，不阻断正常用户）
  }
}

async function reserveQuota(taskId, accountId, amountCny) {
  if (!(Number(amountCny) > 0)) return false;
  await ensureCollection(RESERVE_COLL);
  try {
    await getDb().collection(RESERVE_COLL).add({
      _id: taskId, accountId, amountCny: Number(amountCny),
      state: "active", createdAt: Date.now(), expiresAt: Date.now() + RESERVE_TTL_MS,
    });
    return true;
  } catch (e) {
    logStage("reserve_create_failed", { taskId: String(taskId).slice(0, 20), err: String((e && e.message) || e).slice(0, 120) });
    return false;
  }
}

async function releaseQuota(taskId, reason) {
  if (!taskId) return;
  try {
    await getDb().collection(RESERVE_COLL).doc(taskId).update({
      state: "released", releasedAt: Date.now(), releaseReason: String(reason || "").slice(0, 40),
    });
  } catch (e) { /* 释放失败：等 TTL 过期，不影响用户 */ }
}

// ── 10-24 P1-5：组图任务状态机（服务端持久化，可轮询、可取消、可断点续跑）──
function seriesTaskIdOf(accountId, clientRid) {
  return crypto.createHash("sha256")
    .update("series:" + String(accountId) + ":" + String(clientRid))
    .digest("hex").slice(0, 40);
}

/** 由 items 推导状态：pending 非空 = 还没跑完；跑完按成功数定 done/partial/failed */
function deriveTaskState(items, requested, cancelled) {
  const list = (items || []).filter(Boolean);
  const okCount = list.filter((x) => x.ok).length;
  const done = new Set(list.map((x) => Number(x.index)));
  const pendingIndices = [];
  for (let i = 1; i <= requested; i++) if (!done.has(i)) pendingIndices.push(i);
  const failedIndices = list.filter((x) => !x.ok).map((x) => Number(x.index));
  let status;
  if (cancelled) status = "cancelled";
  else if (pendingIndices.length > 0) status = okCount > 0 ? "running" : "queued";
  else status = okCount === requested ? "done" : (okCount > 0 ? "partial" : "failed");
  return { status, okCount, pendingIndices, failedIndices, items: list };
}

/** 任务对外结构：与旧 series 响应同构，额外带 taskId/status/pendingIndices */
function seriesTaskPayload(doc) {
  const requested = Number(doc.requested || 0);
  const st = deriveTaskState(doc.items, requested, doc.status === "cancelled");
  const priced = st.items.reduce((sum, x) => sum + (x.ok ? Number(x.cost || 0) : 0), 0);
  const committed = st.items.filter((x) => x.ok && x.costState === "committed")
    .reduce((sum, x) => sum + Number(x.cost || 0), 0);
  return {
    ok: st.okCount > 0,
    task_kind: "series",
    taskId: doc._id,
    requestId: doc.clientRequestId || doc._id,
    status: st.status,
    requested,
    succeeded: st.okCount,
    failed: st.failedIndices.length,
    partial: st.status === "partial" || (st.okCount > 0 && st.pendingIndices.length > 0),
    failedIndices: st.failedIndices,
    pendingIndices: st.pendingIndices,
    items: st.items,
    billedCny: Number(priced.toFixed(4)),
    pricedCny: Number(priced.toFixed(4)),
    committedCny: Number(committed.toFixed(4)),
    pendingCostCount: st.items.filter((x) => x.ok && x.costState !== "committed").length,
    size: doc.sizeResolved || doc.size || "",
    quality_tier: doc.qualityTier || "",
    reservedCny: Number(doc.reservedCny || 0),
    createdAt: doc.createdAt || 0,
    updatedAt: doc.updatedAt || 0,
    ms: 0,
  };
}

async function readSeriesTask(taskId) {
  return await readOne(SERIES_COLL, taskId);
}

/** 写回单项 + 重算状态；两个 step 并发时用点路径更新，不会互相覆盖 items */
async function recordSeriesItem(taskId, index, item) {
  const col = getDb().collection(SERIES_COLL);
  try {
    await col.doc(taskId).update({
      ["items." + (index - 1)]: item,
      updatedAt: Date.now(),
      status: "running",
    });
  } catch (e) {
    // 点路径不被支持时退化为整数组写回（读-改-写，仍有极小的并发窗口）
    logStage("series_item_path_update_failed", { taskId: String(taskId).slice(0, 20), err: String((e && e.message) || e).slice(0, 120) });
    const cur = await readOne(SERIES_COLL, taskId);
    if (!cur) return;
    const items = Array.isArray(cur.items) ? cur.items.slice() : [];
    while (items.length < Number(cur.requested || 0)) items.push(null);
    items[index - 1] = item;
    await col.doc(taskId).update({ items, updatedAt: Date.now(), status: "running" }).catch(() => {});
  }
}

async function refreshTaskState(taskId) {
  const doc = await readOne(SERIES_COLL, taskId);
  if (!doc) return null;
  const st = deriveTaskState(doc.items, Number(doc.requested || 0), doc.status === "cancelled");
  const patch = {
    status: st.status,
    succeeded: st.okCount,
    failedIndices: st.failedIndices,
    pendingIndices: st.pendingIndices,
    updatedAt: Date.now(),
  };
  try { await getDb().collection(SERIES_COLL).doc(taskId).update(patch); } catch (e) { /* 状态写失败：下次读时重算 */ }
  // 终态释放预留
  if (["done", "partial", "failed", "cancelled"].includes(st.status)) {
    await releaseQuota(taskId, st.status);
  }
  return Object.assign({}, doc, patch);
}

/** 执行一张（幂等：已成功的直接返回，不再调上游） */
async function executeSeriesStep(task, index, accountId) {
  const items = Array.isArray(task.items) ? task.items : [];
  const existing = items[index - 1];
  if (existing && existing.ok) return existing;
  const item = await runSeriesChild({
    parentRid: task._id, index, total: Number(task.requested || 0), accountId,
    prompt: task.prompt, image: undefined, size: task.size,
    structured: task.structured, renderIntent: task.renderIntent,
    aspectRatio: task.aspectRatio, qualityTier: task.qualityTier,
    resolved: task.sizeResolved,
  });
  await recordSeriesItem(task._id, index, item);
  return item;
}

/** flushJobs 之后再读一次子任务，把 queued 更新成真实 committed —— 响应里的金额必须是账本状态 */
async function refreshSeriesCostStates(parentRid, accountId, items) {
  for (const it of items) {
    if (!it || !it.ok || !(Number(it.cost) > 0)) continue;
    const d = await readOne(JOB_COLL, idemKey(parentRid + "::s" + it.index, accountId));
    it.costState = d && d.costCommitted ? "committed" : (d ? "queued" : "pending");
  }
  return items;
}

/** 组图响应体（首跑 / 重放 / 重试共用同一结构，客户端只需要一套解析） */
function seriesPayload(items, requested, meta) {
  const okItems = items.filter((x) => x && x.ok);
  const failedIndices = items.filter((x) => x && !x.ok).map((x) => x.index);
  const pricedCny = okItems.reduce((sum, x) => sum + Number(x.cost || 0), 0);
  const committedCny = okItems.filter((x) => x.costState === "committed")
    .reduce((sum, x) => sum + Number(x.cost || 0), 0);
  const pendingCostCount = okItems.filter((x) => x.costState !== "committed").length;
  return {
    ok: okItems.length > 0,
    task_kind: "series",
    requestId: String(meta.requestId || ""),
    requested,
    succeeded: okItems.length,
    failed: requested - okItems.length,
    partial: okItems.length > 0 && okItems.length < requested,
    failedIndices,
    items,
    // billedCny 保留字段名兼容旧客户端；语义是"已计价"，不等于"已入账"
    billedCny: Number(pricedCny.toFixed(4)),
    pricedCny: Number(pricedCny.toFixed(4)),
    committedCny: Number(committedCny.toFixed(4)),
    pendingCostCount,
    size: meta.size || "",
    quality_tier: meta.qualityTier || "",
    ms: meta.ms || 0,
  };
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
// 10-24 P1：出口统一脱敏。sub → acct:xxxxxxxx（稳定可关联），err/detail 的 PII 形态打码，
// prompt/content 只留 {len,sha}，上游原文（raw/body）直接丢弃。
function logStage(stage, extra) {
  try {
    logSafe(Object.assign({ ts: new Date().toISOString(), fn: "bf-image", stage }, extra || {}));
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
      // 10-24 修复：401/403 是"会员侧明确拒绝"（到期/停用/掉登录），不是"额度查不到"。
      // 旧实现把两者混成 unavailable → 用户到期来画图，看到的是"暂时无法确认额度"，
      // 客服也无从判断。现在把 bf-api 的错误码与文案原样透传。
      let errBody = null;
      try { errBody = await r.json(); } catch (e) { errBody = null; }
      const errCode = String((errBody && errBody.error) || "");
      logStage("quota_check_http", { status: r.status, code: errCode });
      if (r.status === 401 || r.status === 403) {
        return {
          exhausted: true, unavailable: false, denied: r.status,
          code: errCode || (r.status === 401 ? "UNAUTHORIZED" : "MEMBERSHIP_EXPIRED"),
          message: String((errBody && errBody.message) || ""),
          reason: "denied-" + (errCode || r.status),
        };
      }
      // 5xx：服务不可用，无法确认授权与额度，一律拒绝（fail-closed）
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
    // 10-24 P1-12：生效中的组图预留也要占额度，否则并发两次组图都能通过预检（超额）。
    const reserved = await activeReservedCny(authSubOf(req));
    if (month && month.enabled && typeof pct === "number" && pct <= 0) {
      return { exhausted: true, resetAt: month.resetAt || null, usedCny, capCny, reservedCny: reserved };
    }
    // 有额度池但拿不到剩余比例：无法确认，按不可用处理（不放行）
    if (typeof capCny === "number" && capCny > 0 && typeof pct !== "number") {
      logStage("quota_check_missing_pct", { capCny });
      return { exhausted: true, unavailable: true, reason: "missing-quota", resetAt: null };
    }
    const remainingCny = (typeof capCny === "number" && typeof usedCny === "number")
      ? Number((capCny - usedCny - reserved).toFixed(4))
      : undefined;
    return { exhausted: false, remainingPct: pct, usedCny, capCny, reservedCny: reserved, remainingCny };
  } catch (e) {
    // 超时 / 网络异常：无法确认授权与额度 → 拒绝，避免成本敞口
    logStage("quota_check_failed", { err: String((e && e.message) || e).slice(0, 120) });
    return { exhausted: true, unavailable: true, reason: "unreachable", resetAt: null };
  } finally {
    clearTimeout(timer);
  }
}

/** 会员侧拒绝（401/403）原样转出：文案与错误码跟 bf-api 保持一致，不要改写成"额度不可用" */
function sendDenied(q, send) {
  const code = q.code || (q.denied === 401 ? "UNAUTHORIZED" : "MEMBERSHIP_EXPIRED");
  const fallback = code === "ACCOUNT_SUSPENDED" ? "该账号已停用，请联系客服"
    : code === "MEMBERSHIP_EXPIRED" ? "会员已到期，请联系续费"
    : "登录状态已失效，请重新登录";
  const msg = q.message || fallback;
  logStage("quota_denied", { status: q.denied, code });
  return send(q.denied, {
    ok: false, code: q.denied, error: code, msg, message: msg,
    actions: q.denied === 401 ? ["relogin"] : ["renew"],
    requestId: currentRequestId(),
  });
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
    // 限流台账不可用时不阻断出图（可用性优先），但必须留痕：否则等于限流静默失效
    logStage("rate_limit_unavailable", { err: String((e && e.message) || e).slice(0, 120) });
    return null;
  }
}

// ── 账务（10-24 重构：唯一账务事件 + 分阶段幂等）──
/**
 * 账务事件 ID：由「账号 + 任务 key」派生，稳定且唯一。
 * 同一张图无论重试多少次、被几个实例处理，都只会得到一个事件 ID。
 */
const BILLING_COLL = "bf_billing_events";

function billingEventIdOf(accountId, jobKey) {
  return crypto.createHash("sha256")
    .update("bill:" + String(accountId) + ":" + String(jobKey))
    .digest("hex").slice(0, 48);
}

/**
 * 10-24 关键修复：CloudBase 不会在 add 时自动建集合 —— 集合不存在会直接抛
 * [ResourceNotFound] Db or Table not exist，而 addImageCost 吞掉异常后只返回 false，
 * 表现为「账一直没记上、也没人发现」。所以在写入前显式确保集合存在。
 *
 * 60 秒内失败不重试（避免每次请求都多一次管理 API 调用），成功后进程内缓存。
 */
const ENSURED_COLLECTIONS = new Map();
async function ensureCollection(name) {
  const now = Date.now();
  const hit = ENSURED_COLLECTIONS.get(name);
  if (hit && (hit.ok || now - hit.at < 60 * 1000)) return hit.ok;
  try {
    await getDb().createCollection(name);
    ENSURED_COLLECTIONS.set(name, { ok: true, at: now });
    logStage("collection_created", { name });
    return true;
  } catch (e) {
    const msg = String((e && e.message) || e);
    // 已存在（并发创建 / 之前建过）也算成功
    if (/exist/i.test(msg)) {
      ENSURED_COLLECTIONS.set(name, { ok: true, at: now });
      return true;
    }
    ENSURED_COLLECTIONS.set(name, { ok: false, at: now });
    logStage("collection_ensure_failed", { name, err: msg.slice(0, 140) });
    return false;
  }
}

async function readOne(coll, id) {
  try {
    const r = await getDb().collection(coll).doc(id).get();
    return (r && r.data && r.data[0]) || null;
  } catch (e) { return null; }
}

/**
 * 10-24 账务幂等（P0-4）：
 *   ① 用唯一 _id 领取账务事件 —— 重复提交必然失败，天然去重；
 *   ② 账户累计用「CAS 标记 → inc」两步：先原子地把 accountApplied 从 false 改成 true，
 *      只有抢到标记的那一次才执行 inc；inc 失败时回滚标记，下一轮可重试；
 *   ③ 明细 bf_usage_logs 复用同一个 _id —— 重复写入直接失败，不可能出现两条流水。
 *
 * 残余风险（已在交付说明中标注）：CAS 成功后、inc 完成前进程被杀，这一笔会少计。
 * 这里选择「宁可少收、不可重复扣用户」；对账可用事件表重算账户累计。
 */
async function addImageCost(accountId, costCny, meta) {
  const cost = Math.max(0, Number(costCny) || 0);
  const m = meta || {};
  const jobKey = String(m.jobKey || m.jobId || "");
  const eventId = billingEventIdOf(
    accountId,
    jobKey || ("anon-" + Date.now() + "-" + Math.random().toString(36).slice(2, 8))
  );
  await ensureCollection(BILLING_COLL);
  const col = getDb().collection(BILLING_COLL);

  // ① 领取事件（_id 唯一 → 只有一个调用点能成功）
  let isNew = false;
  let ev = null;
  try {
    await col.add({
      _id: eventId, accountId, costCny: cost, model: m.model || "", kind: m.kind || "image",
      jobId: jobKey, parentJobId: m.parentJobId || "",
      index: Number.isFinite(Number(m.index)) ? Number(m.index) : null,
      state: "pending", accountApplied: false, usageApplied: false, ts: new Date(),
    });
    isNew = true;
  } catch (e) {
    ev = await readOne(BILLING_COLL, eventId);
    if (!ev) {
      logStage("billing_event_read_failed", { eventId: eventId.slice(0, 16) });
      return false;
    }
    if (ev.state === "committed") return true;   // 已完全提交：幂等命中
  }

  // ② 账户累计（CAS 抢占，避免重复 inc）
  let accountOk = false;
  if (!isNew && ev && ev.accountApplied) {
    accountOk = true;                            // 上一轮已累加过，跳过
  } else {
    let grabbed = isNew;
    if (!isNew) {
      try {
        const r = await col.where({ _id: eventId, accountApplied: false })
          .update({ accountApplied: true, accountAppliedAt: Date.now() });
        grabbed = Number((r && (r.updated !== undefined ? r.updated : r.updatedCount)) || 0) > 0;
      } catch (e) {
        // 环境不支持条件更新：退化为「先 inc 再标记」，并明确记录这条降级
        logStage("billing_cas_unsupported", { eventId: eventId.slice(0, 16) });
        grabbed = true;
      }
    }
    if (grabbed) {
      if (isNew) {
        try { await col.doc(eventId).update({ accountApplied: true, accountAppliedAt: Date.now() }); }
        catch (e) { /* 标记失败只影响重试效率，不影响本次金额 */ }
      }
      try {
        await getDb().collection(C.accounts).doc(accountId).update({
          imageUsedCny: getDb().command.inc(cost),
          dayUsedCny: getDb().command.inc(cost),
          weekUsedCny: getDb().command.inc(cost),
        });
        accountOk = true;
      } catch (e) {
        try { await col.doc(eventId).update({ accountApplied: false }); } catch (e2) { /* 忽略 */ }
        logStage("billing_account_failed", {
          accountId: String(accountId).slice(0, 24), costCny: cost,
          err: String((e && e.message) || e).slice(0, 120),
        });
      }
    } else {
      logStage("billing_event_busy", { eventId: eventId.slice(0, 16) });
      return false;                              // 交给下一轮 flush 重试
    }
  }

  // ③ 明细：_id 复用事件 ID → 天然去重
  let usageOk = !!(!isNew && ev && ev.usageApplied);
  if (!usageOk) {
    try {
      await getDb().collection(C.usage).add({
        _id: eventId, accountId, kind: "image", costCny: cost, ts: new Date(),
        model: m.model || "unknown", estimated: false, source: "bf-image",
        jobId: jobKey, parentJobId: m.parentJobId || "",
      });
      usageOk = true;
    } catch (e) {
      // 已存在说明上一轮写成功过（唯一 _id 冲突）→ 视为已应用
      usageOk = !!(await readOne(C.usage, eventId));
      if (!usageOk) {
        logStage("billing_usage_failed", {
          accountId: String(accountId).slice(0, 24), costCny: cost,
          err: String((e && e.message) || e).slice(0, 120),
        });
      }
    }
  }

  if (accountOk && usageOk) {
    try {
      await col.doc(eventId).update({ state: "committed", usageApplied: true, committedAt: Date.now() });
    } catch (e) { /* 状态位失败不影响账务正确性 */ }
    return true;
  }
  logStage("billing_commit_incomplete", { eventId: eventId.slice(0, 16), accountOk, usageOk, costCny: cost });
  return false;
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

function normalizeRid(raw) {
  const v = String(raw || "").trim().slice(0, 64);
  // 10-24 P1-4：requestId 必须在**入口**生成一次并全程复用。
  // 旧实现只在 claimIdem 内部给局部变量赋值，调用方的 rid 仍是空串 →
  // finishIdem('') 直接 return，任务永远停在 processing，账也记不上。
  if (v) return v;
  return "srv-" + Date.now().toString(36) + "-" + crypto.randomBytes(5).toString("hex");
}

async function claimIdem(rid, accountId) {
  const id = normalizeRid(rid);
  const key = idemKey(id, accountId);
  const col = getDb().collection(JOB_COLL);
  try {
    await col.add({
      _id: key, clientRequestId: String(id).slice(0, 120), state: "processing",
      accountId, ts: Date.now(), leanSec: Math.floor(Date.now() / 1000),
    });
    return { state: "new", key, rid: id };
  } catch (e) {
    try {
      const r = await col.doc(key).get();
      const d = (r && r.data && r.data[0]) || null;
      // 归属校验：即使 hash 碰撞或旧数据异常，也绝不把别人的结果交出去
      const sameOwner = !d || String(d.accountId || "") === String(accountId);
      if (sameOwner && d && d.state === "done" && Date.now() - Number(d.ts || 0) < IDEM_TTL_MS) {
        // 10-24 P0-3：组图重放必须返回**完整结果**，不能退化成"单图缓存"
        return {
          state: "done", url: d.url, key, rid: id,
          kind: d.kind || "", result: d.result || null, model: d.model || "",
        };
      }
      // 90 秒内仍是 processing：判为并发重复，不重复生成
      if (sameOwner && d && d.state === "processing" && Date.now() - Number(d.ts || 0) < 90 * 1000) {
        return { state: "busy", key, rid: id };
      }
      // 失败或超时：接管这条任务
      await col.doc(key).set({
        clientRequestId: String(id).slice(0, 120), state: "processing", accountId,
        ts: Date.now(), retried: true,
      });
      return { state: "new", key, rid: id };
    } catch (e2) {
      // 台账不可用时仍允许出图（可用性），但不再声称"命中幂等"
      return { state: "none", key, rid: id };
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
async function finishIdem(rid, accountId, url, costCny, model, extra) {
  if (!rid) {
    logStage("idem_finish_no_rid", { accountId: String(accountId).slice(0, 24) });
    return false;
  }
  const key = idemKey(rid, accountId);
  const patch = {
    state: "done", url: url || "", costCny, model, accountId,
    ts: Date.now(), costCommitted: false,
  };
  const ex = extra || {};
  if (ex.kind) patch.kind = String(ex.kind).slice(0, 24);
  if (ex.result) patch.result = ex.result;
  if (ex.parentJobId) patch.parentJobId = String(ex.parentJobId).slice(0, 80);
  if (ex.input) patch.input = ex.input;
  if (Number.isFinite(Number(ex.index))) patch.index = Number(ex.index);
  try {
    const r = await getDb().collection(JOB_COLL).doc(key).update(patch);
    const n = Number((r && (r.updated !== undefined ? r.updated : r.updatedCount)) || 0);
    if (n > 0) return true;
    // update 成功但没命中（文档不存在）：补建。绝不能"更新了不存在的文档"却当成功。
    await getDb().collection(JOB_COLL).doc(key).set(Object.assign({
      clientRequestId: String(rid).slice(0, 120), createdAt: Date.now(),
    }, patch));
    logStage("idem_finish_recreated", { key: key.slice(0, 16) });
    return true;
  } catch (e) {
    logStage("idem_finish_failed", { key: key.slice(0, 16), err: String((e && e.message) || e).slice(0, 120) });
    // 最后兜底：set 建文档。宁可覆盖状态位，也不能让这张图变成"账面不存在"。
    try {
      await getDb().collection(JOB_COLL).doc(key).set(Object.assign({
        clientRequestId: String(rid).slice(0, 120),
      }, patch));
      logStage("idem_finish_recovered", { key: key.slice(0, 16) });
      return true;
    } catch (e2) { return false; }
  }
}

/** 续租：组图 4 张串行可能超过 90s，不续租会被重复请求判为"超时可接管"→ 重复生成 */
async function touchIdem(rid, accountId) {
  if (!rid) return;
  try {
    await getDb().collection(JOB_COLL).doc(idemKey(rid, accountId)).update({ ts: Date.now() });
  } catch (e) { /* 续租失败不影响本次执行 */ }
}

async function abortIdem(rid, accountId, reason) {
  if (!rid) return false;
  const key = idemKey(rid, accountId);
  try {
    await getDb().collection(JOB_COLL).doc(key).update({
      state: "failed", reason: String(reason || "").slice(0, 60), ts: Date.now(),
    });
    return true;
  } catch (e) {
    logStage("idem_abort_failed", { key: key.slice(0, 16), err: String((e && e.message) || e).slice(0, 120) });
    return false;
  }
}

/// 记账补投（outbox）：已完成但未记账的任务，下次请求时补记，最多 3 条，避免长期漏账。
async function flushJobs(maxJobs) {
  try {
    const col = getDb().collection(JOB_COLL);
    // 10-24：组图一次会产生 N 条待提交任务，固定 3 条会让最后几张停在 queued。
    // 调用方可按需放大本轮处理量（默认仍是 3，避免长尾拖慢单图请求）。
    const take = Math.max(1, Math.min(20, Number(maxJobs) || 3));
    const r = await col.where({ state: "done", costCommitted: false }).limit(take).get();
    for (const d of (r && r.data) || []) {
      const id = d._id || d.id;
      if (!id) continue;
      const cost = Number(d.costCny || 0);
      // 零成本任务（命中缓存 / 父任务 / 管理员豁免）直接确认，不需要账本
      // jobKey 必须传：账务事件 ID 由它派生，传错等于每次 flush 都生成新事件（=重复扣费）
      const billed = cost <= 0 ? true : await addImageCost(d.accountId, cost, {
        model: d.model || "unknown",
        jobKey: String(id),
        kind: d.kind || "image",
        parentJobId: d.parentJobId || "",
        index: d.index,
      });
      if (!billed) {
        // 记账失败：保留 costCommitted=false，下一轮重试；同时累加重试次数供告警
        const tries = Number(d.costTries || 0) + 1;
        await col.doc(id).update({ costTries: tries, costLastErrorAt: Date.now() }).catch(() => {});
        logStage("billing_commit_retry", { jobId: String(id).slice(0, 24), tries, costCny: cost });
        continue;
      }
      await col.doc(id).update({ costCommitted: true, committedAt: Date.now() }).catch(() => {});
    }
  } catch (e) {
    // outbox 自己挂了：下一轮请求会再试；这里必须留日志，否则"账一直没记上"无人知晓
    logStage("billing_flush_failed", { err: String((e && e.message) || e).slice(0, 120) });
  }
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
      // 内部诊断字段绝不进响应（reason/detail/raw 可能含模型名、上游原文）。
      // 注意：status 只在它是数字（上游 HTTP 状态）时删除 —— 组图任务的 status 是
      // queued/running/done… 这类业务状态，客户端要靠它渲染，删了会让 409 响应失去上下文。
      delete body.reason;
      delete body.detail;
      if (typeof body.status === "number") delete body.status;
      delete body.raw;
      logSafe({
        tag: "image_error", fn: "bf-image", requestId: rid,
        httpStatus: code, code: pub.error, category: pub.errorDetail.category,
        retryable: pub.errorDetail.retryable, detail: String(obj.msg || "").slice(0, 200),
      });
    }
    res.writeHead(code, { "Content-Type": "application/json; charset=utf-8" });
    res.end(JSON.stringify(body));
  };

  const u = String(req.url || "");

  if (req.method === "GET" && u.indexOf("/ping") >= 0) {
    return send(200, { ok: true, fn: "bf-image" });
  }

  // ── 10-24 P1-5：组图任务（start / step / status / cancel）──
  // 设计要点：云函数是请求驱动的，没有常驻 worker。所以状态机放在数据库，
  // 由客户端「多次 step」驱动（每次 step 只做一张，远低于函数超时），
  // 这样关掉 App 后任务仍在库里，重开可以 status 查询、继续或取消。

  if (req.method === "POST" && u.indexOf("/series/start") >= 0) {
    const tStart = Date.now();
    await refreshRuntime();
    const auth = await requireMember(req);
    if (!auth) return send(401, { ok: false, code: 401, error: "UNAUTHORIZED", msg: "请重新登录" });

    const q = await quotaExhausted(req);
    if (q.denied) return sendDenied(q, send);
    if (q.unavailable) {
      return send(503, {
        ok: false, code: 503, error: "QUOTA_CHECK_UNAVAILABLE",
        msg: "暂时无法确认额度，请稍后重试。这次没有生成图片，也不会扣费。",
      });
    }
    if (q.exhausted) {
      return send(429, {
        ok: false, code: 429, error: "POOL_EXHAUSTED",
        msg: "本月额度已用完，续费后立即恢复。", resetAt: q.resetAt,
      });
    }

    const body = (await readBody(req)) || {};
    const prompt = String(body.prompt || "").trim();
    const hasStructured = !!(body.structured && typeof body.structured === "object" && Object.keys(body.structured).length);
    if (!prompt && !hasStructured) {
      return send(400, { ok: false, code: 400, error: "BAD_REQUEST", msg: "缺少 prompt" });
    }
    if (prompt.length > 1500) {
      return send(400, { ok: false, code: 400, error: "BAD_REQUEST", msg: "描述过长，请精简到 1500 字以内" });
    }

    const n = Math.min(SERIES_MAX, Math.max(2, Math.floor(Number(body.requested_count || body.requestedCount) || 2)));
    const resolved = resolveSize(body.size, body.aspect_ratio || body.aspectRatio);
    const renderIntent = String(body.render_intent || body.renderIntent || "");
    const aspectRatio = String(body.aspect_ratio || body.aspectRatio || "");
    const qualityTier = String(body.quality_tier || body.qualityTier || "auto").trim();
    const clientRid = normalizeRid(body.requestId);
    const taskId = seriesTaskIdOf(auth.sub, clientRid);

    // 幂等：同一 requestId 重复 start 返回同一任务，不新建、不重复预留
    const existing = await readSeriesTask(taskId);
    if (existing) {
      return send(200, Object.assign(seriesTaskPayload(existing), { idempotent: true, ms: Date.now() - tStart }));
    }

    const models = modelsOf();
    const unitWorst = Math.max(
      priceForSize(resolved, models.pro || RT.IMAGE_MODEL),
      priceForSize(resolved, models.fast || RT.IMAGE_MODEL)
    );
    const need = Number((unitWorst * n).toFixed(4));
    if (typeof q.remainingCny === "number" && q.remainingCny + 1e-6 < need) {
      logStage("series_start_quota_short", { sub: auth.sub, n, remaining: q.remainingCny, need });
      return send(402, {
        ok: false, code: 402, error: "QUOTA_INSUFFICIENT",
        msg: `本次要生成 ${n} 张，剩余额度不足以覆盖（约需 ¥${need.toFixed(2)}）。可以先做 1 张，或续费后再试。`,
        requested: n, remainingCny: q.remainingCny, needCny: need,
        actions: ["single_only", "renew", "cancel"],
      });
    }

    const pendingIndices = [];
    for (let i = 1; i <= n; i++) pendingIndices.push(i);
    const doc = {
      _id: taskId,
      accountId: auth.sub,
      clientRequestId: clientRid,
      requested: n,
      status: "queued",
      items: new Array(n).fill(null),
      prompt: prompt.slice(0, 1600),
      structured: hasStructured ? body.structured : null,
      size: String(body.size || ""),
      sizeResolved: resolved,
      renderIntent, aspectRatio, qualityTier,
      hasImage: !!body.image,
      reservedCny: need,
      succeeded: 0,
      failedIndices: [],
      pendingIndices,
      createdAt: Date.now(),
      updatedAt: Date.now(),
      expiresAt: Date.now() + 24 * 3600 * 1000,
    };
    try {
      await ensureCollection(SERIES_COLL);
      await getDb().collection(SERIES_COLL).add(doc);
    } catch (e) {
      // 并发 start：另一个请求刚建好 → 返回已有的那份
      const again = await readSeriesTask(taskId);
      if (again) return send(200, Object.assign(seriesTaskPayload(again), { idempotent: true }));
      logStage("series_start_create_failed", { sub: auth.sub, err: String((e && e.message) || e).slice(0, 120) });
      return send(500, { ok: false, code: 500, error: "INTERNAL", msg: "任务创建失败，请稍后重试。" });
    }
    await reserveQuota(taskId, auth.sub, need);
    logStage("series_started", { sub: auth.sub, taskId: taskId.slice(0, 16), n, need });
    return send(200, Object.assign(seriesTaskPayload(doc), { ms: Date.now() - tStart }));
  }

  if (req.method === "POST" && u.indexOf("/series/step") >= 0) {
    const tStep = Date.now();
    await refreshRuntime();
    const auth = await requireMember(req);
    if (!auth) return send(401, { ok: false, code: 401, error: "UNAUTHORIZED", msg: "请重新登录" });
    const body = (await readBody(req)) || {};
    const taskId = String(body.taskId || "").trim().slice(0, 64);
    if (!taskId) return send(400, { ok: false, code: 400, error: "BAD_REQUEST", msg: "缺少 taskId" });

    let task = await readSeriesTask(taskId);
    if (!task) {
      return send(404, { ok: false, code: 404, error: "SERIES_NOT_FOUND", msg: "没有找到这次组图任务，请重新开始。" });
    }
    if (String(task.accountId || "") !== String(auth.sub)) {
      return send(403, { ok: false, code: 403, error: "FORBIDDEN", msg: "这个任务不属于当前账号。" });
    }

    const requested = Number(task.requested || 0);
    const idx = Number(body.index);
    if (!Number.isInteger(idx) || idx < 1 || idx > requested) {
      return send(400, { ok: false, code: 400, error: "BAD_REQUEST", msg: "序号超出范围" });
    }

    // 已取消：不再启动新的生成
    if (task.status === "cancelled") {
      return send(409, Object.assign(seriesTaskPayload(task), { code: 409, error: "TASK_CANCELLED" }));
    }

    // 幂等：这一张已经成功，或整个任务已经结束 → 直接返回当前状态
    const existing = (Array.isArray(task.items) ? task.items : [])[idx - 1];
    if (existing && existing.ok) {
      return send(200, Object.assign(seriesTaskPayload(task), { step: idx, reused: true, ms: Date.now() - tStep }));
    }
    if (["done", "failed", "partial"].includes(task.status)) {
      return send(200, Object.assign(seriesTaskPayload(task), { step: idx, reused: true, ms: Date.now() - tStep }));
    }

    try {
      const item = await executeSeriesStep(task, idx, auth.sub);
      await flushJobs(2);
      // 记账状态回读：queued → committed 必须反映到 items 上，否则客户端显示的金额不可信
      if (item && item.ok) {
        const child = await readOne(JOB_COLL, idemKey(task._id + "::s" + idx, auth.sub));
        item.costState = child && child.costCommitted ? "committed" : (child ? "queued" : "pending");
        await recordSeriesItem(task._id, idx, item);
      }
      const updated = await refreshTaskState(task._id);
      logStage("series_step_done", {
        sub: auth.sub, taskId: taskId.slice(0, 16), index: idx,
        ok: !!(item && item.ok), status: (updated && updated.status) || "",
        ms: Date.now() - tStep,
      });
      return send(200, Object.assign(seriesTaskPayload(updated || task), { step: idx, ms: Date.now() - tStep }));
    } catch (e) {
      logStage("series_step_failed", { index: idx, err: String((e && e.message) || e).slice(0, 160) });
      return send(500, { ok: false, code: 500, error: "INTERNAL", msg: "这一张执行出错，可以稍后重试。" });
    }
  }

  if (req.method === "GET" && u.indexOf("/series/status") >= 0) {
    await refreshRuntime();
    const auth = await requireMember(req);
    if (!auth) return send(401, { ok: false, code: 401, error: "UNAUTHORIZED", msg: "请重新登录" });
    const m = u.match(/[?&]taskId=([^&]+)/);
    const taskId = m ? decodeURIComponent(m[1]).slice(0, 64) : "";
    if (!taskId) return send(400, { ok: false, code: 400, error: "BAD_REQUEST", msg: "缺少 taskId" });
    const task = await readSeriesTask(taskId);
    if (!task || String(task.accountId || "") !== String(auth.sub)) {
      return send(404, { ok: false, code: 404, error: "SERIES_NOT_FOUND", msg: "没有找到这次组图任务。" });
    }
    // 读的时候顺手把 pending/status 修正一遍（上一轮可能写到一半）
    const fixed = await refreshTaskState(taskId);
    return send(200, seriesTaskPayload(fixed || task));
  }

  if (req.method === "POST" && u.indexOf("/series/cancel") >= 0) {
    await refreshRuntime();
    const auth = await requireMember(req);
    if (!auth) return send(401, { ok: false, code: 401, error: "UNAUTHORIZED", msg: "请重新登录" });
    const body = (await readBody(req)) || {};
    const taskId = String(body.taskId || "").trim().slice(0, 64);
    if (!taskId) return send(400, { ok: false, code: 400, error: "BAD_REQUEST", msg: "缺少 taskId" });
    const task = await readSeriesTask(taskId);
    if (!task || String(task.accountId || "") !== String(auth.sub)) {
      return send(404, { ok: false, code: 404, error: "SERIES_NOT_FOUND", msg: "没有找到这次组图任务。" });
    }
    const finished = ["done", "partial", "failed", "cancelled"].includes(task.status);
    if (!finished) {
      try {
        await getDb().collection(SERIES_COLL).doc(taskId).update({
          status: "cancelled", cancelledAt: Date.now(), updatedAt: Date.now(),
        });
      } catch (e) { /* 取消失败：不阻断，用户重试 */ }
      await releaseQuota(taskId, "cancelled");
    }
    const updated = await readSeriesTask(taskId);
    logStage("series_cancel", { sub: auth.sub, taskId: taskId.slice(0, 16), alreadyFinished: finished });
    return send(200, Object.assign(seriesTaskPayload(updated || task), { cancelled: !finished }));
  }

  // ── 10-24 新增：只重试失败的子图（P0-2/P1-5 的最小可用闭环）──
  // 语义：成功的子任务保持不动（claim 命中 done 直接复用），失败的按原 input 重跑；
  // 每张仍有独立 requestId 与独立账务事件，不会重复扣费。
  if (req.method === "POST" && u.indexOf("/series/retry") >= 0) {
    const tRetry = Date.now();
    await refreshRuntime();
    const auth = await requireMember(req);
    if (!auth) return send(401, { ok: false, code: 401, error: "UNAUTHORIZED", msg: "请重新登录" });
    await flushJobs();
    const q = await quotaExhausted(req);
    if (q.denied) return sendDenied(q, send);
    if (q.unavailable) {
      return send(503, {
        ok: false, code: 503, error: "QUOTA_CHECK_UNAVAILABLE",
        msg: "暂时无法确认额度，请稍后重试。这次没有生成图片，也不会扣费。",
      });
    }
    if (q.exhausted) {
      return send(429, {
        ok: false, code: 429, error: "POOL_EXHAUSTED",
        msg: "本月额度已用完，续费后立即恢复。", resetAt: q.resetAt,
      });
    }
    const body = (await readBody(req)) || {};
    const parentRid = normalizeRid(body.requestId || body.parentRequestId);
    const rec = await readOne(JOB_COLL, idemKey(parentRid, auth.sub));
    const prev = rec && rec.result;
    const input = rec && rec.input;
    if (!prev || prev.task_kind !== "series" || !input) {
      return send(404, {
        ok: false, code: 404, error: "SERIES_NOT_FOUND",
        msg: "没有找到这次组图任务的记录，请重新生成。",
      });
    }
    if (input.hasImage) {
      return send(422, {
        ok: false, code: 422, error: "TASK_UNSUPPORTED",
        msg: "这组图是基于参考图生成的，暂时无法单独补画。请重新生成整组。",
        actions: ["retry", "cancel"],
      });
    }
    const wanted = Array.isArray(body.indices) && body.indices.length
      ? body.indices
      : (prev.failedIndices || []);
    const targets = Array.from(new Set(wanted
      .map((x) => Number(x))
      .filter((i) => Number.isInteger(i) && i >= 1 && i <= Number(prev.requested || 0))));
    if (!targets.length) {
      return send(200, Object.assign({}, prev, {
        ok: true, retriedIndices: [], cached: true, cost: 0, ms: Date.now() - tRetry,
      }));
    }
    const resolved = resolveSize(input.size, input.aspectRatio);
    // 防御：历史/畸形 result 不能让整个接口 500
    const prevItems = Array.isArray(prev.items) ? prev.items : [];
    const byIndex = new Map(prevItems.map((it) => [Number(it.index), it]));
    for (const i of targets) {
      const item = await runSeriesChild({
        parentRid, index: i, total: Number(prev.requested || targets.length),
        accountId: auth.sub,
        prompt: input.prompt, image: undefined, size: input.size,
        structured: input.structured, renderIntent: input.renderIntent,
        aspectRatio: input.aspectRatio, qualityTier: input.qualityTier, resolved,
      });
      // 重试成功后替换该项；重试仍失败保留最新的失败信息
      byIndex.set(i, item);
    }
    await flushJobs(targets.length + 2);
    const merged = Array.from(byIndex.values()).sort((a, b) => Number(a.index) - Number(b.index));
    await refreshSeriesCostStates(parentRid, auth.sub, merged);
    const requested = Number(prev.requested || merged.length);
    const payload = seriesPayload(merged, requested, {
      requestId: parentRid, size: resolved, qualityTier: input.qualityTier,
      ms: Date.now() - tRetry,
    });
    payload.retriedIndices = targets;
    // 重写父任务结果：下次重放拿到的是**合并后**的完整结果
    await finishIdem(parentRid, auth.sub, (merged.find((x) => x.ok) || {}).url || "", 0, "series",
      { kind: "series", result: payload, input });
    logStage("series_retry_done", {
      sub: auth.sub, parentRid, targets, okCount: payload.succeeded,
      committedCny: payload.committedCny, ms: Date.now() - tRetry,
    });
    return send(200, payload);
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
    // 10-24 P1-2：不可用 ≠ 用完。服务故障时告诉用户"续费"是错误引导，
    // 正确做法是 503 + 可重试文案，并且明确"这次没有生成、不会扣费"。
    if (q.denied) return sendDenied(q, send);
    if (q.unavailable) {
      logStage("quota_check_unavailable", { sub: auth.sub, reason: q.reason });
      return send(503, {
        ok: false, code: 503, error: "QUOTA_CHECK_UNAVAILABLE",
        msg: "暂时无法确认额度，请稍后重试。这次没有生成图片，也不会扣费。",
      });
    }
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
    // 10-24 P1-4：rid 在这里生成一次，后续 finish/abort/记账全部复用同一个值。
    const rid = normalizeRid(body.requestId);
    const claim = await claimIdem(rid, auth.sub);
    if (claim.state === "done") {
      logStage("idempotent_hit", { sub: auth.sub, rid, kind: claim.kind || "image" });
      // 10-24 P0-3：组图重放必须返回完整 items[]，不能退化成"单图缓存"
      if (claim.result && claim.result.task_kind === "series") {
        return send(200, Object.assign({}, claim.result, {
          cached: true, cost: 0, ms: Date.now() - tReq, requestId: rid,
        }));
      }
      return send(200, {
        ok: true, url: claim.url, cached: true, cost: 0,
        ms: Date.now() - tReq, requestId: rid,
      });
    }
    if (claim.state === "busy") {
      logStage("idempotent_busy", { sub: auth.sub, rid });
      return send(409, {
        ok: false, code: 409, error: "IN_PROGRESS",
        msg: "同一张图还在生成中，请稍候再试", retryAfterSec: 30,
      });
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
    // ── 组图：服务端编排（拆 N 个单图子任务，各自 claim / 记账 / 可部分成功）──
    if (taskKind === "series") {
      const n = Math.min(SERIES_MAX, Math.max(2, Math.floor(Number(requestedCount) || 2)));
      const resolved = resolveSize(body.size, aspectRatio);
      const models = modelsOf();
      // 10-24 P1-12：先按最贵档估算，余额不足就不启动任何子图 ——
      // 否则 4 张跑完才发现额度不够，用户拿到半套、账也乱。
      const unitWorst = Math.max(
        priceForSize(resolved, models.pro || RT.IMAGE_MODEL),
        priceForSize(resolved, models.fast || RT.IMAGE_MODEL)
      );
      const cap = Number(q.capCny);
      const used = Number(q.usedCny);
      if (Number.isFinite(cap) && cap > 0 && Number.isFinite(used)) {
        const remaining = cap - used;
        if (remaining + 1e-6 < unitWorst * n) {
          await abortIdem(rid, auth.sub, "quota_insufficient");
          logStage("series_quota_short", { sub: auth.sub, n, remaining, need: unitWorst * n });
          return send(402, {
            ok: false, code: 402, error: "QUOTA_INSUFFICIENT",
            msg: `本次要生成 ${n} 张，剩余额度不足以覆盖（约需 ¥${(unitWorst * n).toFixed(2)}）。可以先做 1 张，或续费后再试。`,
            requested: n, remainingCny: Number(remaining.toFixed(4)),
            needCny: Number((unitWorst * n).toFixed(4)),
            actions: ["single_only", "renew", "cancel"],
          });
        }
      }

      const items = [];
      const tSeries = Date.now();
      for (let i = 1; i <= n; i++) {
        // 每张开始前续租父任务（P1-5：90s lease 与 4 张串行时长不匹配）
        if (i > 1) await touchIdem(rid, auth.sub);
        const item = await runSeriesChild({
          parentRid: rid, index: i, total: n, accountId: auth.sub,
          prompt: body.prompt, image: body.image, size: body.size,
          structured: body.structured, renderIntent, aspectRatio,
          qualityTier, resolved,
        });
        items.push(item);
      }
      await flushJobs(n + 2);
      await refreshSeriesCostStates(rid, auth.sub, items);

      const okCount = items.filter((x) => x.ok).length;
      const payloadBody = seriesPayload(items, n, {
        requestId: rid, size: resolved, qualityTier, ms: Date.now() - t0,
      });
      // 全失败：不落 done（否则用户永远没法重试整组），abort 让下一次可以重新开始
      if (okCount === 0) {
        await abortIdem(rid, auth.sub, "series_all_failed");
        logStage("series_failed", { sub: auth.sub, n, ms: Date.now() - tSeries });
        const e = publicError("SERIES_ALL_FAILED", { requestId: rid, stage: "series" });
        return send(502, Object.assign(e, payloadBody, { ok: false }));
      }

      // 父任务：costCny=0（钱记在子任务上，避免重复计费），但必须持久化**完整结果**
      const parentSaved = await finishIdem(
        rid, auth.sub, (items.find((x) => x.ok) || {}).url || "", 0, "series",
        {
          kind: "series",
          result: payloadBody,
          // 重试失败项需要原始输入。图片引用（data URL）不存：体积大且可能过期，
          // 带参考图的组图在重试时会明确提示"需要重新生成整组"。
          input: {
            prompt: String(body.prompt || "").slice(0, 1600),
            structured: body.structured || null,
            size: String(body.size || ""),
            renderIntent, aspectRatio, qualityTier,
            hasImage: !!body.image,
          },
        }
      );
      if (!parentSaved) {
        logStage("series_parent_persist_failed", { sub: auth.sub, n });
      }
      logStage("series_done", {
        sub: auth.sub, n, okCount, pricedCny: payloadBody.pricedCny,
        committedCny: payloadBody.committedCny, ms: Date.now() - tSeries,
      });
      return send(200, Object.assign(payloadBody, { parentPersisted: parentSaved }));
    }

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
        task_kind: taskKind, quality_tier: qualityTier, requestId: rid,
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
