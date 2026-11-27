"use strict";

/**
 * 参考图原文提取（Reference Transcription）
 *
 * 为什么需要它：
 *   对话模型在「一边看参考图、一边设计版面和写文案」时，会把术语改写成近义说法
 *   （实测：PGM接口→PoE接口、多防区接口→多协议接口）。
 *   但同一张图，如果只让它「照抄文字」，实测 26 项能抄对 23 项，剩下 3 项是原图换行导致的断句，
 *   不是识别错误。
 *
 * 所以做法是：先把原文抄下来（一次额外调用），再把这份清单作为「逐字稿」交给它去设计。
 * 这样模型不需要再"猜"字，只需要排版。
 *
 * 成本：整图一次 ≈ 4s / 0.007 元（DeepSeek 图片按 ~800×800 折算、单张 384 token）。
 */

const TRANSCRIBE_PROMPT = [
  "逐行列出图中出现的所有中文文字，原样输出，不要翻译、不要改写、不要补全、不要解释。",
  "只输出文字本身，每行一条。看不清的字用 ？ 代替。",
].join("");

const DESIGN_HINT = /海报|宣传|设计|重绘|重新做|重新生成|做成|排版|长图|宣传图|信息图|banner|封面/i;
function restylesReference(text) {
  const value=String(text||"");
  return /(?:换|改|重做|重新生成|重绘).{0,35}(?:风格|样式|画风)|(?:换成|改成|改为|换为)[^，。；\n]{1,18}风(?=的|[，。；\n]|并|同时|$)|(?:风格|画风).{0,12}(?:换|改)/.test(value)
    && !/(?:删|去掉|移除|替换|修改|改写|新增).{0,8}(?:文案|文字|标题|栏目|内容|产品)|不要.{0,8}(?:保留|照抄)/.test(value);
}
function latestUserMessage(messages) {
  return [...(Array.isArray(messages)?messages:[])].reverse().find(m=>m?.role==="user"&&!require("./shared/image-delivery").isHistoryPreview(m));
}

function lastUserText(messages) {
  const last = latestUserMessage(messages);
  const c = last && last.content;
  if (typeof c === "string") return c;
  if (Array.isArray(c)) return c.filter(p => p && p.type === "text").map(p => p.text || "").join("\n");
  return "";
}

function currentImageParts(messages) {
  const parts = latestUserMessage(messages)?.content;
  if (!Array.isArray(parts)) return [];
  const previews = parts[0]?.text?.startsWith('【本次编辑前生成图预览】') && parts[1]?.type === 'image_url'
    && parts[2]?.text === '【以下是用户本轮输入与上传附件，source_index仍按原附件顺序从1计数】';
  return (previews ? parts.slice(3) : parts).filter(p => p?.type === 'image_url' && typeof p.image_url?.url === 'string');
}

function sourceImageIndex(text, count) {
  if (count === 1) return 1;
  // Mixed attachments have a source only when the user identifies it.
  const refs = [...String(text || '').matchAll(/图([一二三四五六1-6])(?:是|为)(?:原海报|原稿|原图|底图)|(?:把|将)图([一二三四五六1-6])(?:的海报)?(?:重绘|重排|重新排版|改|换)/gu)];
  const slots = [...new Set(refs.map(match => {
    const number = match[1] || match[2];
    return Number(number) || '一二三四五六'.indexOf(number) + 1;
  }))];
  return slots.length === 1 && slots[0] <= count ? slots[0] : null;
}

function firstUserImage(messages) {
  const images = currentImageParts(messages);
  const text = require('./shared/verbatim-image-prompt').authoredText(messages);
  const source = sourceImageIndex(text, images.length);
  return source ? images[source - 1].image_url.url : '';
}

/** 是否值得做前置转录：有图 + 是设计类诉求 */
function shouldTranscribe(messages) {
  const url = firstUserImage(messages);
  if (!url) return false;
  if (!/^data:image\//i.test(url)) return false;                 // 只处理内联图，避免再拉一次外链
  if (url.length > 8 * 1024 * 1024) return false;                 // 太大的不冒险
  if (/只(?:改|加|换)|保持.{0,8}(?:原图|版式|比例)/.test(lastUserText(messages))) {
    // 局部小改不需要重抄全文
    return false;
  }
  return DESIGN_HINT.test(lastUserText(messages)) || restylesReference(lastUserText(messages));
}

function linesOf(text) {
  return String(text || "")
    .split("\n")
    .map(s => s.trim().replace(/^(?:[-*•]\s+|\d+[.、]\s+)/, ""))
    .filter(s => s.length >= 2 && s.length <= 1000)
    .filter(s => !/^(好的|以下是|图中|文字如下|注[:：])/.test(s));
}

/**
 * 用对话模型把图里的字抄下来。
 * @param {{imageUrl:string, callModel:(messages:Array)=>Promise<{content:string,usage?:object}>}} p
 */
async function transcribe({ imageUrl, callModel }) {
  if (!imageUrl || typeof callModel !== "function") return null;
  const res = await callModel([{
    role: "user",
    content: [
      { type: "text", text: TRANSCRIBE_PROMPT },
      { type: "image_url", image_url: { url: imageUrl } },
    ],
  }]);
  const lines = linesOf(res && res.content);
  if (!lines.length) return null;
  return { lines, usage: (res && res.usage) || null };
}

/** 生成注入给模型的「逐字稿」系统消息 */
function verbatimMessage(lines) {
  if (!Array.isArray(lines) || !lines.length) return null;
  const list = lines.slice(0, 60).join(" / ");
  return [
    "【参考图逐字稿】下面是从本轮原图读出的文字，遇到不清楚的字符以原图为准：",
    list,
    "本轮 structured.text 必须**从这份逐字稿里逐字取用**：不得替换成近义术语（例如 PGM 接口不能写成 PWM/PoE，多防区接口不能写成多协议接口），不得改写数字与型号。",
    "逐字稿里没有的信息不要编造；确实缺少的公司名/电话，用已知信息或留空，不要填占位词。",
  ].join("\n");
}

/**
 * 近似术语修复：模型把逐字稿里的词写成了近义/错字版本时，改回逐字稿的写法。
 * 只在「长度相同或差 1」且「首字相同」时替换，避免误伤正常创作文案。
 */
function repairTerms(text, lines) {
  if (typeof text !== "string" || !text || !Array.isArray(lines) || !lines.length) return { text, fixed: [] };
  const SUFFIX = /(接口|探测器|警笛|门磁|烟雾器|组网|防水|画质|夜视|语音|警戒|监控|编码|报警平台|一体机)$/;
  const vocab = lines.filter(l => /^[\u4e00-\u9fa5A-Za-z0-9]{2,12}$/.test(l) && SUFFIX.test(l));
  const fixed = [];
  let out = text;
  for (const term of vocab) {
    if (out.includes(term)) continue;
    const n = term.length;
    // 在文本里找「等长、首字相同、末两字相同」的片段，判为同一术语的错写
    for (let i = 0; i + n <= out.length; i++) {
      const seg = out.slice(i, i + n);
      if (!/^[\u4e00-\u9fa5A-Za-z0-9]+$/.test(seg)) continue;
      if (seg === term) break;
      if (seg[0] !== term[0]) continue;
      if (seg.slice(-2) !== term.slice(-2)) continue;
      if (!SUFFIX.test(seg)) continue;
      out = out.slice(0, i) + term + out.slice(i + n);
      fixed.push({ from: seg, to: term });
      break;
    }
  }
  return { text: out, fixed };
}

function keepSourceLines(blocks, lines) {
  const normalize = s=>String(s||"").replace(/\s+/g,"");
  const result=Array.isArray(blocks)?[...blocks]:[];
  const printed=()=>result.map(b=>normalize(b?.text)).join("\n");
  const used=new Set(result.map(b=>b?.key));
  for(const line of lines.slice(0,60)){
    if(typeof line!=="string" || !line.trim() || /[?？]/.test(line) || printed().includes(normalize(line)))continue;
    let key="source_copy_"+(result.length+1);
    while(used.has(key))key+="_";
    used.add(key);
    result.push({key,role:"label",text:line});
  }
  return result;
}

module.exports = { currentImageParts, sourceImageIndex, restylesReference, keepSourceLines, shouldTranscribe, transcribe, verbatimMessage, repairTerms, linesOf, firstUserImage, lastUserText, TRANSCRIBE_PROMPT };
