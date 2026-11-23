"use strict";
/**
 * 海报生产闭环：生成 → 审计 → 局部修复 → 复审 → 参考图合成。
 *
 * 设计原则（2026-11-16 定）：
 *   - 审计判定用字符串比对，模型只负责转录，不负责下结论；
 *   - 修一处只改一处（bbox 局部编辑），不整张重出，避免把已经对的地方改错；
 *   - 参考照片由服务端贴回，不交给模型「保持原样」；
 *   - 每张最多修 N 次，超了就带着审计报告交付，不无限重试烧钱。
 *
 * 依赖全部注入，便于离线测试：
 *   generate({prompt,size,images}) -> {png:Buffer, cost:number}
 *   transcribe(png)                -> string[]
 *   repair({png,prompt})           -> {png:Buffer, cost:number}
 *   composePhoto({png,photo})      -> {png:Buffer, box}|null
 */

const AD = require("./poster-art-direction");
const { audit } = require("./poster-text-audit");
const { repairPrompt, planRepairs } = require("./poster-repair");

const DEFAULT_MAX_REPAIR = 2;

async function run({
  blocks,
  styleFamily = "tech",
  density,
  aspectRatio,
  orientation,
  palette,
  layoutNotes,
  photoBytes = null,
  hasLogo = false,
  images = [],
  maxRepair = DEFAULT_MAX_REPAIR,
  adapters,
  placeholderClause = "",
  promptOverride = "",
  sizeOverride = "",
  onStep = () => {},
}) {
  if (!Array.isArray(blocks) || !blocks.length) throw Object.assign(new Error("PIPELINE_NO_BLOCKS"), { code: "PIPELINE_NO_BLOCKS" });
  if (!adapters || typeof adapters.generate !== "function") throw Object.assign(new Error("PIPELINE_NO_GENERATE"), { code: "PIPELINE_NO_GENERATE" });

  const built = AD.composePosterPrompt({ styleFamily, density, palette, layoutNotes, blocks, hasPhoto: !!photoBytes, hasLogo, aspectRatio, orientation });
  const basePrompt = promptOverride || built.prompt;
  const prompt = photoBytes && placeholderClause ? basePrompt + "\n\n" + placeholderClause : basePrompt;
  if (sizeOverride) built.canvas.size = sizeOverride;

  let cost = 0;
  const steps = [];
  const t0 = Date.now();

  let out = await adapters.generate({ prompt, size: sizeOverride || built.canvas.providerSize, images });
  cost += Number(out.cost || 0);
  steps.push({ step: "generate", ms: Date.now() - t0, size: built.canvas.size });
  onStep({ step: "generate", size: built.canvas.size });

  let report = null;
  let repairs = 0;

  for (let attempt = 0; attempt <= maxRepair; attempt++) {
    if (typeof adapters.transcribe !== "function") break;
    const texts = await adapters.transcribe(out.png);
    report = audit(blocks, texts);
    steps.push({ step: "audit", attempt, ms: Date.now() - t0, summary: report.summary });
    onStep({ step: "audit", attempt, summary: report.summary });
    if (report.pass) break;
    if (attempt === maxRepair) break;
    if (typeof adapters.repair !== "function") break;

    const pending = planRepairs(report, blocks);
    // 只修「知道现在错成什么样」的条目：near 拿到的是图上实际文字，能写进「把 A 改成 B」。
    // missing 只知道缺了什么、不知道画面上是什么，硬修会变成「把 X 改成 X」这种无意义请求。
    const target = pending.find(p => p.wrong && p.wrong !== p.right);
    if (!target) break;

    const rp = repairPrompt({ wrong: target.wrong || target.right, right: target.right, box: target.box || undefined });
    const fixed = await adapters.repair({ png: out.png, prompt: rp, key: target.key });
    if (!fixed || !Buffer.isBuffer(fixed.png)) break;
    out = { ...out, png: fixed.png };
    cost += Number(fixed.cost || 0);
    repairs++;
    steps.push({ step: "repair", key: target.key, status: target.status, ms: Date.now() - t0 });
    onStep({ step: "repair", key: target.key });
  }

  let composed = null;
  if (photoBytes && typeof adapters.composePhoto === "function") {
    try {
      composed = await adapters.composePhoto({ png: out.png, photo: photoBytes });
      if (composed && Buffer.isBuffer(composed.png)) {
        out = { ...out, png: composed.png };
        steps.push({ step: "compose", box: composed.box, ms: Date.now() - t0 });
        onStep({ step: "compose", box: composed.box });
      }
    } catch (e) {
      steps.push({ step: "compose", error: String(e.message || e).slice(0, 120) });
    }
  }

  return {
    png: out.png,
    prompt,
    canvas: built.canvas,
    cost: Number(cost.toFixed(4)),
    repairs,
    audit: report,
    composed: composed ? { box: composed.box } : null,
    steps,
    ms: Date.now() - t0,
  };
}

module.exports = { run, DEFAULT_MAX_REPAIR };
