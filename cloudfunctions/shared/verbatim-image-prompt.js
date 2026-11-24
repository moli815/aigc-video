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
function original(structured) {
  const text = structured?.verbatim_prompt;
  return typeof text === 'string' && text.trim() ? text : null;
}
module.exports = { extract, original };
