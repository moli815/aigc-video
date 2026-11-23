"use strict";

/**
 * 交付要求守卫（Requirement Guard）
 *
 * 背景：实测发现，把 8 条硬性要求写进请求，成品质量会从「白底 Logo / 占位 / 文字重复 / 拉伸」
 * 变成「干净可交付」。但那 8 条现在只活在测试脚本里。
 * 这个模块把它变成产品行为：自动识别附件角色、自动生成要求、自动校验返回的文案。
 *
 * 只做三件事：
 *   1. 读附件尺寸，判断哪张是 Logo、哪张是照片、哪张是参考旧稿
 *   2. 产出「交付要求」系统消息（不写死具体文案，只写约束）
 *   3. 对模型给的 structured.text 做硬校验与修补（缺公司名/缺热线/有占位/有重复）
 */

const { restylesReference } = require("./reference-text");
const LOGO_MAX_RATIO = 3.2;   // Logo 一般扁平但不至于超过 3.2:1

/** 读 data URL 里图片的宽高（只解析头部，不整图解码） */
function imageSize(dataUrl) {
  try {
    const m = /^data:image\/(png|jpeg|jpg);base64,(.+)$/i.exec(String(dataUrl || ""));
    if (!m) return null;
    const buf = Buffer.from(m[2], "base64");
    if (m[1].toLowerCase() === "png") {
      if (buf.length < 24 || buf.readUInt32BE(12) !== 0x49484452) return null;
      return { w: buf.readUInt32BE(16), h: buf.readUInt32BE(20), type: "png" };
    }
    // JPEG: 找 SOF
    let i = 2;
    while (i + 9 < buf.length) {
      if (buf[i] !== 0xff) { i++; continue; }
      const marker = buf[i + 1];
      const len = buf.readUInt16BE(i + 2);
      if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc) {
        return { w: buf.readUInt16BE(i + 7), h: buf.readUInt16BE(i + 5), type: "jpeg" };
      }
      i += 2 + len;
    }
    return null;
  } catch { return null; }
}

/** 收集本轮用户消息里的内联图（按出现顺序） */
function collectImages(messages) {
  const out = [];
  for(const part of require("./reference-text").currentImageParts(messages)){
    if(!/^data:image\//i.test(part.image_url.url))continue;
    out.push({index:out.length+1,size:imageSize(part.image_url.url)});
  }
  return out;
}

/**
 * 判定附件角色。
 * 规则：面积最小的扁图 → logo；面积最大的 → 参考/旧稿；其余 → 素材照片。
 * 只有 1 张时不做角色假设。
 */
function classify(images, userText) {
  const valid = images.filter(i => i.size && i.size.w > 0 && i.size.h > 0);
  const mentionsOldText = String(userText || "");
  const oldSemantics = /旧稿|旧版|上一版|之前的|原来那|改版|重绘|这张海报|参考这版|照着这版/.test(mentionsOldText);
  if (valid.length === 0) return { logo: null, poster: null, photo: null, count: 0 };
  // 只有一张图时也必须能判角色：小扁图当 Logo，否则按语义在「旧稿 / 素材照片」之间选
  if (valid.length === 1) {
    const only = valid[0];
    if(restylesReference(mentionsOldText))return {logo:null,poster:only,photo:null,count:1};
    const ratio = only.size.w / only.size.h;
    const area = only.size.w * only.size.h;
    if (ratio <= LOGO_MAX_RATIO && area < 400 * 200) return { logo: only, poster: null, photo: null, count: 1 };
    return oldSemantics
      ? { logo: null, poster: only, photo: null, count: 1 }
      : { logo: null, poster: null, photo: only, count: 1 };
  }
  const withArea = valid.map(i => ({ ...i, area: i.size.w * i.size.h, ratio: i.size.w / i.size.h }));
  const sorted = [...withArea].sort((a, b) => a.area - b.area);
  const smallest = sorted[0];
  const largest = sorted[sorted.length - 1];
  const logo = smallest.ratio <= LOGO_MAX_RATIO && smallest.area * 3 < largest.area ? smallest : null;
  // 「旧稿」必须有语义证据：用户提到旧/上一版/改版/这张海报/重绘；否则面积最大的当素材照片
  const text = String(userText || "");
  const mentionsOld = /旧稿|旧版|上一版|之前的|原来那|改版|重绘|这张海报|参考这版|照着这版/.test(text);
  const rest = withArea.filter(i => i !== logo);
  const poster = mentionsOld && rest.length ? rest[rest.length - 1] : null;
  const photo = rest.find(i => i !== poster) || null;
  return { logo, poster, photo, count: valid.length };
}

/**
 * 生成交付要求（只写约束，不写具体文案）
 */
function buildRequirements({ roles, company, contact }) {
  // 刻意不用「1. 2. 3.」编号：模型会模仿输入格式，把要求转写成逐条版式清单，
  // 结果 Seedream 收到一份「版式说明书」，画面死板、背景乱堆装饰。
  const parts = [];
  parts.push("同一段文字在画面里只出现一次，不要一处标题、另一处再写一遍");
  parts.push("不出现「品牌名称」「公司名称」「待补充」「XXX」这类占位词");
  parts.push("图片素材保持原始宽高比，不拉伸变形");
  parts.push("画布比例与 aspect_ratio 完全一致");
  parts.push("小字清晰可读，不生成带糊英文的假界面");
  if (roles && roles.logo) parts.push("第 " + roles.logo.index + " 张附件是公司 Logo，直接用附件里的原图形，不重画、不加白底或方框");
  if (roles && roles.photo) parts.push("第 " + roles.photo.index + " 张附件是实拍素材，作主视觉并保持人物与设备原比例");
  if (roles && roles.poster) parts.push("第 " + roles.poster.index + " 张附件是要改版的旧稿，栏目与文字一个都不能丢");
  if (company) parts.push("公司全称固定写作「" + company + "」");
  if (contact) parts.push("联系方式固定写作「" + contact + "」");
  // 多附件时最容易出的错：模型把数据看板/价目表整张截图贴进画面
  const imgCount = [roles && roles.logo, roles && roles.photo, roles && roles.poster].filter(Boolean).length;
  if (imgCount >= 3) parts.push("附件里除指定的主视觉与旧稿外，其余图片仅作信息参考——只提取其中的数值和文字，不要把整张界面截图贴进画面");
  return "【交付要求】以下是硬性约束，直接执行，不要把要求本身画进画面：" + parts.join("；") + "。";
}

const PLACEHOLDER = /^(?:品牌名称|公司名称|公司名字|待补充|待填写|XXX+|示例|示例文字)$/;

/**
 * 对 structured.text 做硬校验与修补。返回修补后的 blocks 与问题清单。
 */
function enforce(blocks, { company, contact }) {
  const issues = [];
  if (!Array.isArray(blocks)) return { blocks, issues: ["no_blocks"] };
  let out = blocks.map(b => ({ ...b }));

  // 占位词：有真值就替换，没有就删
  out = out.filter(b => {
    const t = String(b.text || "").trim();
    if (!PLACEHOLDER.test(t)) return true;
    const isCompanySlot = /品牌名称|公司名称|公司名字/.test(t);
    if (isCompanySlot && company) { b.text = company; issues.push("placeholder_filled"); return true; }
    issues.push("placeholder_removed");
    return false;
  });

  // 重复段：同一段文字出现多次，只留第一次
  const seen = new Set();
  out = out.filter(b => {
    const key = String(b.text || "").replace(/\s/g, "");
    if (!key) return true;
    if (seen.has(key)) { issues.push("duplicate_removed"); return false; }
    seen.add(key);
    return true;
  });

  const joined = out.map(b => String(b.text || "")).join("\n");
  if (company && !joined.includes(company)) {
    out.push({ key: "company_name", role: "footer", text: company });
    issues.push("company_injected");
  }
  if (contact && !joined.replace(/\D/g, "").includes(contact.replace(/\D/g, ""))) {
    out.push({ key: "contact_hotline", role: "contact", text: `全国服务热线 ${contact}` });
    issues.push("contact_injected");
  }
  return { blocks: out, issues };
}

/** 比例容差：实际与请求偏差超过 8% 视为不合格 */
function ratioMismatch(requested, actualW, actualH) {
  const m = /^(\d+(?:\.\d+)?)\s*[:：]\s*(\d+(?:\.\d+)?)$/.exec(String(requested || ""));
  if (!m || !actualW || !actualH) return false;
  const want = Number(m[1]) / Number(m[2]);
  const got = actualW / actualH;
  return Math.abs(got - want) / want > 0.08;
}

module.exports = { imageSize, collectImages, classify, buildRequirements, enforce, ratioMismatch };
