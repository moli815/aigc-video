"use strict";

/**
 * 提示词契约（Prompt Contract）
 *
 * 依据：火山方舟《Seedream 4.0-5.0 提示词指南》
 *   1. 多图输入要指明「不同图像分别参考/编辑什么」；
 *   2. 要生成的文字放进引号/逐行列出，可提升文字准确率；
 *   3. 写出图像用途与类型（如「海报」），可提升场景适配度。
 *   4. 中文 prompt 控制在 300–600 字；过长会稀释文字权重。
 *
 * 2026-11-21 第三版（极简 + 逐行）：
 *   实测对照：1450 字「画面纪律 + 美学参照 + 分组文字」→ 小字 100% 崩；
 *              435 字「用途 + 素材 + 画面 + 逐行文字 + 三条风格」→ 六款产品名、
 *              说明、价格、电话全部正确，且 Seedream 自己排出了撕纸边缘、枫叶、
 *              手绘图标等设计元素。结论：版式交给它，我们只说清「要什么、做什么、
 *              给了什么」，文字逐行列出即可。
 *
 *   本模块只做四件事：写用途、标素材角色、裁剪画面描述、把文案逐行摆好。
 *   不写版式清单、不写坐标、不堆风格形容词。
 */

const MAX_LEN = 1100;      // 中文总字数上限。900 会挤掉「画面 + 风格」，1020 仍装不下
                           // STYLE + 网格句（实测 1076）会退回精简档，所以留到 1100。
const VISUAL_BUDGET = 160; // 画面描述保留字数（其余砍掉，避免稀释文字）
const COPY_BUDGET = 400;   // 文字清单总字数预算

const LIMIT = { title: 16, subtitle: 36, label: 12, body: 12, contact: 22, footer: 30 };
const COUNT = { title: 1, subtitle: 1, label: 6, body: 10, contact: 1, footer: 1 };

const PURPOSE = {
  "9:16": "竖版长图海报（朋友圈/易拉宝）",
  "3:4": "竖版门店海报",
  "2:3": "竖版印刷海报",
  "4:5": "竖版社媒海报",
  "1:1": "方形社媒海报",
  "16:9": "横版大屏海报",
  "4:3": "横版展架海报",
};

/** 三条底层风格底噪：信息密、有元素、不素。不写具体手法，留给模型发挥。 */
/**
 * 三条底层风格底噪：信息密集、每块有图形、不素。
 * 「标题区也要有装饰」来自实际反馈：大标题旁边留白会让整张图显得空。
 */
const STYLE = "风格：商业海报级成品，信息密集、分区清楚。底色要有色调与材质，不要大面积纯白；分区用色块、描边、丝带、印章，不要只靠细线；每个区块都要有图形（实拍、图标、示意图或插画），没有实拍就画示意图，不要只摆文字；标题周围与四角加装饰。严格遵循网格系统：同一行卡片等高、同栏等宽、元素对齐、间距统一、比例协调。构图重心在上方主视觉，向下自然过渡到浅色信息面（渐隐、羽化，不要硬边横切），底部留一条浅色信息带放联系方式。";
/** 精简版风格：文案量大、总长逼近上限时用它，保证「有色调、有元素」永远不被丢掉。 */
const STYLE_MIN = "风格：商业海报级成品，信息密集。底色要有色调与材质，不要纯白；分区用色块、描边、印章；每区都要有图形（实拍、图标或示意图），不要只摆文字；标题周围与四角加装饰；同一行卡片等高、同栏等宽、间距统一；主视觉在上，向下渐隐到浅色信息面，底部留信息带。";
// 2026-11-22 文字修复（依据官方 Seedream 5.5 指南 + 社区实测）：
// ① 每一处要印的字都放进「」，模型侧才是「确定的字符串」而不是「一串文字」；
// ② 写明层级/位置/字重，模型才知道谁是标题谁是价格，小字最先崩的就是缺少这层；
// ③ 负向约束要具体：英文伪字、乱码、水印、装饰数字，比笼统的「不要添加其他文字」有效；
// ④ 网格对齐单独一句，实测能明显减少元素错位与行距不匀。
const COPY_INTRO = "以下文字逐字照写、不得改动；画面不出现其它文字、伪字或乱码：";
const COPY_OUTRO = "排版：同类信息归成一区、每区有区头，不要摊平；文字不压图、不出血。";
// 2026-11-22：模型会自作主张加「门店经营看板」和编造的销售额/订单数（对话里从未要求）。
// 官方 5.5 指南指出提示词后段权重更高，所以禁令放在文字块最后一句，而不是只写在风格里。
// 2026-11-22 第 17 轮补充：模型会自己补一段「品牌故事」凑满版面，而这段字它没有原文，
// 只能瞎写——实测底部出现约 200 字的整段伪文字，比留白难看得多。
// 所以禁令必须点名「长段落」，只说「不出现未列出的文字」它不当回事。
const COPY_BAN = "禁止：不出现上面没列出的文字（含栏目名、标语、数据标签）；不写超过 20 字的连续长段落（品牌故事、公司简介、免责声明一律不写）；不出现销售额、订单数这类统计块；不出现看板、仪表盘、POS 或手机界面截图；不写「二维码空位」这类占位说明，留白即可。";

function ratioLabel(aspectRatio) {
  const m = /^(\d+(?:\.\d+)?):(\d+(?:\.\d+)?)$/.exec(String(aspectRatio || ""));
  return m ? `${m[1]}:${m[2]}` : "";
}

function roleParts(roles) {
  const out = [];
  if (roles && roles.poster) out.push(`图${roles.poster.index} 是旧稿，只参考栏目结构，不照抄它的文字`);
  if (roles && roles.photo) out.push(`图${roles.photo.index} 是实拍照片，只作主视觉用一次，不要在其他区块重复，人物与设备保持原比例`);
  if (roles && roles.logo) out.push(`图${roles.logo.index} 是公司 Logo 原件，原样使用，不加白底或边框`);
  return out;
}

/** 按标点回退到最近的分隔符，不产生半截词 */
function clip(text, max) {
  const t = String(text || "").replace(/\s+/g, " ").trim();
  if (!t) return "";
  if (t.length <= max) return t;
  const head = t.slice(0, max);
  const m = head.match(/^([\s\S]*)[，。、；：·|/（(]/);
  if (m && m[1].trim().length >= Math.max(4, Math.ceil(max * 0.5))) return m[1].trim();
  return head.trim();
}

function hardSplit(text, max) {
  const out = [];
  for (let i = 0; i < text.length; i += max) out.push(text.slice(i, i + max).trim());
  return out.filter(Boolean);
}

/** 长段落兜底：按句切，句子过长按逗号切并把碎片并回上一段，不产生半截词 */
function expand(text, max, limit) {
  const t = String(text || "").replace(/\s+/g, " ").trim();
  if (!t) return [];
  if (t.length <= max) return [t];
  const parts = [];
  for (const sent of t.split(/[。！？!?\n]+/)) {
    const s = sent.trim();
    if (!s) continue;
    if (s.length <= max) { parts.push(s); continue; }
    for (const clause of s.split(/[，、；;]/)) {
      const c = clause.trim();
      if (!c) continue;
      const last = parts[parts.length - 1];
      if (last && last.length + c.length + 1 <= max) parts[parts.length - 1] = last + "，" + c;
      else parts.push(c);
    }
  }
  // 过滤阈值放到 3 字：像「质保10年」「六寸整模」这类短规格只有 4-5 字，
  // 按 6 字过滤会把客户最想保住的参数直接丢掉（实测丢过「质保10年」）。
  return parts.filter(p => p.length >= 3).slice(0, limit);
}

/** 文案按「卡片」归组：label + body + price 合成一行，其他角色各占一行 */
function groupCopy(blocks, texts) {
  const src = Array.isArray(blocks) && blocks.length
    ? blocks.filter(b => b && typeof b.text === "string" && b.text.trim()).map(b => ({ role: String(b.role || "body"), text: b.text.trim() }))
    : (texts || []).filter(Boolean).map(t => ({ role: "body", text: String(t).trim() }));

  const out = { head: [], cards: [], foot: [] };
  const HEAD_MAX = 4;
  let used = 0;
  const room = n => used + n <= COPY_BUDGET;

  const loose = [];
  for (const item of src) {
    const text = item.text;
    const pendingCard = out.cards.length > 0 && !out.cards[out.cards.length - 1].body && !out.cards[out.cards.length - 1].price;
    if (item.role === "body" && !/^[¥￥]/.test(text) && !pendingCard) { loose.push(item); continue; }
    if (item.role === "title") {
      const t = clip(text, LIMIT.title);
      if (out.head.length < HEAD_MAX && room(t.length)) { out.head.push(t); used += t.length; }
      continue;
    }
    if (item.role === "subtitle") {
      const t = clip(text, LIMIT.subtitle);
      if (out.head.length < HEAD_MAX && room(t.length)) { out.head.push(t); used += t.length; }
      continue;
    }
    if (item.role === "contact" || item.role === "footer") {
      const t = clip(text, LIMIT[item.role]);
      // 电话与署名不受字数预算限制：漏了电话是硬伤
      if (out.foot.length < 2 && t) { out.foot.push(t); used += t.length; }
      continue;
    }
    if (item.role === "label") {
      if (out.cards.length >= COUNT.label) continue;
      const t = clip(text, LIMIT.label);
      if (!t || !room(t.length)) continue;
      out.cards.push({ label: t, body: "", price: "" });
      used += t.length;
      continue;
    }
    // body：价格单独成段，其余并入最近一张「命名卡」
    const isPrice = /^[¥￥$]\s*\d/.test(text) || /^\d+(?:\.\d+)?\s*元/.test(text);
    if (isPrice) {
      // 价格必须挂在最近的命名卡上。之前无条件赋给「最后一张卡」，
      // 说明被切成多段后会留下无 label 的散卡，价格就挂到散条目上——
      // 实测导致「栗子奶油欧包」缺价、¥18 跑到要点区。
      let idx = -1;
      for (let k = out.cards.length - 1; k >= 0; k--) if (out.cards[k].label) { idx = k; break; }
      const t = clip(text, 12);
      if (idx >= 0 && !out.cards[idx].price && room(t.length)) {
        out.cards[idx].price = t; used += t.length;
      }
      continue;
    }
    if (out.cards.filter(c => !c.label).length >= 4) continue;
    // 说明最多两段，都归同一张卡（用「·」连排），不再产生游离卡。
    const parts = text.length > LIMIT.body ? expand(text, LIMIT.body, 2) : [clip(text, LIMIT.body)];
    const last = out.cards[out.cards.length - 1];
    const target = last && last.label ? last : null;
    if (target) {
      const seg = Array.isArray(target.body) ? target.body : (target.body ? [target.body] : []);
      for (const part of parts) {
        if (!part || seg.length >= 2 || !room(part.length)) break;
        if (seg.includes(part)) continue;
        seg.push(part); used += part.length;
      }
      target.body = seg;
    } else {
      for (const part of parts) {
        if (!part || !room(part.length)) break;
        out.cards.push({ label: "", body: [part], price: "" });
        used += part.length;
        break;
      }
    }
  }
  // 第二轮：补最多 2 条松散说明（品牌故事/服务承诺），卡片优先占位
  for (const item of loose) {
    if (out.cards.filter(c => !c.label).length >= 4) break;
    if (out.head.length + out.cards.length + out.foot.length >= 14) break;
    for (const part of expand(item.text, LIMIT.body, 1)) {
      if (!part || !room(part.length)) break;
      out.cards.push({ label: "", body: [part], price: "" });
      used += part.length;
    }
  }
  return out;
}

/** 逐行渲染：卡片合成「标题 · 说明 · 价格」，一眼能对上 */
/** 把一句说明拆成规格角标：带数字的片段优先（那才是客户要保住的参数），
 *  过长的描述性片段直接丢掉——它一定被改写成卖点，留着只会把角标挤掉。 */
function badgeFrags(text, max = 2) {
  const raw = String(text || "");
  const out = [];
  // 第一优先：把「数字+单位」单独抽出来当角标（32 层、40 克、18 小时、质保 10 年）。
  // 这是客户要保住的硬参数，也是 OCR 校验比对的同一批 token；整句塞进去一定会被改写。
  const spec = /(?:质保|保修|周期|时长)?\s*(\d+(?:\.\d+)?)\s*(克|g|G|kg|ml|毫升|年|层|度|°|%|小时|分钟|个月|天|周)/.exec(raw);
  if (spec) out.push(`${spec[1]}${spec[2]}`.replace(/^(质保|保修)/, ""));
  // 第二优先：短卖点片段（≤6 字），长的直接丢——长句 100% 会被润色。
  const list = raw.split(/[·、,，/|]/).map(x => x.trim()).filter(x => x.length >= 2);
  for (const t of list) {
    if (out.length >= max) break;
    if (/[0-9]/.test(t)) continue;
    const cut = t.length <= 6 ? t : "";
    if (cut && !out.includes(cut)) out.push(cut);
  }
  return out.slice(0, max);
}

function copyLines(g) {
  const lines = [];

  // 标题区：官方 5.5 指南要求逐条加引号 + 写清层级。实测标题区最听话，
  // 每次都能逐字保留，所以主/副标题一定放在这里。
  g.head.forEach((h, i) => {
    if (!h) return;
    lines.push(i === 0
      ? `主标题「${h}」——全图最大，粗黑体，置于画面上方`
      : `副标题「${h}」——约为主标题的三分之一大小，常规体，紧跟主标题下方`);
  });

  const cards = g.cards.filter(c => c.label || c.body || c.price);
  const named = cards.filter(c => c.label);
  const loose = cards.filter(c => !c.label);

  if (named.length) {
    // 2026-11-22 第 12 轮：说明不再砍掉。
    // 上一版为了保价格把卡片说明全砍了，画面上只剩名称和价格，用户反馈「文字信息太少」。
    // 对照实测：口腔 6 卡 ×（名称/价格/说明）三块同排全部正确——关键不是块数少，
    // 而是同类信息成组、每区有区头；摊平成一片才会被模型合并丢弃。
    lines.push("产品卡（六张卡集中在同一区域，两列三行，不许拆散、不许合并；等高、等宽；卡片左侧画示意图或图标（产品轮廓、结构剖面、器械简图），不要只放文字；名称加粗、价格大号、说明一行写完且六张长度接近；数字原样照写）：");
    for (const c of named) {
      let body = Array.isArray(c.body) ? c.body.join("·") : c.body;
      // 两段说明连起来超过 14 字时，只保留带数字的那段：
      // 硬塞进一行会挤成两行，六张卡高度立刻不齐，而且长句必被改写。
      if (body && body.length > 14 && Array.isArray(c.body)) {
        const withDigit = c.body.find(x => /[0-9]/.test(x));
        body = withDigit || c.body[0];
      }
      // 价格必须跟名称粘成同一个字符串（2026-11-22 第 22 轮）：
      // 拆成「名称」「¥1280」两个引号块时，模型会把价格当可省略项，六款设备报价全丢；
      // 粘成「AC-2000 双目球机 ¥1280」后，它是同一个不可分割的名称块，丢不掉。
      const nameBlock = c.price ? `${c.label} ${c.price}` : c.label;
      const parts = [`「${nameBlock}」`];
      if (body) parts.push(`「${body}」`);
      lines.push(parts.join(""));
    }
  }

  if (loose.length) {
    // 非卡片信息（服务承诺、工艺参数、选购提示）单独成一区，带区头，
    // 不要混进产品卡里——混进去会被模型当说明改写。
    lines.push("要点区（产品卡下方一整块，不要拆成多栏；最多四行小字，每行前面加一个小圆点）：");
    for (const c of loose.slice(0, 4)) {
      const body = Array.isArray(c.body) ? c.body.join("·") : c.body;
      const row = [body, c.price].filter(Boolean).map(t => `「${t}」`).join("");
      if (row) lines.push(row);
    }
  }

  if (g.foot.length) {
    // 2026-11-22：只写「必须出现」时模型会用一句标语（如「从一颗栗子开始的温暖」）
    // 把底部信息带整条替换掉——它认为那样更美。改成给底部带指定左右位置与层级，
    // 模型才会照着填；这是官方指南里「写清位置」比「强调重要」更有效的直接证据。
    // 只给「一条」指令：之前写成左右两段，模型做成了两行，每行都带完整电话，
    // 结果同一组号码在底部印了两遍（2026-11-22 实测）。
    lines.push("底部信息带（画面最下方一条浅色带，必填，不得用标语替换；整带只出现一次，不要重复）：");
    lines.push(g.foot.filter(Boolean).map(t => `「${t}」`).join("　") + "　——同一行，顺序不变");
  }
  return lines;
}

/**
 * 从模型写的 prompt 里把文案抽出来。
 * 现状：部分模型不填 structured.text，而是把文案混在 prompt 描述里（如
 * 「主标题‘让每一处都看得见’超大白色粗体居顶」）。这里按标注词、引号、
 * 型号参数、电话号码四条线索抽取，抽不到就返回空数组（退回原行为）。
 */
function extractCopy(prompt) {
  const text = String(prompt || "");
  if (!text) return [];
  const blocks = [];
  const seen = new Set();
  const push = (role, value) => {
    const v = String(value || "").replace(/[‘’'"“”「」『』]/g, "").trim();
    if (!v || v.length < 2 || seen.has(v)) return;
    seen.add(v);
    blocks.push({ role, text: v });
  };

  // ① 带标注词的主/副标题
  const title = /(?:主标题|大标题|标题)\s*[:：]?\s*[‘’'"“”「『]?([^‘’'"“”「」』，。；\n]{2,20})/.exec(text);
  if (title) push("title", title[1]);
  const sub = /(?:副标题|副标|小标题)\s*[:：]?\s*[‘’'"“”「『]?([^‘’'"“”「」』，。；\n]{2,34})/.exec(text);
  if (sub) push("subtitle", sub[1]);

  // ② 型号 + 括号参数 → 一张卡（label=型号，body=参数）
  const modelRe = /([A-Z]{2,}[-\w]{2,})\s*[（(]([^）)]{4,60})[）)]/g;
  let m;
  while ((m = modelRe.exec(text))) {
    push("label", m[1]);
    push("body", m[2].replace(/[，,]/g, " "));
  }

  // ③ 引号包裹的短句（按顺序，长的当说明、短的当区块名）
  //    跳过方位/动作描述（「左上角放置安驰科技」不是画面文案）与已抽取的标题
  const quoted = /[‘’'"“”「『]([^‘’'"“”「」』\n]{2,40})[’'"”」』]/g;
  const norm = v => v.replace(/[\s/|\-—·、,，]/g, "");
  const taken = new Set(blocks.map(b => norm(b.text)));
  while ((m = quoted.exec(text))) {
    const v = m[1].trim();
    if (/^[\d\s.¥￥•·、|\/]+$/.test(v)) continue;
    if (/(放置|位于|放在|置于|叠加|作为|居中|居左|居右|左上|右上|左下|右下|背景)/.test(v)) continue;
    if (/(科技|公司|门店|连锁|口腔|教育|烘焙|bakery)$/i.test(v)) continue;
    if (norm(v).length < 2 || taken.has(norm(v))) continue;
    taken.add(norm(v));
    push(v.length <= 12 ? "label" : "body", v.replace(/\s*\/\s*/g, " "));
  }

  // ④ 电话
  const phone = /(1\d{10}|\d{3,4}[-\s]?\d{3,4}[-\s]?\d{4})/.exec(text);
  if (phone) push("contact", `全国服务热线 ${phone[1]}`);


  // 顺序规整：主标题、副标题在前后不动，其余保持出现顺序
  return blocks;
}

/**
 * 解析「整段文本」形态的 structured.text。
 * 实测：模型常把全部文案写成一个多行字符串（块之间空行分隔），而不是对象数组：
 *   齿悦口腔 / CHIYUE DENTAL / 种植牙专场 · 本月限定 / 重新长出一口好牙 /
 *   韩国奥齿泰种植体 + 说明 + ￥4980 / 全国服务热线 400-9902-517 ……
 * 这里按块识别品牌、活动标签、主标题、副标题、产品卡、价格、电话、长段落。
 */
function parseTextString(raw) {
  const raw1 = String(raw || "")
    .replace(/\r\n/g, "\n")
    .split(/\n{2,}/)
    .map(s => s.trim())
    .filter(Boolean);
  // 没有空行分隔时退化按单换行拆（模型常把整份文案写成连续多行）
  const chunks = raw1.length === 1 && /\n/.test(raw1[0])
    ? raw1[0].split(/\n/).map(s => s.trim()).filter(Boolean)
    : raw1;
  const blocks = [];
  let titleDone = false;
  let subtitleDone = false;

  for (const chunk of chunks) {
    const allLines = chunk.split(/\n/).map(s => s.trim()).filter(Boolean);
    if (!allLines.length) continue;

    // 产品卡：出现 ¥ 价格 → 整块按「名称 / 说明 / 价格」拆
    const price = allLines.find(l => /^[￥¥]\s*\d/.test(l));
    if (price) {
      const rest = allLines.filter(l => l !== price);
      if (rest[0]) blocks.push({ role: "label", text: rest[0] });
      if (rest[1]) blocks.push({ role: "body", text: String(rest[1]).split(/[·、]/)[0].trim() });
      blocks.push({ role: "body", text: price });
      continue;
    }

    const lines = [...allLines];
    // 品牌行（全大写英文，如 MAIHE BAKERY / CHIYUE DENTAL）单独成署名；
    // 同块里的中文品牌名（首行、短、无分隔符）一起带走，其余行继续判角色。
    const brandLines = lines.filter(l => /^[A-Z][A-Z\s&.'-]{2,}$/.test(l));
    if (brandLines.length) {
      const idx = lines.indexOf(brandLines[0]);
      const cn = idx <= 1 && lines[idx - 1] && lines[idx - 1].length <= 10 && !/[·|｜/／]/.test(lines[idx - 1]) ? lines.splice(idx - 1, 1)[0] : "";
      const stillBrand = lines.filter(l => brandLines.includes(l));
      for (const b of stillBrand) lines.splice(lines.indexOf(b), 1);
      blocks.push({ role: "footer", text: [cn, ...brandLines].filter(Boolean).join(" ") });
    }
    if (!lines.length) continue;

    // 电话块
    const phoneLine = lines.find(l => /(全国服务热线|服务热线|咨询热线|热线|电话)/.test(l) && /(1\d{10}|\d{3,4}[-\s]?\d{3,4}[-\s]?\d{4})/.test(l))
      || lines.find(l => /^(1\d{10}|\d{3,4}[-\s]?\d{3,4}[-\s]?\d{4})$/.test(l.replace(/\s/g, "")));
    const phone = phoneLine && (phoneLine.match(/(1\d{10}|\d{3,4}[-\s]?\d{3,4}[-\s]?\d{4})/) || [])[0];
    if (phone) {
      blocks.push({ role: "contact", text: `全国服务热线 ${phone}` });
      continue;
    }

    for (const line of lines) {
      // 长段落当说明，交给下游按句拆
      if (line.length > 40) { blocks.push({ role: "body", text: line }); continue; }
      // 主标题：第一个 ≤16 字、不含分隔符的短句
      if (!titleDone && line.length <= 16 && !/[·|｜/／]/.test(line)) {
        blocks.push({ role: "title", text: line });
        titleDone = true;
        continue;
      }
      // 副标题：紧跟主标题的一句
      if (titleDone && !subtitleDone && line.length <= 40) {
        blocks.push({ role: "subtitle", text: line });
        subtitleDone = true;
        continue;
      }
      blocks.push({ role: "body", text: line });
    }
  }
  return blocks;
}

/**
 * 把模型自创的结构（products / craft / member / labels / contact / footer…）
 * 折成统一的角色列表。实测同一模型会给出至少四种形态：
 *   text 数组 / text 多行字符串 / {title,subtitle,products[]} / 纯 prompt 描述。
 */
function structureToBlocks(s) {
  if (!s || typeof s !== "object" || Array.isArray(s)) return [];
  const out = [];
  const put = (role, v) => {
    const t = String(v == null ? "" : v).replace(/\s+/g, " ").trim();
    if (t) out.push({ role, text: t });
  };
  put("title", s.title || s.headline || s.main_title);
  put("subtitle", s.subtitle || s.sub_title || s.tagline);
  const products = Array.isArray(s.products) ? s.products : Array.isArray(s.items) ? s.items : [];
  for (const p of products.slice(0, 10)) {
    if (!p || typeof p !== "object") { put("body", p); continue; }
    put("label", p.name || p.title || p.label);
    put("body", p.body || p.desc || p.description || p.spec);
    const price = p.price != null ? String(p.price) : "";
    if (price) put("body", /^[¥￥]/.test(price) ? price : "¥" + price.replace(/[^\d.]/g, ""));
  }
  // labels + bodies 数量相等时按「栏目 + 说明」一一配对成卡片（2026-11-22）：
  // 模型常用这种双数组形态写栏目稿，旧实现把它们全当散点，结果产品卡区是空的，
  // 版面只剩要点区——用户看到的就是「信息少、没内容」。
  const labels = Array.isArray(s.labels) ? s.labels.filter(x => x != null && String(x).trim()) : [];
  const bodies = Array.isArray(s.bodies) ? s.bodies.filter(x => x != null && String(x).trim()) : [];
  const paired = labels.length >= 2 && labels.length === bodies.length;
  if (paired) {
    for (let i = 0; i < Math.min(labels.length, 8); i++) {
      put("label", labels[i]);
      put("body", bodies[i]);
    }
  }
  for (const key of ["craft", "member", "points", "features", "selling_points", "services"]) {
    if (!Array.isArray(s[key])) continue;
    for (const t of s[key].slice(0, 4)) {
      if (t && typeof t === "object") put("body", t.text || t.name || t.title);
      else put("body", t);
    }
  }
  // 没有配对成功时，labels 仍按散点收进来，不要整块丢掉
  if (!paired) for (const t of labels.slice(0, 4)) put("body", t);
  if (!paired) for (const t of bodies.slice(0, 4)) put("body", t);
  if (s.allergen) put("body", String(s.allergen).slice(0, 40));
  if (s.contact) {
    const c = String(s.contact).trim();
    put("contact", /热线|电话|咨询/.test(c) ? c : `全国服务热线 ${c}`);
  }
  if (s.footer) put("footer", s.footer);
  return out;
}

/** 统一入口：数组 → 字符串 → 自创结构 → 从 prompt 抽 */
/** 模型给文案的字段名不统一：text / content / value 都见过（2026-11-23 真实客户复现） */
function textOf(item) {
  if (item == null) return "";
  if (typeof item === "string") return item.trim();
  if (typeof item !== "object") return String(item).trim();
  const v = item.text != null ? item.text : (item.content != null ? item.content : (item.value != null ? item.value : ""));
  return String(v == null ? "" : v).trim();
}

function normalizeCopy(blocks, prompt, structured) {
  if (Array.isArray(blocks) && blocks.length) {
    return blocks.filter(b => b && textOf(b))
      // 模型有时用 type 而不是 role（2026-11-23 真实客户复现实测），
      // 只认 role 会把标题、电话全部降级成普通说明，层级和底部信息带全乱。
      .map(b => ({ role: String(b.role || b.type || "body"), text: textOf(b) }));
  }
  if (typeof blocks === "string" && blocks.trim()) {
    const parsed = parseTextString(blocks);
    if (parsed.length) return parsed;
  }
  const s = structured && typeof structured === "object" ? structured : null;
  if (s) {
    // structured.text 也可能是数组（真实链路通常已在 blocks 里传进来，这里兜底）
    if (Array.isArray(s.text) && s.text.length) {
      const arr = s.text.filter(b => b && textOf(b));
      if (arr.length) return arr.map(b => ({ role: String(b.role || b.type || "body"), text: textOf(b) }));
    }
    if (typeof s.text === "string" && s.text.trim()) {
      const parsed = parseTextString(s.text);
      if (parsed.length) return parsed;
    }
    // structured.text 本身是对象（{title, subtitle, products…}）时也要能解析
    if (s.text && typeof s.text === "object" && !Array.isArray(s.text)) {
      const folded = structureToBlocks(s.text);
      if (folded.length) return folded;
    }
    const folded = structureToBlocks(s);
    if (folded.length) return folded;
  }
  return extractCopy(prompt);
}

/** 去掉画面描述里的引号文字（已抽到文字清单，避免重复） */
function stripQuoted(prompt) {
  const src = String(prompt || "");
  let out = "";
  let depth = 0;
  const open = "‘'\"“「『";
  const close = "’'\"”」』";
  for (const ch of src) {
    if (open.includes(ch)) { depth++; continue; }
    if (close.includes(ch)) { if (depth > 0) depth--; continue; }
    if (depth === 0) out += ch;
  }
  return out.replace(/：\s*[，、]+/g, "：").replace(/[，、]{2,}/g, "，").replace(/，。/g, "。").replace(/。{2,}/g, "。").replace(/\s{2,}/g, " ").trim();
}

/** 画面描述瘦身：只留主体/场景/光线，砍掉版式与风格堆砌 */
function trimVisual(prompt, budget = VISUAL_BUDGET) {
  let t = String(prompt || "").replace(/\s+/g, " ").trim();
  if (!t) return "";
  // 去掉版式/字号类描述（版式交给模型）与已抽出的型号参数（已在文字清单里）
  t = t.replace(/[A-Z]{2,}[-\w]{2,}\s*[（(][^）)]{4,60}[）)]/g, "");
  // 只删「明确的排版指令」，不要误伤场景描述：
  // 旧规则 (左|右|上|下).{0,6}(放|排|占|留|区) 会把「晨光从左侧照入，面包摆放…」
  // 当成版式语句整段删掉，结果画面描述整条消失，模型只能自由发挥。
  const LAYOUT = /(左上|右上|左下|右下|上方|下方|顶部|底部|中间|左侧|右侧).{0,4}(放置|放在|摆放|排在|占据|留白|留出)|占画面.{0,4}%|第[一二三四五]层|分[两三]栏|主标题|副标题|大标题|小标题|字号|居中|居顶|居底|加粗|粗体|描边|发光/;
  t = t.split(/[。；;]/).filter(s => s && !LAYOUT.test(s)).join("。");
  if (t.length <= budget) return t;
  const head = t.slice(0, budget);
  const cut = Math.max(head.lastIndexOf("。"), head.lastIndexOf("，"));
  return (cut > budget * 0.5 ? head.slice(0, cut) : head).trim();
}

function build(prompt, opts, level) {
  const { roles, aspectRatio, blocks, texts, company, contact } = opts;
  const ratio = ratioLabel(aspectRatio);
  const purpose = PURPOSE[ratio] || "商业宣传海报";
  const seg = [];

  // 模型没给 structured.text 时，从它写的 prompt 里把文案抽回来
  const source = normalizeCopy(blocks, prompt, opts && opts.structured);

  if (level !== "minimal") {
    seg.push(`用途：${purpose}。`);
    const rl = roleParts(roles);
    if (rl.length) seg.push(`素材：${rl.join("；")}。`);
  }

  // 画面描述里已抽取的引号文字要删掉，避免同一句话出现两次
  const visualSrc = stripQuoted(prompt);
  const visual = level === "minimal" ? "" : trimVisual(visualSrc, level === "compact" ? 100 : VISUAL_BUDGET);
  // 主标题写进「画面」段的**开头**（2026-11-22 第 16 轮）：
  // 之前单独占一行，模型仍会为画面氛围改写——「栗香上市」被写成「秋天的栗香」
  // 和「用一颗面包温暖每一天」。画面描述是它执行力最强的地方，而描述的第一个元素
  // 就是它的构图起点，所以标题必须排在画面描述最前面，且明确「既定文案、不得润色」。
  const gHead = groupCopy(source, texts).head;
  const titleCue = gHead[0] && level !== "minimal"
    ? `画面上方是全图最大的标题「${gHead[0]}」（品牌既定文案，逐字照写，不许换词、不许加前后缀）`
    : "";
  const visualAll = [titleCue, visual].filter(Boolean).join("；");
  if (visualAll) seg.push(`画面：${visualAll}`);
  // 风格段永不可省：一省就是纯白底、没元素的白底表格。
  seg.push(level === "full" ? STYLE : STYLE_MIN);

  const g = groupCopy(source, texts);
  const lines = copyLines(g);
  if (lines.length) {
    seg.push(COPY_INTRO + "\n" + lines.join("\n"));
    // 排版与禁令在最小档也要留：它们是「不摊平、不乱加字」的最后一道约束。
    seg.push(COPY_OUTRO);
    if (level !== "minimal") seg.push(COPY_BAN);
  }

  if (company && level !== "minimal" && !lines.some(l => l.includes(company))) seg.push(company);
  if (contact && level !== "minimal" && !lines.some(l => l.includes(String(contact).replace(/\D/g, "")))) seg.push(`全国服务热线 ${contact}`);

  return seg.join("\n");
}

/** 在模型 prompt 后追加契约；超长自动降级 */
function augment(prompt, opts = {}) {
  for (const level of ["full", "compact", "minimal"]) {
    const out = build(prompt, opts, level);
    if (out.length <= MAX_LEN) return out;
  }
  const source = normalizeCopy(opts.blocks, prompt, opts.structured);
  const lines = copyLines(groupCopy(source, opts.texts));
  return `用途：商业宣传海报。\n${STYLE_MIN}\n${COPY_INTRO}\n${lines.join("\n")}`.slice(0, MAX_LEN);
}

module.exports = {
  augment, roleParts, PURPOSE, STYLE, MAX_LEN, COPY_BUDGET,
  groupCopy, copyLines, clip, expand, trimVisual, extractCopy, parseTextString, structureToBlocks, normalizeCopy, textOf,
};
