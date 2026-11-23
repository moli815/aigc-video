"use strict";
/**
 * 提示词契约 + 意图分流 单测（2026-11-21 第三版：极简 + 逐行）
 * 覆盖：四种文案形态解析、逐行排版、行数预算、普通配图不被污染、电话不丢。
 */
const test = require("node:test");
const assert = require("node:assert/strict");
const pc = require("../worktree/bf-api-final/prompt-contract");
const ic = require("../worktree/bf-api-final/intent-contract");

const PRODUCTS = [
  ["栗子奶油欧包", "北海道小麦粉 · 栗子泥 40 克", "¥18"],
  ["栗香麻薯", "一盒六个 · 冷藏更好吃", "¥12"],
  ["焦糖栗子塔", "手工挞皮 · 流心", "¥22"],
  ["栗子拿铁", "现磨咖啡 · 栗子糖浆", "¥26"],
  ["栗子巴斯克", "低糖 · 六寸整模", "¥28"],
  ["栗子可颂", "32 层黄油起酥", "¥16"],
];

function blockList() {
  const items = [
    { role: "title", text: "栗香上市" },
    { role: "subtitle", text: "燕山板栗 · 慢火熬煮 4 小时 · 每日现烤" },
  ];
  for (const [n, d, p] of PRODUCTS) {
    items.push({ role: "label", text: n }, { role: "body", text: d }, { role: "body", text: p });
  }
  items.push({ role: "contact", text: "全国服务热线 400-826-7718" });
  items.push({ role: "footer", text: "麦禾堂 MAIHE BAKERY · 苏州 12 家门店" });
  return items;
}

test("四种文案形态都能解析出文字清单", () => {
  const shapes = {
    数组: { text: blockList() },
    字符串: { text: "栗香上市\n\n燕山板栗 · 慢火熬煮 4 小时\n\n栗子奶油欧包\n北海道小麦粉 · 栗子泥 40 克\n¥18" },
    对象: { text: { title: "开业大吉", subtitle: "全场第二杯半价", contact: "400-123-4567" } },
    顶层对象: { title: "开业大吉", subtitle: "全场第二杯半价", contact: "400-123-4567" },
  };
  for (const [name, structured] of Object.entries(shapes)) {
    // 真实链路里 intent-contract 会先解析出 blocks 再传进来；两种入口都要能出清单
    const viaBlocks = pc.augment("暖色调海报，木质台面，文字区留白", { aspectRatio: "3:4", blocks: blockList() });
    assert.ok(viaBlocks.includes("逐字照写"), `${name} blocks 入口未生成文字清单`);
    const viaStructured = pc.augment("暖色调海报，木质台面，文字区留白", { aspectRatio: "3:4", structured });
    assert.ok(viaStructured.includes("逐字照写"), `${name} structured 入口未生成文字清单`);
  }
});

test("产品卡：价格粘在名称块里、说明同行且都带引号", () => {
  const g = pc.groupCopy(blockList(), []);
  const lines = pc.copyLines(g);
  const row = lines.find(l => l.includes("栗子奶油欧包")) || "";
  // 价格必须和名称在同一个「」块内（2026-11-22：拆成两个引导块时报价会被整体省略）
  assert.ok(/「栗子奶油欧包\s*¥18」/.test(row), "价格没粘在名称块里，实际：" + row);
  assert.ok(row.includes("「北海道小麦粉"), "说明没跟名称同一行");
  assert.ok(lines.some(l => l.includes("栗子可颂") && l.includes("32 层黄油起酥")), "说明里的数字应原样保留");
});

test("每条文案都带引号（官方 5.5 指南的硬要求）", () => {
  const lines = pc.copyLines(pc.groupCopy(blockList(), []));
  const copy = lines.filter(l => !/[：:]$/.test(l));   // 分组说明行以冒号结尾，不算文案
  assert.ok(copy.length >= 8, "文案行过少: " + copy.length);
  for (const l of copy) {
    assert.ok(l.includes("「") && l.includes("」"), `文案未加引号: ${l}`);
  }
});

test("行数受预算约束，不无限堆", () => {
  const lines = pc.copyLines(pc.groupCopy(blockList(), []));
  assert.ok(lines.length <= 18, `行数超限: ${lines.length}`);
});

test("电话与署名不会被字数预算挤掉", () => {
  const lines = pc.copyLines(pc.groupCopy(blockList(), []));
  assert.ok(lines.some(l => l.includes("400-826-7718")), "电话丢了");
});

test("提示词总长不超过上限", () => {
  const out = pc.augment("暖色调海报，木质台面，晨光，文字区留白干净", { aspectRatio: "3:4", structured: { text: blockList() } });
  assert.ok(out.length <= pc.MAX_LEN, `超长: ${out.length}`);
  assert.ok(out.includes("风格："), "缺风格约束");
});

test("长段落展开成短句，不产生半截词", () => {
  const long = "麦禾堂始于2015年。坚持当日现磨、当日烘烤、不卖隔夜，把面团放进4摄氏度冷库醒发18小时，次日清晨5点进炉。";
  const g = pc.groupCopy([{ role: "body", text: long }], []);
  for (const c of g.cards) {
    if (!c.body) continue;
    assert.ok(!/^[·，。、]/.test(c.body), `开头是分隔符: ${c.body}`);
    assert.ok(!/[·，。、]$/.test(c.body), `结尾是分隔符: ${c.body}`);
  }
});

// ── 意图分流：普通配图绝不能被加上海报契约 ──
function applyOnce(args) {
  const calls = [{ id: "t", type: "function", function: { name: "image_generate", arguments: JSON.stringify(args) } }];
  const out = ic.apply(calls, { hasAny: false, roles: null, ratio: null, enforceSpec: null });
  return JSON.parse(out[0].function.arguments);
}

test("普通配图与插画不追加海报契约", () => {
  for (const p of ["一只橘猫趴在窗台晒太阳，写实摄影", "扁平风咖啡杯插画，莫兰迪色系", "把背景换成海边"]) {
    const a = applyOnce({ prompt: p });
    assert.equal(a.prompt, p, `被污染: ${a.prompt}`);
  }
});

test("海报类请求追加契约", () => {
  const a = applyOnce({ prompt: "做一张咖啡店开业海报，标题「开业大吉」", render_intent: "poster" });
  assert.ok(/逐字照写|风格：/.test(a.prompt), "海报未追加契约");
});
