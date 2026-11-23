"use strict";
const test = require("node:test");
const assert = require("node:assert");
const { audit, normalize, levenshtein, TRANSCRIBE_SYSTEM } = require("../cloudfunctions/shared/poster-text-audit.js");
const { compileNativeCopy } = require("../cloudfunctions/shared/image-design-brief.js");

const EXP = [
  { key: "brand", role: "label", text: "中防保全（苏州）科技有限公司", duplicable: true },
  { key: "hotline", role: "contact", text: "400-7758-119", duplicable: true },
  { key: "hero", role: "title", text: "一个平台 管住城市安全风险" },
  { key: "b1", role: "body", text: "消防与安防终端接入同一平台" },
];

test("全部逐字一致时通过", () => {
  const r = audit(EXP, [
    "中防保全（苏州）科技有限公司",
    "400-7758-119",
    "一个平台 管住城市安全风险",
    "消防与安防终端接入同一平台",
  ]);
  assert.equal(r.pass, true);
  assert.equal(r.summary.exact, 4);
});

test("全半角与空格差异不误判为错", () => {
  const r = audit([{ text: "400-7758-119" }], ["400－7758－119"]);
  assert.equal(r.summary.exact, 1);
});

test("错一个字报 near，不自动放行", () => {
  const r = audit([{ text: "城市综合安全风险管理解决方案" }], ["城市综合安全风险管险解决方案"]);
  assert.equal(r.pass, false);
  assert.equal(r.items[0].status, "near");
  assert.equal(r.items[0].distance, 1);
});

test("漏字报 missing", () => {
  const r = audit([{ text: "中防保全（苏州）科技有限公司" }], ["中防保全科技有限公司"]);
  assert.equal(r.items[0].status, "missing");
});

test("模型自加的栏目名报 extra", () => {
  const r = audit([{ text: "平台通过国家信息安全等级保护测评" }], ["资质背书", "平台通过国家信息安全等级保护测评"]);
  assert.deepEqual(r.extras, ["资质背书"]);
  assert.equal(r.pass, false);
});

test("允许重复的段落在页眉页脚各一次不算错", () => {
  const r = audit(
    [{ text: "400-7758-119", duplicable: true }],
    ["400-7758-119", "400-7758-119"]
  );
  assert.equal(r.pass, true);
  assert.equal(r.items[0].occurrences, 2);
});

test("不允许重复的段落出现两次也要报出来", () => {
  const r = audit([{ text: "九小场所 · 商业综合体" }], ["九小场所 · 商业综合体", "九小场所 · 商业综合体"]);
  assert.equal(r.pass, false);
  assert.equal(r.items[0].status, "duplicate");
  assert.equal(r.summary.duplicate, 1);
});

test("空转录不会崩，全部报 missing", () => {
  const r = audit(EXP, []);
  assert.equal(r.summary.missing, 4);
  assert.equal(r.pass, false);
});

test("编辑距离实现正确", () => {
  assert.equal(levenshtein("abc", "abc"), 0);
  assert.equal(levenshtein("abc", "abd"), 1);
  assert.equal(levenshtein("", "abc"), 3);
});

test("转录提示词明确禁止纠正拼写", () => {
  assert.match(TRANSCRIBE_SYSTEM, /禁止纠正拼写/);
  assert.match(TRANSCRIBE_SYSTEM, /texts/);
});

test("生产文案编译带上总字数、条数与禁增小标题", () => {
  const items = [
    { key: "brand", role: "label", text: "中防保全（苏州）科技有限公司" },
    { key: "hotline", role: "contact", text: "400-7758-119" },
    { key: "b1", role: "body", text: "消防与安防终端接入同一平台" },
    { key: "b2", role: "body", text: "分散在各楼层的设备状态持续在线" },
    { key: "b3", role: "body", text: "对异常识别与分级" },
  ];
  const out = compileNativeCopy(items, { literalLines: true });
  assert.match(out, /共 5 段、合计 \d+ 字/);
  assert.match(out, /正文共 3 条/);
  assert.match(out, /不要给区块起小标题或栏目名/);
  assert.match(out, /画面不得出现任何其他文字/);
  assert.match(out, /"中防保全（苏州）科技有限公司"/);
});

test("非 literalLines 路径行为不变", () => {
  const out = compileNativeCopy([{ key: "a", role: "title", text: "标题" }], { literalLines: false });
  assert.match(out, /【画面定稿与文字层级】/);
  assert.ok(!out.includes("不要给区块起小标题"));
});

test("长句被转录按视觉换行切成多行，不应误判为多出", () => {
  const r = audit(
    [{ text: "消防与安防终端接入同一平台，火警、故障、离线状态一屏可见，值班人员不必在多套系统之间来回切换。" }],
    ["消防与安防终端接入同一平台，火警、故障、离线状态一屏", "可见，值班人员不必在多套系统之间来回切换。", "资质背书"]
  );
  assert.equal(r.summary.exact, 1);
  assert.deepEqual(r.extras, ["资质背书"]);
});

test("两三个字的凭空小标要报出来，不能当碎片跳过", () => {
  const r = audit([{ text: "05 大业务系统" }], ["契约", "05 大业务系统"]);
  assert.deepEqual(r.extras, ["契约"]);
});

test("已出现完整原文后，多出的子串也不能伪装成换行碎片", () => {
  const r = audit([{ text: "服务流程" }], ["服务流程", "服务"]);
  assert.deepEqual(r.extras, ["服务"]);
  assert.equal(r.pass, false);
});
