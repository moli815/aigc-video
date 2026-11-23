"use strict";
const test = require("node:test");
const assert = require("node:assert");
const path = require("path");
const { PNG } = require(path.join(__dirname, "../cloudfunctions/bf-image/node_modules/pngjs"));
const { bboxTag, repairPrompt, planRepairs } = require("../cloudfunctions/shared/poster-repair.js");
const pipeline = require("../cloudfunctions/shared/poster-pipeline.js");
const { audit } = require("../cloudfunctions/shared/poster-text-audit.js");

function blankPng(w = 40, h = 40) {
  const p = new PNG({ width: w, height: h });
  p.data.fill(0);
  for (let i = 3; i < p.data.length; i += 4) p.data[i] = 255;
  return PNG.sync.write(p);
}

test("bbox 标签按 0–999 归一化输出且不越界", () => {
  assert.equal(bboxTag([0, 0, 1, 1]), "<bbox>0 0 999 999</bbox>");
  assert.equal(bboxTag([0.5, 0.25, 0.25, 0.5]), "<bbox>500 250 749 749</bbox>");
  assert.equal(bboxTag([-1, -1, 2, 2]), "<bbox>0 0 999 999</bbox>");
  assert.equal(bboxTag(null), "");
});

test("修复提示词把改动限定在一处，并列出不可动项", () => {
  const p = repairPrompt({ wrong: "技术持由", right: "技术支持由", box: [0.5, 0.8, 0.4, 0.05] });
  assert.match(p, /<bbox>500 799 899 849<\/bbox>/);
  assert.match(p, /把「技术持由」改为「技术支持由」/);
  assert.match(p, /必须完整保留，不得重绘/);
});

test("只挑出 near / missing，不碰已经对的条目", () => {
  const blocks = [{ key: "a", text: "对的" }, { key: "b", text: "技术支持由" }, { key: "c", text: "漏掉的" }];
  const report = {
    items: [
      { key: "a", text: "对的", status: "exact" },
      { key: "b", text: "技术支持由", status: "near", actual: "技术持由" },
      { key: "c", text: "漏掉的", status: "missing" },
    ],
  };
  const plan = planRepairs(report, blocks, { b: [0.1, 0.2, 0.3, 0.4] });
  assert.equal(plan.length, 2);
  assert.equal(plan[0].wrong, "技术持由");
  assert.deepEqual(plan[0].box, [0.1, 0.2, 0.3, 0.4]);
  assert.equal(plan[1].status, "missing");
});

test("闭环：第一次审计不过，修一次后通过", async () => {
  let transcribeRound = 0;
  let repaired = false;
  const res = await pipeline.run({
    blocks: [{ key: "hero", text: "一个平台 管住城市安全风险" }],
    adapters: {
      generate: async () => ({ png: blankPng(), cost: 0.23 }),
      transcribe: async () => {
        transcribeRound++;
        return transcribeRound === 1 ? ["一个平台 管住城市安全风"] : ["一个平台 管住城市安全风险"];
      },
      repair: async () => { repaired = true; return { png: blankPng(41, 41), cost: 0.23 }; },
    },
  });
  assert.ok(repaired, "没有触发修复");
  assert.equal(res.repairs, 1);
  assert.equal(res.audit.pass, true);
  assert.equal(res.cost, 0.46);
});

test("修满次数仍不过时带着报告交付，不无限重试", async () => {
  const res = await pipeline.run({
    blocks: [{ key: "hero", text: "一个平台 管住城市安全风险" }],
    maxRepair: 2,
    adapters: {
      generate: async () => ({ png: blankPng(), cost: 0.23 }),
      transcribe: async () => ["一个平台 管住城市安全风"],
      repair: async () => ({ png: blankPng(), cost: 0.23 }),
    },
  });
  assert.equal(res.repairs, 2);
  assert.equal(res.audit.pass, false);
  assert.equal(res.cost, 0.69);
});

test("一次通过时不花修复钱", async () => {
  const res = await pipeline.run({
    blocks: [{ key: "hero", text: "一个平台 管住城市安全风险" }],
    adapters: {
      generate: async () => ({ png: blankPng(), cost: 0.23 }),
      transcribe: async () => ["一个平台 管住城市安全风险"],
    },
  });
  assert.equal(res.repairs, 0);
  assert.equal(res.cost, 0.23);
  assert.equal(res.audit.pass, true);
});

test("有参考图时提示词带占位色，并在末尾合成", async () => {
  let sawPlaceholder = false;
  const res = await pipeline.run({
    blocks: [{ key: "hero", text: "一个平台 管住城市安全风险" }],
    photoBytes: Buffer.from("fake-photo"),
    placeholderClause: "留出纯品红矩形",
    adapters: {
      generate: async ({ prompt }) => { sawPlaceholder = prompt.includes("#FF00FF") || prompt.includes("纯品红"); return { png: blankPng(), cost: 0.33 }; },
      transcribe: async () => ["一个平台 管住城市安全风险"],
      composePhoto: async () => ({ png: blankPng(60, 60), box: [0.1, 0.1, 0.5, 0.5] }),
    },
  });
  assert.ok(sawPlaceholder, "提示词没带占位色要求");
  assert.ok(res.composed, "没有执行合成");
  assert.ok(res.steps.some(s => s.step === "compose"));
});

test("合成失败不影响交付", async () => {
  const res = await pipeline.run({
    blocks: [{ key: "hero", text: "标题" }],
    photoBytes: Buffer.from("x"),
    placeholderClause: "纯品红",
    adapters: {
      generate: async () => ({ png: blankPng(), cost: 0.33 }),
      transcribe: async () => ["标题"],
      composePhoto: async () => { throw new Error("ASSET_ENGINE_TIMEOUT"); },
    },
  });
  assert.ok(Buffer.isBuffer(res.png));
  assert.equal(res.composed, null);
  assert.ok(res.steps.some(s => s.step === "compose" && s.error));
});

test("没有文案块时直接报错，不产生空请求", async () => {
  await assert.rejects(() => pipeline.run({ blocks: [], adapters: { generate: async () => ({}) } }), /PIPELINE_NO_BLOCKS/);
});

test("审计失败但无法定位时不做无意义修复", async () => {
  const res = await pipeline.run({
    blocks: [{ key: "hero", text: "一个平台 管住城市安全风险" }],
    adapters: {
      generate: async () => ({ png: blankPng(), cost: 0.23 }),
      transcribe: async () => [],
      repair: async () => { throw new Error("不该被调用"); },
    },
  });
  assert.equal(res.repairs, 0);
  assert.equal(res.audit.pass, false);
});

test("审计判定本身不依赖模型：同样的转录结果永远同样判定", () => {
  const blocks = [{ text: "中防保全（苏州）科技有限公司" }];
  const a = audit(blocks, ["中防保全（苏州）科技有限公司"]);
  const b = audit(blocks, ["中防保全（苏州）科技有限公司"]);
  assert.deepEqual(a.summary, b.summary);
  assert.equal(a.pass, true);
});
