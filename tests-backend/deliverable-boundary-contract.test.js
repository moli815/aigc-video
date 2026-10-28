/**
 * 交付物边界契约（2026-10-28）
 *
 * 事故：AI 热讯周报海报底部印着「数据来源：公开报道整理，截至2026年10月28日」
 * 与「未核实项：Meta Muse 留存与付费转化未公开…」。
 *
 * 根因不是模型乱写，是我们自己的数据真实性规则（META_RULE 第 1~5 条）被错误地
 * 执行到了**图片**上：出处与未核实项本该写在聊天正文，却印进了交付物。
 *
 * 锁两件事：
 * 1) 规则层：META_RULE 必须明确「图片里不放核对说明」，并说明真正的去处是聊天正文；
 * 2) 执行层：bf-image 必须在组 prompt 之前按行剔掉这类文案（模型不听话时也不出丑）。
 */
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "..");
const read = (file) => fs.readFileSync(path.join(root, file), "utf8");
const apiFunction = read("cloudfunctions/bf-api/index.js");
const imageFunction = read("cloudfunctions/bf-image/index.js");

test("META_RULE draws the boundary between text deliverables and images", () => {
  assert.match(apiFunction, /messages = injectDeliveryRule\(messages\)/, "独立规则未接入真实请求");
  const block = require('../cloudfunctions/shared/image-delivery').DELIVERY_RULE;
  for (const token of ["数据来源", "未核实", "仅供参考"]) {
    assert.ok(block.includes(token), `边界规则没有点名「${token}」`);
  }
  assert.match(block, /聊天回复正文|正文/, "没有说明核对说明该写在哪里");
  assert.match(block, /不得.*编造/,
    "没有说明与真实性规则不冲突，模型可能理解成允许编造");
});

test("bf-image strips meta copy before building the prompt", () => {
  assert.match(imageFunction, /require\("\.\/shared\/image-delivery"\)/);
  assert.match(imageFunction, /const cleanedPrompt = cleanImageRequest/);
  const around = imageFunction.slice(imageFunction.indexOf("const cleanedPrompt = cleanImageRequest"), imageFunction.indexOf("const cleanedPrompt = cleanImageRequest") + 450);
  assert.match(around, /const rawPrompt = String\(cleanedPrompt\.prompt/, "清理结果没有进入 rawPrompt");
  assert.match(around, /structured = cleanedPrompt.structured/, "结构化文案未复用同一处理结果");
});

test("stripMetaCopy removes only meta lines and keeps real content", () => {
  const {cleanText:stripMetaCopy,labelOf}=require('../cloudfunctions/shared/image-delivery');
  const metaCopyLike=text=>!!labelOf(text);

  assert.equal(metaCopyLike("数据来源：公开报道整理"), true);
  assert.equal(metaCopyLike("· 未核实项：Meta 留存率未公开"), true);
  assert.equal(metaCopyLike("截至2026年10月28日"), false, "正常截止日期必须保留");
  assert.equal(metaCopyLike("免责声明：本文仅供参考"), false, "不能把免责声明一律删除");
  assert.equal(metaCopyLike("标题：本周 AI 热讯周报"), false, "正常标题不能误伤");
  assert.equal(metaCopyLike("要点：OpenAI 发布 GPT-6.1 Terra"), false);

  const input = [
    "本周 AI 热讯周报",
    "2026.10.26 — 10.28",
    "数据来源：公开报道整理，截至2026年10月28日",
    "未核实项：Meta Muse 留存与付费转化未公开",
    "资本层面：Anthropic 递交 S-1",
  ].join("\n");
  const out = stripMetaCopy(input);
  assert.equal(out.removed, 2, "应剔除两条核对说明");
  assert.ok(out.text.includes("本周 AI 热讯周报"));
  assert.ok(out.text.includes("资本层面"));
  assert.ok(!out.text.includes("数据来源"));
  assert.ok(!out.text.includes("未核实"));
});
