"use strict";

/**
 * 提示词契约本地自检（2026-11-22 第 19 轮）
 *
 * 为什么要有这个脚本：上一轮的坏习惯是「改完直接跑图」，一次出图 ¥0.6 + 40 秒，
 * 排版问题却一眼就能从提示词文本里看出来。先把提示词验干净，再花额度。
 *
 * 检查项对应的是真实踩过的坑：
 *   · 长度超限 → 降级到 minimal → 画面与风格整段丢失 → 纯白底
 *   · 卡片数与输入不符 / 有卡没价格 → 模型漏画
 *   · 底部信息重复 → 电话印两遍
 *   · 说明过长 → 必崩伪字
 *   · 缺网格约束 → 卡片高低不齐、栏宽不等
 *
 * 用法：node scripts/verify-prompt-contract-20261122.cjs
 * 退出码 0 = 全过；1 = 有失败项（用于卡住部署）。
 */

const path = require("path");

const ROOT = path.join(__dirname, "..");
const pc = require(path.join(ROOT, "worktree/bf-api-final/prompt-contract"));
const ic = require(path.join(ROOT, "worktree/bf-api-final/intent-contract"));

const MAX_LEN = 1100;

/** 口腔：六卡带说明，最像真实商业稿 */
const DENTAL = [
  { role: "title", text: "重新长出一口好牙" },
  { role: "subtitle", text: "CBCT 三维评估 · 数字化导板种植" },
  ["韩国奥齿泰", "含基台与全瓷冠，质保10年", "¥4980"],
  ["瑞士 ITI", "亲水表面，质保15年", "¥9800"],
  ["瑞典诺贝尔", "钛易耐表面，终身质保", "¥12800"],
  ["全瓷贴面", "美学修复，少磨牙", "¥2680"],
  ["隐形矫正", "隐形舒适，不影响美观", "¥23800"],
  ["儿童窝沟封闭", "预防龋齿，保护恒牙", "¥180"],
].flatMap(x => (Array.isArray(x)
  ? [{ role: "label", text: x[0] }, { role: "body", text: x[1] }, { role: "body", text: x[2] }]
  : [x]))
  .concat([
    { role: "body", text: "每日限8位，免费拍片评估" },
    { role: "body", text: "支持分期，需提前预约" },
    { role: "contact", text: "全国服务热线 400-9902-517" },
    { role: "footer", text: "齿悦口腔 CHIYUE DENTAL" },
  ]);

/** 烘焙：六款产品 + 要点 + 页脚 */
const BAKERY = [
  { role: "title", text: "栗香上市" },
  { role: "subtitle", text: "燕山板栗 · 慢火熬煮 4 小时 · 每日现烤" },
  ["栗子奶油欧包", "北海道小麦粉，栗子泥40克", "¥18"],
  ["栗香麻薯", "一盒六个，冷藏更好吃", "¥12"],
  ["焦糖栗子塔", "手工挞皮，流心馅", "¥22"],
  ["栗子拿铁", "现磨咖啡，栗子糖浆", "¥26"],
  ["栗子巴斯克", "低糖版，六寸整模", "¥28"],
  ["栗子可颂", "32层黄油起酥", "¥16"],
].flatMap(x => (Array.isArray(x)
  ? [{ role: "label", text: x[0] }, { role: "body", text: x[1] }, { role: "body", text: x[2] }]
  : [x]))
  .concat([
    { role: "body", text: "迁西板栗，糖度18度以上" },
    { role: "body", text: "每日现烤，不卖隔夜" },
    { role: "contact", text: "全国服务热线 400-826-7718" },
    { role: "footer", text: "麦禾堂 MAIHE BAKERY · 苏州12家门店" },
  ]);

const fails = [];
const warns = [];
const ok = (cond, msg) => { if (!cond) fails.push(msg); };

function checkScene(name, blocks, promptText, roles) {
  const out = pc.augment(promptText, { aspectRatio: "3:4", blocks, roles });
  const lines = out.split("\n");

  // ① 长度：超限会降级并丢掉画面/风格
  ok(out.length <= MAX_LEN, `[${name}] 提示词 ${out.length} 字，超过上限 ${MAX_LEN}`);

  // ② 必需段落齐全（这是「纯白底」的根因）
  for (const seg of ["用途：", "画面：", "风格：", "逐字照写", "排版：", "禁止："]) {
    ok(out.includes(seg), `[${name}] 缺少段落「${seg}」→ 会被降级成白底`);
  }

  // ③ 风格必须是 full 档（STYLE_MIN 没有网格与示意图要求）
  ok(/网格系统/.test(out), `[${name}] 风格段缺「网格系统」约束（等高等宽对齐）`);
  ok(/没有实拍就画示意图/.test(out), `[${name}] 缺「无素材时画示意图」→ 卡片会只有文字`);
  ok(/卡片左侧画示意图或图标/.test(out), `[${name}] 卡片缺「左侧图形」要求 → 会做成纯文字卡`);

  // ④ 主标题锁在画面描述里
  const title = blocks.find(b => b.role === "title");
  if (title) {
    const visualLine = lines.find(l => l.startsWith("画面：")) || "";
    ok(visualLine.includes(`「${title.text}」`), `[${name}] 主标题没写进画面描述开头，会被改写`);
  }

  // ⑤ 卡片数 = 输入 label 数。
  // 注意卡片行现在是「名称 ¥价格」「说明」两块（价格粘进名称块），所以按段落取行，
  // 不能再用「两个引号块」做正则——否则会把卡片漏判成 0 张。
  const labels = blocks.filter(b => b.role === "label").map(b => b.text);
  const cardSeg = out.includes("产品卡")
    ? out.split("产品卡")[1].split(/要点区|底部信息带/)[0]
    : "";
  const cardLines = cardSeg.split("\n").filter(l => /^「[^」]+」/.test(l));
  ok(cardLines.length === labels.length,
    `[${name}] 卡片行 ${cardLines.length} 张，输入 ${labels.length} 个产品`);
  for (const name2 of labels) {
    ok(cardLines.some(l => l.includes(name2)), `[${name}] 产品「${name2}」没进卡片行`);
  }

  // ⑥ 价格必须与名称在同一块里（拆开就会出现「六款报价全丢」）
  for (const l of cardLines) {
    const first = ([...l.matchAll(/「([^」]*)」/g)][0] || [])[1] || "";
    const hasPriceInLabel = /[¥￥]\s*\d/.test(first);
    const label = labels.find(n => first.includes(n)) || first;
    const expectPrice = blocks.some(b => b.role === "label" && b.text === label
      && blocks.some(x => x.role === "body" && /^[¥￥]/.test(x.text) && blocks.indexOf(x) > blocks.indexOf(b) && blocks.indexOf(x) < blocks.indexOf(b) + 3));
    if (expectPrice) ok(hasPriceInLabel, `[${name}] 「${label}」的价格没跟名称粘在一起`);
  }

  // ⑦ 说明长度 ≤14（20 字必崩伪字）
  for (const l of cardLines) {
    const segs = [...l.matchAll(/「([^」]*)」/g)].map(m => m[1]);
    const body = segs[1] || "";
    ok(body.length <= 14, `[${name}] 说明「${body}」${body.length} 字，超过 14 字会崩`);
  }

  // ⑦ 底部信息带只出现一次，且不重复同一条
  const footStart = lines.findIndex(l => l.startsWith("底部信息带"));
  ok(footStart > 0, `[${name}] 缺底部信息带`);
  if (footStart > 0) {
    const footBlock = lines.slice(footStart).filter(l => l.startsWith("「"));
    ok(footBlock.length === 1, `[${name}] 底部信息带 ${footBlock.length} 行，应为 1 行`);
    const inner = [...(footBlock[0] || "").matchAll(/「([^」]*)」/g)].map(m => m[1]);
    ok(new Set(inner).size === inner.length, `[${name}] 底部信息带存在重复条目`);
  }

  // ⑧ 同一句话不应整段出现两次（防止标题既在画面又在清单时被模型画两遍）
  const dup = lines.filter(l => l.length > 18 && out.split(l).length > 2);
  ok(dup.length === 0, `[${name}] 重复段落：${dup.slice(0, 2).map(x => x.slice(0, 20)).join(" / ")}`);

  // ⑨ 非卡片信息归到要点区，不能混进产品卡
  const loose = blocks.filter(b => b.role === "body" && !/^[¥￥]/.test(b.text));
  const paired = labels.length;
  if (loose.length > paired) {
    ok(out.includes("要点区"), `[${name}] 有 ${loose.length - paired} 条非卡片信息但缺要点区`);
  }

  return { name, len: out.length, cards: cardLines.length, prompt: out };
}

// ── 场景 1/2：直接传 blocks ──
const r1 = checkScene("口腔", DENTAL, "明亮诊室实景，数字化口扫设备，白色与薄荷绿，干净专业的医疗质感，自然光", { photo: { index: 1 }, logo: { index: 2 } });
const r2 = checkScene("烘焙", BAKERY, "暖木色烘焙门店，晨光从左侧照入，手作面包摆放在藤篮里，蒸汽与粗糙质感", { photo: { index: 1 }, logo: { index: 2 } });

// ── 场景 3：模型自己写的 prompt 里混着文案（无 blocks），走抽取兜底 ──
const r3 = pc.augment(
  "门店促销海报。主标题‘秋季上新’，副标题‘全场第二件半价’，产品‘栗子欧包’‘¥18’、‘栗子拿铁’‘¥26’，底部‘全国服务热线 400-826-7718’",
  { aspectRatio: "3:4" }
);
ok(r3.includes("逐字照写"), "[抽取兜底] 没生成文字清单");
ok(/网格系统/.test(r3), "[抽取兜底] 风格段缺网格约束");
ok(r3.length <= MAX_LEN, `[抽取兜底] ${r3.length} 字超上限`);

// ── 场景 4：普通配图不许被污染 ──
const cat = ic.apply(
  [{ id: "c", type: "function", function: { name: "image_generate", arguments: JSON.stringify({ prompt: "一只橘猫趴在窗台上晒太阳", aspect_ratio: "3:4" }) } }],
  { hasAny: false, roles: null, ratio: null, orientation: null, enforceSpec: null, userText: "画一只猫" },
  () => {}
);
const catArgs = JSON.parse(cat[0].function.arguments);
ok(!/逐字照写|风格：/.test(catArgs.prompt), "[普通配图] 被海报契约污染了");
ok(catArgs.prompt === "一只橘猫趴在窗台上晒太阳", "[普通配图] prompt 被改动");

// ── 场景 5：海报必须锁 3:4 ──
const poster = ic.apply(
  [{ id: "c", type: "function", function: { name: "image_generate", arguments: JSON.stringify({ prompt: "竖版门店海报", aspect_ratio: "2:3", structured: { text: [{ role: "title", text: "开业" }] } }) } }],
  { hasAny: true, roles: null, ratio: null, orientation: "portrait", enforceSpec: null, userText: "做一张开业海报" },
  () => {}
);
const posterArgs = JSON.parse(poster[0].function.arguments);
ok(posterArgs.aspect_ratio === "3:4", `[画布] 海报比例没锁到 3:4，实际 ${posterArgs.aspect_ratio}`);

// ── 场景 5.5：structured 是对象形态（labels/bodies）时，画布也必须锁 3:4 ──
const posterObj = ic.apply(
  [{ id: "c", type: "function", function: { name: "image_generate", arguments: JSON.stringify({ prompt: "竖版牙科视觉图", aspect_ratio: "2:3", structured: { title: "长好牙", labels: ["A", "B", "C"], bodies: ["1", "2", "3"] } }) } }],
  { hasAny: false, roles: null, ratio: null, orientation: null, enforceSpec: null, userText: "" },
  () => {}
);
const posterObjArgs = JSON.parse(posterObj[0].function.arguments);
ok(posterObjArgs.aspect_ratio === "3:4", `[画布] 对象形态文案没锁 3:4，实际 ${posterObjArgs.aspect_ratio}`);

// ── 场景 6：labels + bodies 双数组要配对成卡 ──
const pairs = pc.augment("咖啡店开业海报，奶油色背景", {
  aspectRatio: "3:4",
  structured: { title: "开业大吉", labels: ["手冲现磨", "开业活动", "门店地址"], bodies: ["当日现烘", "第二杯半价", "平江路 88 号"], contact: "400-123-4567" },
});
ok((pairs.match(/^「[^」]+」「/gm) || []).length >= 3, "[结构折叠] labels/bodies 没配对成卡片");

// ── 输出 ──
console.log("=".repeat(72));
console.log(`口腔场景：${r1.len} 字，${r1.cards} 张卡`);
console.log(`烘焙场景：${r2.len} 字，${r2.cards} 张卡`);
console.log("=".repeat(72));

if (warns.length) {
  console.log("\n提醒：");
  warns.forEach(w => console.log("  · " + w));
}
if (fails.length) {
  console.log(`\n未通过 ${fails.length} 项：`);
  fails.forEach(f => console.log("  ✗ " + f));
  console.log("\n不通过就不要跑图。");
  process.exit(1);
}
console.log("\n全部通过，可以出图。");
console.log("\n—— 口腔场景提示词全文 ——\n");
console.log(r1.prompt);
