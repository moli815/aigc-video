"use strict";
const {isHistoryPreview}=require('./shared/image-delivery');
const count=items=>items.reduce((n,t)=>n+[...(t.text||'').replace(/\s/g,'')].length,0);
function numberOf(s){if(/^\d+$/.test(s))return Number(s);if(s==='千')return 1000;if(s==='一千')return 1000;if(s==='两千'||s==='二千')return 2000;return null;}
// Explicit length in original user turns only; unrelated chat, assistant guesses
// and model preferences cannot become a content obligation.
function requirement(messages){let result=null;
 for(const m of messages||[]){if(m?.role!=='user'||isHistoryPreview(m))continue;const text=typeof m.content==='string'?m.content:Array.isArray(m.content)?m.content.filter(p=>p.type==='text').map(p=>p.text||'').join('\n'):'';
  if(!/海报|长图|宣传图|信息图/.test(text))continue;
  if(/(?:极简|少字|不要长文|不需要.{0,4}千字)/.test(text)){result=null;continue;}
  for(const hit of text.matchAll(/(?:(大约|大概|约|左右)\s*)?(\d{2,4}|一千|两千|二千|千)\s*字(?:左右)?/g)){
   if(/不要|不需要|不是/.test(text.slice(Math.max(0,hit.index-8),hit.index)))continue;
   const target=numberOf(hit[2]);if(target<100||target>4000)continue;result={target,min:Math.floor(target*.85),max:Math.ceil(target*1.3)};
  }
 }return result;
}
function assertCopy(items,r){if(r&&count(items)<r.min)throw Object.assign(Error('TOOL_ARGUMENTS_INVALID'),{code:'TOOL_ARGUMENTS_INVALID',reason:'CONTENT_INCOMPLETE',field:'structured.text',contentRequirement:r});}
module.exports={count,requirement,assertCopy};
