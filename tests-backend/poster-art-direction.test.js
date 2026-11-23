"use strict";
const test = require("node:test");
const assert = require("node:assert");
const AD = require("../cloudfunctions/shared/poster-art-direction.js");

const BLOCKS = [
  { zone: "A 顶栏", role: "brand", level: "sub", text: "中防保全（苏州）科技有限公司", duplicable: true },
  { zone: "A 顶栏", role: "hotline", level: "label", text: "400-7758-119", duplicable: true },
  { zone: "B 主张", role: "hero", level: "hero", text: "一个平台 管住城市安全风险" },
  { zone: "D 数据", role: "metric", level: "metric", text: "05 大业务系统" },
  { zone: "D 数据", role: "metric", level: "metric", text: "05 平台核心能力" },
  { zone: "D 数据", role: "metric", level: "metric", text: "05 类应用场景" },
];

test("画布档位随字数自动升级", () => {
  assert.equal(AD.planCanvas({ totalChars: 60 }).size, "1.5K");
  assert.equal(AD.planCanvas({ totalChars: 121 }).size, "2K");
  assert.equal(AD.planCanvas({ totalChars: 10, hasPhoto: true }).size, "2K");
  assert.equal(AD.planCanvas({ totalChars: 121 }).outputTierCny, 0.23);
  assert.equal(AD.planCanvas({ totalChars: 60 }).outputTierCny, 0.13);
});

test("文字契约逐条加引号，且不合并、不改写", () => {
  const c = AD.composeTextContract(BLOCKS);
  assert.equal(c.count, 6);
  BLOCKS.forEach(b => assert.ok(c.text.includes(JSON.stringify(b.text)), "缺少原文：" + b.text));
  assert.match(c.text, /中防保全（苏州）科技有限公司/);
  assert.match(c.text, /400-7758-119/);
});

test("同一区并列条目必须声明全数出现", () => {
  const c = AD.composeTextContract(BLOCKS);
  assert.match(c.text, /内部区域\d+，不印此标记】（本组共 3 项，必须 3 项全部出现/);
});

test("只有标记 duplicable 的段落在硬约束里被允许重复", () => {
  const c = AD.composeTextContract(BLOCKS);
  assert.match(c.text, /允许在页眉与页脚各出现一次/);
  assert.ok(!c.text.includes('"一个平台 管住城市安全风险" 允许'), "主标题不该被允许重复");
});

test("没有 duplicable 时给出不重复约束", () => {
  const c = AD.composeTextContract([{ zone: "B", role: "hero", level: "hero", text: "测试标题" }]);
  assert.match(c.text, /每段只印一次，不得重复/);
});

test("美术指导不混入文案，也不把装饰候选变成强制清单", () => {
  const art = AD.composeArtDirection({ styleFamily: "tech", density: "dense", palette: ["#061024", "#0A327E", "#39D0FF"] });
  BLOCKS.forEach(b => assert.ok(!art.includes(b.text), "美术指导混入了文案：" + b.text));
  assert.match(art, /可选的视觉语言/);
  assert.doesNotMatch(art, /必须全部|至少用上|6 倍以上|占画面 25%/);
  assert.match(art, /风格禁区：/);
});

test("六个风格族都能产出非空且互不相同的美术指导", () => {
  const outs = AD.FAMILY_KEYS.map(f => AD.composeArtDirection({ styleFamily: f, density: "balanced" }));
  outs.forEach((o, i) => assert.ok(o.length > 120, AD.FAMILY_KEYS[i] + " 指导过短"));
  assert.equal(new Set(outs).size, AD.FAMILY_KEYS.length, "风格指导出现重复，等于没分支");
});

test("未知风格与未知密度回落到安全默认值", () => {
  assert.equal(AD.normalizeFamily("不存在的风格"), "tech");
  assert.equal(AD.normalizeDensity("xxx"), "dense");
});

test("完整提示词不含重复文案块名，且契约只出现一次", () => {
  const p = AD.composePosterPrompt({
    styleFamily: "tech", density: "dense", palette: ["#061024"],
    layoutNotes: ["顶部窄栏", "中部主视觉", "六项业务横向"],
    blocks: BLOCKS, hasPhoto: true, hasLogo: true,
  });
  assert.equal(p.prompt.split("【画面文字契约】").length, 2, "契约出现次数不是 1");
  assert.match(p.prompt, /1776×2368/);
  const hits = p.prompt.split("400-7758-119").length - 1;
  assert.ok(hits <= 2, "热线在提示词里出现 " + hits + " 次");
});

test("成本估算与官方单价一致", () => {
  assert.equal(AD.estimateCost({ inputImages: 2, canvas: { outputTierCny: 0.23 } }), 0.33);
  assert.equal(AD.estimateCost({ inputImages: 0, canvas: { outputTierCny: 0.13 } }), 0.13);
});

test("版面容量：300 字内走单张，300–800 走长图，超过走系列", () => {
  assert.equal(AD.planFormat(120).mode, "poster");
  assert.equal(AD.planFormat(300).mode, "poster");
  assert.equal(AD.planFormat(500).mode, "longform");
  assert.equal(AD.planFormat(801).mode, "series");
  assert.equal(AD.planFormat(900).pages, 3);
});

test("拆系列时同一组不被拆开，且每页不超容量", () => {
  const blocks = [
    { zone: "C", group: "g1", text: "一".repeat(120) },
    { zone: "C", group: "g1", text: "二".repeat(120) },
    { zone: "C", group: "g2", text: "三".repeat(120) },
    { zone: "C", group: "g2", text: "四".repeat(120) },
  ];
  const pages = AD.splitIntoSeries(blocks, 250);
  assert.ok(pages.length >= 2, "应该拆成两页以上");
  pages.forEach(p => assert.ok(p.chars <= 360, "某页超容量：" + p.chars));
  // g1 两条必须同页
  const pageOf = t => pages.findIndex(p => p.blocks.some(b => b.text[0] === t));
  assert.equal(pageOf("一"), pageOf("二"), "同一组被拆开了");
});

test("系列提示词带页序，且不同页的文案不串", () => {
  const blocks = [
    { zone: "A", text: "标题甲" },
    { zone: "B", group: "g", text: "乙".repeat(300) },
    { zone: "C", group: "h", text: "丙".repeat(300) },
    { zone: "D", group: "i", text: "丁".repeat(300) },
  ];
  const out = AD.composeSeries({ blocks, maxPerPage: 300, styleFamily: "tech", density: "dense" });
  assert.ok(out.length >= 2, "应该拆成多页");
  assert.match(out[0].prompt, /系列海报第 1 张/);
  const withB = out.findIndex(o => o.prompt.includes("乙"));
  assert.ok(withB >= 0, "没有任何一页含乙");
  out.forEach((o, i) => { if (i !== withB) assert.ok(!o.prompt.includes("乙"), "第" + (i + 1) + "页串进了乙"); });
});

test("有参考图时必须声明参考图文字不得复刻", () => {
  const art = AD.composeArtDirection({ styleFamily: "tech", density: "dense", hasReference: true });
  assert.match(art, /【参考图文字隔离】/);
  assert.match(art, /原件.*保留/);
});
