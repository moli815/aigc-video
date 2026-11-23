"use strict";
const MAX_OUTPUTS=8;
const validOutputCount=n=>Number.isInteger(n)&&n>=2&&n<=MAX_OUTPUTS;
// One server-owned opt-in for native art, protected originals and glyph repair.
// Defaults remain off. No App parameter can opt an account into paid stages.
function policyOf(raw){let p;try{p=typeof raw==='string'?JSON.parse(raw):raw;}catch{return null;}const c=p?.nativeCopy;
 if(!c||c.enabled!==true||!['all',undefined].includes(c.audience)||c.accountIds!==undefined&&(!Array.isArray(c.accountIds)||c.accountIds.length>100||c.accountIds.some(a=>typeof a!=='string'||!a||a.length>160)))return null;
 if(c.audience!=='all'&&!Array.isArray(c.accountIds))return null;
 if(c.maxOutputs!==undefined&&!validOutputCount(c.maxOutputs))return null;
 if(c.minChars!==undefined&&(!Number.isInteger(c.minChars)||c.minChars<0||c.minChars>4000))return null;
 return{audience:c.audience||'allowlist',accountIds:c.accountIds||[],maxOutputs:c.maxOutputs||2,minChars:c.minChars??0};
}
function enabled(raw,owner){const p=policyOf(raw);return !!(p&&typeof owner==='string'&&owner&&(p.audience==='all'||p.accountIds.includes(owner)));}
function eligible(raw,owner,body){return enabled(raw,owner)&&body&&Number(body.requested_count||body.requestedCount||1)===1&&body.layer_decomposition!==true&&!body.structured?.preserve_assets?.length&&body.text_mode!=='overlay'&&!['mockup'].includes(body.render_intent||body.renderIntent)&&['generate','reference'].includes(body.task_kind||body.taskKind||(body.image?'edit':'generate'))&&Array.isArray(body.structured?.text)&&body.structured.text.some(t=>t.role==='body'&&typeof t.text==='string'&&t.text.trim())&&body.structured.text.reduce((n,t)=>n+(typeof t?.text==='string'?t.text.trim().length:0),0)>=policyOf(raw).minChars;}
module.exports={policyOf,enabled,eligible,MAX_OUTPUTS,validOutputCount};
