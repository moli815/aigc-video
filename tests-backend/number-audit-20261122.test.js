"use strict";
// 2026-11-22「保数字」校验：抽取硬 token + 归一化比对。只测确定性部分，OCR 由线上视觉模型完成。
const test = require("node:test");
const assert = require("node:assert/strict");
const path = require("path");

const audit = require(path.join(__dirname, "..", "cloudfunctions/shared/number-audit.js"));

test("抽出价格、克数、层数、时长", () => {
  const tokens = audit.tokensOf([
    { role: "body", text: "北海道小麦粉 · 栗子泥 40 克" },
    { role: "body", text: "¥18" },
    { role: "body", text: "32 层黄油起酥" },
    { role: "body", text: "低温发酵 18 小时" },
    { role: "title", text: "栗香上市" },
  ]);
  assert.ok(tokens.includes("40克"), "缺 40克: " + tokens.join(","));
  assert.ok(tokens.includes("¥18"), "缺价格: " + tokens.join(","));
  assert.ok(tokens.includes("32层"), "缺层数: " + tokens.join(","));
  assert.ok(tokens.includes("18小时"), "缺时长: " + tokens.join(","));
  assert.ok(!tokens.some(t => t.includes("栗香")), "标题不该被当数字 token");
});

test("字符串形态的文案也能抽", () => {
  const tokens = audit.tokensOf("ITI 种植体 9800 元\n质保 10 年");
  assert.ok(tokens.includes("9800元"), tokens.join(","));
  assert.ok(tokens.includes("10年"), tokens.join(","));
});

test("转录里出现 → 不报缺失", () => {
  const r = audit.check(["¥18", "40克"], "栗子奶油欧包 ¥18 北海道小麦粉 栗子泥40克");
  assert.equal(r.checked, 2);
  assert.deepEqual(r.missing, []);
});

test("被改写成卖点 → 报缺失（线上真实场景）", () => {
  const r = audit.check(["¥18", "40克", "32层"], "栗子奶油欧包 ¥18 香甜栗子奶油 绵软细腻");
  assert.deepEqual(r.missing, ["40克", "32层"]);
});

test("标点与空格不影响判定", () => {
  const r = audit.check(["18 小时", "¥ 18"], "发酵18小时，售价¥18");
  assert.deepEqual(r.missing, []);
});

test("元 / ¥ 写法不同不算缺失（线上真实误报）", () => {
  const r = audit.check(["4980元", "9800元"], "¥4980  ¥9800");
  assert.deepEqual(r.missing, []);
});

test("数量上限保护：最多 16 个 token", () => {
  const many = Array.from({ length: 40 }, (_, i) => ({ text: `${i + 10} 克` }));
  assert.ok(audit.tokensOf(many).length <= 16);
});

test("price verification requires a complete currency amount, not a model number or a digit substring", () => {
  const tokens = audit.tokensOf("AC-7000 平台 ￥28,000 元；摄像头 680 元");
  assert.deepEqual(tokens, ["￥28,000", "680元"]);
  assert.deepEqual(audit.check(tokens, "设备 28000  序号 1680元").missing, tokens);
  assert.deepEqual(audit.check(tokens, "平台 28,000 元；摄像头 ¥680").missing, []);
});
