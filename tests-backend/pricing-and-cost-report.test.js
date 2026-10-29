/**
 * 定价与成本看板契约（2026-10-29）
 *
 * 两件事一起钉死：
 * 1) 售价 = 上游成本 × 倍数（默认 2）。成本按火山官方单价，Pro 多图第 2 张起 0.02/张。
 *    旧实现把售价同时当成本写流水，成本看板显示的是售价，毛利永远是 0；
 *    而且 Flash 出 2K 图按 Pro 价收 0.8（成本 0.12），Pro 2K 却只收 0.8（成本 0.60）——
 *    一个暴赚一个亏。
 * 2) 成本看板查不到数据：查询用「数字毫秒」做范围，而流水写的是 Date，
 *    BSON 范围比较按类型分桶 → 只剩语义缓存那条零元行可见（截图里的 1 次调用 / ¥0）。
 */
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { aggregateCostRows } = require("../cloudfunctions/bf-api/cost-report");

const root = path.resolve(__dirname, "..");
const read = (file) => fs.readFileSync(path.join(root, file), "utf8");
const imageFunction = read("cloudfunctions/bf-image/index.js");
const apiFunction = read("cloudfunctions/bf-api/index.js");

/** 直接执行源码里的定价函数，避免测试里另抄一套算术 */
function pricing() {
  const start = imageFunction.indexOf("/**\n * 上游真实成本");
  const end = imageFunction.indexOf("/** 兼容旧调用点");
  assert.ok(start > 0 && end > start, "无法截取定价函数");
  const RT = {
    IMAGE_SIZE: "2K",
    IMAGE_COST_PRO_SMALL: 0.3, IMAGE_COST_PRO_LARGE: 0.6,
    IMAGE_COST_PRO_LAYER_SMALL: 0.15, IMAGE_COST_PRO_LAYER_LARGE: 0.3,
    IMAGE_COST_FLASH: 0.12, IMAGE_COST_LITE: 0.22,
    IMAGE_COST_45: 0.25, IMAGE_COST_40: 0.2,
    IMAGE_COST_EXTRA_INPUT: 0.02, IMAGE_PRICE_MULTIPLIER: "2",
  };
  return new Function("RT", imageFunction.slice(start, end) + "\nreturn { upstreamCostOf, customerPriceOf };")(RT);
}

test("price is exactly 2x upstream cost, per official unit prices", () => {
  const { upstreamCostOf, customerPriceOf } = pricing();
  const pro2k = upstreamCostOf({ size: "1776x2368", model: "doubao-seedream-5-0-pro-260628", inputImages: 1 });
  assert.equal(pro2k, 0.6, "Pro >236 万像素成本 0.60");
  assert.equal(customerPriceOf(pro2k), 1.2);

  const pro15 = upstreamCostOf({ size: "1344x1792", model: "doubao-seedream-5-0-pro-260628", inputImages: 1 });
  // 1.5K 3:4 = 241 万像素，官方按 ≤261 万计 0.30（旧代码用 236 万当界会误判成大图）
  assert.equal(pro15, 0.3);
  assert.equal(customerPriceOf(pro15), 0.6);

  // 2K 按档位字符也要判成"大图"
  assert.equal(upstreamCostOf({ size: "2K", model: "doubao-seedream-5-0-pro-260628", inputImages: 1 }), 0.6);
});

test("extra reference images are charged to us and passed through", () => {
  const { upstreamCostOf, customerPriceOf } = pricing();
  const two = upstreamCostOf({ size: "2K", model: "doubao-seedream-5-0-pro-260628", inputImages: 2 });
  assert.equal(Number(two.toFixed(2)), 0.62, "Pro 第 2 张输入图 0.02");
  assert.equal(customerPriceOf(two), 1.24);
});

test("flash is no longer billed at pro prices", () => {
  const { upstreamCostOf, customerPriceOf } = pricing();
  // 回归：旧实现 Flash 出 2K 图按 IMAGE_PRICE_2K=0.8 收，成本只有 0.12
  const flash2k = upstreamCostOf({ size: "2K", model: "doubao-seedream-5-0-flash-260915", inputImages: 2 });
  assert.equal(flash2k, 0.12, "Flash 不分尺寸，且输入图免费");
  assert.equal(customerPriceOf(flash2k), 0.24);
});

test("price never falls below cost", () => {
  const { customerPriceOf } = pricing();
  assert.equal(customerPriceOf(0), 0);
  assert.ok(customerPriceOf(0.005) >= 0.005);
});

test("ledger separates cost from charge", () => {
  // 账户扣款用售价
  assert.match(imageFunction, /imageUsedCny: getDb\(\)\.command\.inc\(charge\)/, "账户仍按成本扣款");
  // 流水写成本 + 售价 + 毛利
  assert.match(imageFunction, /costCny: upstream, priceCny: charge/, "流水没有区分成本与售价");
  assert.match(imageFunction, /marginCny: Number\(\(charge - upstream\)\.toFixed\(4\)\)/);
  // 任务单要存下上游成本，否则 flush 时拿不到
  assert.match(imageFunction, /patch\.upstreamCostCny = Number\(ex\.upstreamCostCny\) \|\| 0/);
});

test("cost dashboard query matches both Date and legacy numeric timestamps", () => {
  assert.match(apiFunction, /db\.command\.or\(\[\s*\{ ts: db\.command\.gte\(new Date\(startMs\)\) \},\s*\{ ts: db\.command\.gte\(startMs\) \},/,
    "查询仍然只匹配一种时间类型");
  assert.match(apiFunction, /kind: "chat", costCny: 0, ts: new Date\(\)/, "语义缓存行仍写数字毫秒");
});

test("aggregation counts mixed timestamp types and reports revenue", () => {
  const now = Date.now();
  const rows = [
    { _id: "a", accountId: "acc", kind: "chat", costCny: 0.0158, model: "deepseek-v4.1-flash-1017", tier: "modeStandard", ts: new Date(now - 3600e3) },
    { _id: "b", accountId: "acc", kind: "chat", costCny: 0, model: "semantic-cache", tier: "modeStandard", ts: now - 1800e3 },
    { _id: "c", accountId: "acc", kind: "image", costCny: 0.6, priceCny: 1.2, marginCny: 0.6, model: "doubao-seedream-5-0-pro-260628", ts: new Date(now - 600e3) },
  ];
  const report = aggregateCostRows(rows, { startMs: now - 86400e3, endMs: now + 1000 });
  assert.equal(report.ledgerEvents, 3, "Date 与数字两种 ts 都必须计入");
  assert.equal(report.totalCny, 0.62, "按分聚合：0.0158→2 分、0.6→60 分");
  assert.equal(report.imageCount, 1);
  assert.equal(report.revenueCny, 1.2, "售价缺失的行不进收入统计");
  assert.equal(report.marginCny, 0.6);
  assert.equal(report.pricedEvents, 1);
});
