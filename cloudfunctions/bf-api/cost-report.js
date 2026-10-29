// cost-report.js —— 成本看板的纯聚合层（2026-10-25）
//
// 为什么单独抽出来：原来的聚合写在 handleCostReport 里，只能靠"读源码"验证，
// 而成本口径恰恰是最容易算错、又最需要被测试钉死的地方。
// 现在它是纯函数：输入账务行 + 时间窗，输出报表对象，可以直接 node --test。
//
// 口径约定（写进代码，别再靠口头解释）：
//   · 账务事件 = 一行 bf_usage_logs；`ledgerEvents` 是去重后的条数。
//   · 用户请求 = 唯一 requestId/jobId 的个数；父组图任务通常是 0 元行，**不进均价分母**。
//   · 金额单位统一人民币元；内部按 1e-8 元整数单位累加，保留小额 Token 费用，避免浮点误差。
//   · 时间窗半开区间 [start, end)；日期键一律 ISO（YYYY-MM-DD），时区固定 Asia/Shanghai。

const MONEY_SCALE = 1e8; // 每笔不足一分钱的 Token 成本不可先舍入为零。
const TZ_OFFSET_MS = 8 * 3600 * 1000; // Asia/Shanghai，无夏令时

/** 把任意形态的时间字段归一成毫秒（兼容 Date / number / string / {$date}）。 */
function tsMsOf(value) {
  if (value == null) return null;
  if (value instanceof Date) return value.getTime();
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string") {
    const n = Number(value);
    if (Number.isFinite(n)) return n;
    const parsed = Date.parse(value);
    return Number.isFinite(parsed) ? parsed : null;
  }
  if (typeof value === "object" && value.$date != null) return tsMsOf(value.$date);
  if (typeof value === "object" && typeof value.getTime === "function") {
    try { return value.getTime(); } catch (e) { return null; }
  }
  return null;
}

/** 账务行 → 统一口径（未知字段保留为 unknown，不猜 chat/plus） */
function normalizeRow(row) {
  const raw = row || {};
  const kindRaw = String(raw.kind || "").trim().toLowerCase();
  const kind = kindRaw === "image" ? "image" : (kindRaw === "chat" ? "chat" : "unknown");
  const costCny = Number(raw.costCny);
  return {
    id: String(raw._id || raw.usageEventId || ""),
    eventId: String(raw.usageEventId || raw._id || ""),
    accountId: String(raw.accountId || ""),
    kind,
    taskType: String(raw.taskType || ""),
    requestId: String(raw.requestId || raw.jobId || ""),
    model: String(raw.model || ""),
    tier: String(raw.tier || raw.qualityTier || ""),
    state: String(raw.state || "committed"),
    costCny: Number.isFinite(costCny) && costCny > 0 ? costCny : 0,
    // 售价（可选）：只有新版图片流水才带。老数据没有这个字段，绝不按成本去猜售价。
    priceCny: Number.isFinite(Number(raw.priceCny)) && Number(raw.priceCny) > 0 ? Number(raw.priceCny) : null,
    tsMs: tsMsOf(raw.ts) ?? tsMsOf(raw.createdAt),
  };
}

function isoDayKey(ms) {
  const d = new Date(ms + TZ_OFFSET_MS);
  const y = d.getUTCFullYear();
  const m = String(d.getUTCMonth() + 1).padStart(2, "0");
  const day = String(d.getUTCDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}

/** 从 start 到 end（不含）逐日生成完整日期序列——零成本日期也要在轴上 */
function daySeries(startMs, endMs) {
  const out = [];
  const step = 86400000;
  let cursor = Math.floor((startMs + TZ_OFFSET_MS) / step) * step - TZ_OFFSET_MS;
  while (cursor < endMs) {
    out.push(isoDayKey(cursor));
    cursor += step;
  }
  return out;
}

function round4(v) { return Number(v.toFixed(4)); }
function roundMoney(v) { return Number(v.toFixed(8)); }

/**
 * 聚合。
 * @param {Array} rows 账务行（可含时间窗外数据，函数内会过滤）
 * @param {{startMs:number,endMs:number,truncated?:boolean,queryMs?:number}} opts
 */
function aggregateCostRows(rows, opts) {
  const startMs = Number(opts && opts.startMs) || 0;
  const endMs = Number(opts && opts.endMs) || Date.now();
  const input = Array.isArray(rows) ? rows : [];

  const seen = new Set();
  const events = [];
  let outOfWindow = 0;
  let noTimestamp = 0;
  for (const raw of input) {
    const r = normalizeRow(raw);
    if (!r.id && !r.eventId) continue;
    const key = r.eventId || r.id;
    if (seen.has(key)) continue;          // 同一事件 ID 只计一次
    seen.add(key);
    if (r.tsMs == null) { noTimestamp++; continue; }
    if (r.tsMs < startMs || r.tsMs >= endMs) { outOfWindow++; continue; }
    events.push(r);
  }

  let totalUnits = 0;
  const byKindC = {}, byTierC = {}, byModelC = {}, byAccountC = {}, byDayC = {};
  const requestIds = new Set();
  let imageCount = 0;
  let failedCount = 0;
  let zeroCostEvents = 0;
  let revenueUnits = 0;
  let pricedEvents = 0;

  for (const e of events) {
    const units = Math.round(e.costCny * MONEY_SCALE);
    totalUnits += units;
    const add = (bag, key) => { bag[key] = (bag[key] || 0) + units; };
    add(byKindC, e.kind);
    add(byTierC, e.tier || "unknown");
    add(byModelC, e.model || "unknown");
    add(byAccountC, e.accountId || "unassigned");
    add(byDayC, isoDayKey(e.tsMs));
    if (e.requestId) requestIds.add(e.requestId);
    if (e.kind === "image") imageCount += 1;
    if (e.state === "failed" || e.state === "reconciliation_required") failedCount += 1;
    if (units === 0) zeroCostEvents += 1;
    if (e.priceCny != null) { revenueUnits += Math.round(e.priceCny * MONEY_SCALE); pricedEvents += 1; }
  }

  const toObj = (bag) => Object.fromEntries(Object.entries(bag).map(([k, v]) => [k, roundMoney(v / MONEY_SCALE)]));
  const totalCny = roundMoney(totalUnits / MONEY_SCALE);

  const days = daySeries(startMs, endMs);
  const byDay = days.map((date) => ({ date, cost: roundMoney((byDayC[date] || 0) / MONEY_SCALE) }));

  // TOP 客户：占比是"占全部成本"，同时给出覆盖率，避免把 TOP10 当全体
  const accountEntries = Object.entries(byAccountC).sort((a, b) => b[1] - a[1]);
  const topN = accountEntries.filter(([k]) => k !== "unassigned").slice(0, 10);
  const topAccountsCostUnits = topN.reduce((s, [, v]) => s + v, 0);
  const unassignedUnits = byAccountC.unassigned || 0;

  // 守恒校验：分组之和应等于总额（按整数单位计算，理论上恒等；不等于就是代码出错）
  const sumKinds = Object.values(byKindC).reduce((a, b) => a + b, 0);
  const sumTiers = Object.values(byTierC).reduce((a, b) => a + b, 0);
  const sumModels = Object.values(byModelC).reduce((a, b) => a + b, 0);

  return {
    windowStartIso: new Date(startMs).toISOString(),
    windowEndIso: new Date(endMs).toISOString(),
    timeZone: "Asia/Shanghai",
    rowCount: input.length,           // 查到的原始行数（含重复/越界）
    ledgerEvents: events.length,      // 去重且在窗口内的事件数
    requestCount: requestIds.size,    // 唯一请求数（父任务 0 元行不参与均价）
    imageCount,
    failedCount,
    zeroCostEvents,
    dropped: { duplicated: input.length - seen.size, outOfWindow, noTimestamp },
    totalCny,
    avgCnyPerLedgerEvent: events.length ? roundMoney(totalCny / events.length) : 0,
    avgCnyPerRequest: requestIds.size ? roundMoney(totalCny / requestIds.size) : 0,
    // 售价与毛利：只统计带 priceCny 的流水（新版图片流水）。拿不到售价的旧数据不进分母。
    revenueCny: roundMoney(revenueUnits / MONEY_SCALE),
    marginCny: roundMoney((revenueUnits - events.filter((e) => e.priceCny != null)
      .reduce((s2, e) => s2 + Math.round(e.costCny * MONEY_SCALE), 0)) / MONEY_SCALE),
    pricedEvents,
    byKind: toObj(byKindC),
    byTier: toObj(byTierC),
    byModel: toObj(byModelC),
    byDay,
    topAccounts: topN.map(([accountId, units]) => ({ accountId, cost: roundMoney(units / MONEY_SCALE) })),
    topAccountsCostCny: roundMoney(topAccountsCostUnits / MONEY_SCALE),
    topAccountsCoverage: totalUnits ? round4(topAccountsCostUnits / totalUnits) : 0,
    unassignedCostCny: roundMoney(unassignedUnits / MONEY_SCALE),
    conservation: {
      kindsMatch: sumKinds === totalUnits,
      tiersMatch: sumTiers === totalUnits,
      modelsMatch: sumModels === totalUnits,
    },
    truncated: !!(opts && opts.truncated),
    queryMs: Number((opts && opts.queryMs) || 0),
  };
}

module.exports = { aggregateCostRows, tsMsOf, isoDayKey, daySeries, normalizeRow };
