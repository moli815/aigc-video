// ============================================================================
// cost-report.test.js —— 成本看板聚合口径（2026-10-25 全项目审查 §1）
//
// 这是真单测：直接 require 聚合层跑数据，不是"读源码找字符串"。
// 钉死的口径：
//   · 账务事件数 ≠ 用户请求数（父组图 0 元行不进均价分母）
//   · 同一 usageEventId 只计一次
//   · 时间窗是半开区间 [start, end)，边界外的必须被丢
//   · 缺 model/tier/accountId 进 unknown/unassigned，不能丢成本
//   · 分组之和必须等于总额（守恒）
//   · 日期序列要含零值日期且升序
// ============================================================================

const test = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");

const { aggregateCostRows, tsMsOf } = require(path.join(
  __dirname, "../cloudfunctions/bf-api/cost-report.js"));

const T0 = Date.parse("2026-10-20T00:00:00+08:00");
const WINDOW = { startMs: T0, endMs: T0 + 3 * 86400000 }; // 10/20 ~ 10/22（不含 10/23）

test("micro-token costs are summed before display rounding instead of discarded per call", () => {
  const rows = Array.from({length:500},(_,i)=>({_id:String(i),requestId:String(i),kind:"chat",costCny:0.0000035,priceCny:0.000007,ts:new Date(T0+1)}));
  const r=aggregateCostRows(rows,WINDOW);
  assert.equal(r.totalCny,0.00175); assert.equal(r.revenueCny,0.0035); assert.equal(r.marginCny,0.00175);
  assert.equal(r.avgCnyPerRequest,0.0000035); assert.equal(r.zeroCostEvents,0); assert.equal(r.byKind.chat,0.00175);
});

// 说明：usageEventId 默认跟随 _id —— 每行代表一个独立账务事件。
// 只有显式传 usageEventId 时才会触发去重（COST-02 用它构造重复事件）。
function row(over) {
  const merged = Object.assign({
    _id: "e1", accountId: "acc1", kind: "chat",
    model: "deepseek-v4.1-flash", tier: "standard", costCny: 1.5,
    requestId: "req1", state: "committed", ts: T0 + 3600000,
  }, over || {});
  merged.usageEventId = (over && over.usageEventId) || merged._id;
  return merged;
}

test("COST-01 空账本：0 元、0 事件、无异常", () => {
  const r = aggregateCostRows([], WINDOW);
  assert.equal(r.totalCny, 0);
  assert.equal(r.ledgerEvents, 0);
  assert.equal(r.requestCount, 0);
  assert.deepEqual(r.conservation, { kindsMatch: true, tiersMatch: true, modelsMatch: true });
});

test("COST-02 重复 usageEventId 只计一次", () => {
  const rows = [row({ _id: "same", usageEventId: "same", costCny: 2 }),
                row({ _id: "same-dup", usageEventId: "same", costCny: 2 })];
  const r = aggregateCostRows(rows, WINDOW);
  assert.equal(r.totalCny, 2, "同一事件重复写入不能翻倍");
  assert.equal(r.ledgerEvents, 1);
  assert.equal(r.dropped.duplicated, 1);
});

test("COST-03 账务事件数 ≠ 用户请求数（父任务 0 元行不进均价分母）", () => {
  const rows = [
    row({ _id: "p", usageEventId: "p", requestId: "reqA", kind: "image", costCny: 0 }),
    row({ _id: "c1", usageEventId: "c1", requestId: "reqA", kind: "image", costCny: 0.3 }),
    row({ _id: "c2", usageEventId: "c2", requestId: "reqA", kind: "image", costCny: 0.3 }),
  ];
  const r = aggregateCostRows(rows, WINDOW);
  assert.equal(r.ledgerEvents, 3, "账务事件按行计");
  assert.equal(r.requestCount, 1, "用户请求按 requestId 去重");
  assert.equal(r.totalCny, 0.6);
  assert.equal(r.avgCnyPerRequest, 0.6, "均价分母应是请求数，不是 3");
  assert.equal(r.avgCnyPerLedgerEvent, 0.2);
  assert.equal(r.zeroCostEvents, 1);
});

test("COST-04 chat 与 image 分组之和等于总额", () => {
  const rows = [
    row({ _id: "a", costCny: 1.11, kind: "chat" }),
    row({ _id: "b", costCny: 2.22, kind: "image" }),
  ];
  const r = aggregateCostRows(rows, WINDOW);
  assert.equal(r.totalCny, 3.33);
  assert.equal(r.byKind.chat, 1.11);
  assert.equal(r.byKind.image, 2.22);
  assert.ok(r.conservation.kindsMatch);
});

test("COST-05 缺字段进 unknown/unassigned，不丢成本", () => {
  const rows = [
    row({ _id: "x", costCny: 1, kind: "给钱了但没写kind", model: "", tier: "", accountId: "" }),
    row({ _id: "y", costCny: 2, kind: "chat", model: "m1", tier: "high", accountId: "acc1" }),
  ];
  const r = aggregateCostRows(rows, WINDOW);
  assert.equal(r.totalCny, 3);
  assert.equal(r.byKind.unknown, 1);
  assert.equal(r.byModel.unknown, 1);
  assert.equal(r.byTier.unknown, 1);
  assert.equal(r.unassignedCostCny, 1);
  assert.ok(r.conservation.tiersMatch, "unknown 也要算进守恒");
});

test("COST-06 时间窗是半开区间 [start, end)", () => {
  const rows = [
    row({ _id: "before", usageEventId: "before", ts: WINDOW.startMs - 1 }),
    row({ _id: "atStart", usageEventId: "atStart", ts: WINDOW.startMs }),
    row({ _id: "inside", usageEventId: "inside", ts: WINDOW.startMs + 86400000 }),
    row({ _id: "atEnd", usageEventId: "atEnd", ts: WINDOW.endMs }),
    row({ _id: "after", usageEventId: "after", ts: WINDOW.endMs + 1 }),
  ];
  const r = aggregateCostRows(rows, WINDOW);
  assert.equal(r.ledgerEvents, 2, "恰好 start 计入，恰好 end 不计入");
  assert.equal(r.dropped.outOfWindow, 3);
});

test("COST-07 时间字段形态混用也能算（Date / number / string / {$date}）", () => {
  const rows = [
    row({ _id: "d1", usageEventId: "d1", ts: new Date(T0 + 1000), costCny: 1 }),
    row({ _id: "d2", usageEventId: "d2", ts: T0 + 2000, costCny: 1 }),
    row({ _id: "d3", usageEventId: "d3", ts: String(T0 + 3000), costCny: 1 }),
    row({ _id: "d4", usageEventId: "d4", ts: { $date: T0 + 4000 }, costCny: 1 }),
    row({ _id: "d5", usageEventId: "d5", ts: null, costCny: 9 }),
  ];
  const r = aggregateCostRows(rows, WINDOW);
  assert.equal(r.totalCny, 4, "四种时间形态都要计入");
  assert.equal(r.dropped.noTimestamp, 1, "没有时间的行被单独统计，不混进金额");
});

test("COST-08 6000 行不静默截断（安全上限由调用方标记）", () => {
  const rows = Array.from({ length: 6000 }, (_, i) => row({
    _id: "r" + i, usageEventId: "r" + i, requestId: "req" + i, costCny: 0.01, ts: T0 + 1000,
  }));
  const r = aggregateCostRows(rows, WINDOW);
  assert.equal(r.ledgerEvents, 6000, "聚合层不做 5000 行截断");
  assert.equal(r.totalCny, 60);
  const flagged = aggregateCostRows(rows, Object.assign({}, WINDOW, { truncated: true }));
  assert.equal(flagged.truncated, true, "调用方说截断就要透传，UI 才能提示不完整");
});

test("COST-09 日期序列包含零值日期且按时间升序", () => {
  const rows = [row({ _id: "z", usageEventId: "z", ts: T0 + 3600000, costCny: 1 })];
  const r = aggregateCostRows(rows, WINDOW);
  const dates = r.byDay.map((d) => d.date);
  assert.deepEqual(dates, ["2026-10-20", "2026-10-21", "2026-10-22"], "ISO 日期 + 完整序列");
  assert.equal(r.byDay[0].cost, 1);
  assert.equal(r.byDay[1].cost, 0, "零成本日期要在轴上，值为 0");
});

test("COST-10 TOP 客户覆盖率与未归属成本", () => {
  const rows = [
    row({ _id: "a", usageEventId: "a", accountId: "acc1", costCny: 3 }),
    row({ _id: "b", usageEventId: "b", accountId: "acc2", costCny: 1 }),
    row({ _id: "c", usageEventId: "c", accountId: "", costCny: 4 }),
  ];
  const r = aggregateCostRows(rows, WINDOW);
  assert.equal(r.totalCny, 8);
  assert.equal(r.topAccountsCostCny, 4);
  assert.equal(r.topAccountsCoverage, 0.5, "TOP 覆盖率 = TOP 成本 / 全部成本");
  assert.equal(r.unassignedCostCny, 4);
});

test("COST-11 tsMsOf 对脏数据返回 null 而不是 NaN", () => {
  assert.equal(tsMsOf("不是时间"), null);
  assert.equal(tsMsOf(undefined), null);
  assert.equal(tsMsOf(NaN), null);
  assert.equal(tsMsOf(new Date(0)), 0);
});

// ── 源码契约（处理器层，聚合层已由上面的单测覆盖）────────────────────────────
const fs = require("node:fs");
const API = fs.readFileSync(path.join(__dirname, "../cloudfunctions/bf-api/index.js"), "utf8");

test("COST-12 查询失败必须报错，不得伪装成零成本", () => {
  const start = API.indexOf("async function handleCostReport");
  const body = API.slice(start, start + 2600);
  assert.doesNotMatch(body, /catch \{\s*\/\* 查询失败返回空报表 \*\/\s*\}/, "仍在吞异常");
  assert.match(body, /COST_REPORT_QUERY_FAILED/, "缺少明确的查询失败错误码");
  assert.match(body, /sendError\(res, 500/, "查询失败未返回 5xx");
});

test("COST-13 报表必须带完整性状态与生成时间", () => {
  const start = API.indexOf("async function handleCostReport");
  const body = API.slice(start, start + 2600);
  for (const key of ["dataStatus", "generatedAt", "callsSemantics"]) {
    assert.ok(body.includes(key), `缺少 ${key}`);
  }
  assert.match(body, /truncated \? "truncated" : "complete"/, "dataStatus 未按截断状态取值");
});

test("COST-14 分页有安全上限且超过要标记 truncated", () => {
  const start = API.indexOf("async function handleCostReport");
  const body = API.slice(start, start + 2600);
  assert.match(body, /MAX_ROWS = \d+/, "缺少安全上限常量");
  assert.match(body, /truncated = true/, "达到上限未标记截断");
});
