'use strict';

// An instruction belongs to the envelope. Never search the artwork brief for commands.
function extract(input) {
  if (typeof input !== 'string') return null;
  const match = /^([^\n：:]{1,180})[：:\n]([\s\S]+)$/u.exec(input.trimStart());
  if (!match) return null;
  const header = match[1].trim();
  const explicit = /(?:原样|逐字)(?:直传|传入|传给|发给|发送|输入|提交|生成|生图|出图)|(?:不要|别|无需|禁止|不做)(?:再|进行|任何)?(?:润色|改写|改动)(?:提示词|下面|这段|原文)?|提示词直传|(?:verbatim|without rewriting)/i;
  if (!explicit.test(header) || /[?？]|是否|能否|假如|如果|例如|举例|不要原样|别原样|不(?:要|用)直传|(?:标题|标语|台词)(?:是|写)/.test(header)) return null;
  if (!/提示词|生图|作图|做图|画图|出图|图像模型|绘图|传给.{0,8}模型|原样(?:直传|传入|传给|发给)|prompt/i.test(header)) return null;
  const body = match[2].replace(/^(?:\r?\n)/,'');
  if (!body.trim()) return null;
  return body;
}
// Shipped iPads combined generated attachment notes with the user's text. New
// transports keep each note separate, preserving even quoted marker text.
const attachmentNote = /^【(?:本轮附件图册】共有 \d+ 张独立图片。REF 番号|本轮附件图册未生成】部分图片未正确读取|图片附件：[^\n】]+】(?:$|\n)|图片文字OCR（辅助，可能有误差）：[^\n】]+】\n|用户上传的文件：[^\n】]+】\n)/u;
function authoredText(messages) {
  const { isHistoryPreview } = require('./image-delivery');
  const user = [...messages].reverse().find(m => m?.role === 'user' && !isHistoryPreview(m));
  if (!user) return '';
  const parts = Array.isArray(user.content) ? user.content : [{ type: 'text', text: user.content }];
  let texts = parts.filter(p => p?.type === 'text' && typeof p.text === 'string').map(p => p.text);
  if (texts[0]?.startsWith('【本次编辑前生成图预览】') && parts[1]?.type === 'image_url'
      && texts[1] === '【以下是用户本轮输入与上传附件，source_index仍按原附件顺序从1计数】') texts = texts.slice(2);
  else if (texts[0]?.startsWith('【本次生成图预览未读取】不能据此声称已看清编辑位置')) texts = texts.slice(1);
  const boundary = texts.findIndex(t => attachmentNote.test(t));
  if (boundary >= 0) return texts.slice(0, boundary).join('\n');
  let source = texts.join('\n');
  if (texts.length === 1 && parts.some(p => p?.type === 'image_url')) {
    const paragraphs = source.split('\n\n');
    const note = paragraphs.findIndex(p => attachmentNote.test(p));
    if (note >= 0) source = paragraphs.slice(0, note).join('\n\n');
  }
  return source;
}
function fromMessages(messages) {
  return extract(authoredText(messages));
}
function original(structured) {
  const text = structured?.verbatim_prompt;
  return typeof text === 'string' && text.trim() ? text : null;
}
module.exports = { extract, authoredText, fromMessages, original };
