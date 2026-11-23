"use strict";
const { planPosterCanvas, ratioOf } = require("./shared/poster-canvas");
// Existing aspect_ratio field only: no new binary or client field required.
// Opt-in at the server caller. Local edits and old client composition stay intact.
function adaptPosterCanvasCalls(calls, { enabled = false, userText = "", messages = [] } = {}) {
  if (!enabled || !Array.isArray(calls)) return calls;
  const text = String(userText);
  if (!/海报|宣传图|信息图|长图/.test(text)) return calls;
  if(/只(?:改|加|换)|保持.{0,8}(?:原图|版式|比例)|(?:原图|版式|比例).{0,5}(?:不变|别动|不改)/.test(text))return calls;
  const requested = text.match(/(?:宽高比|比例|做成|改成)\s*(\d+(?:\.\d+)?)\s*[:：比x×]\s*(\d+(?:\.\d+)?)/i)
    || text.match(/(\d+(?:\.\d+)?)\s*[:：比x×]\s*(\d+(?:\.\d+)?)\s*的?(?:横版|竖版|海报|宣传图|信息图|产品长图|长图)/i);
  const fixed = requested ? `${requested[1]}:${requested[2]}` : "";
  const auto = /比例.{0,6}(?:你|自动|灵活|内容)|(?:按|根据)信息量|自动.{0,4}(?:比例|画布)/.test(text);
  return calls.map(call => {
    if (call?.function?.name !== "image_generate") return call;
    let a; try { a = JSON.parse(call.function.arguments); } catch { return call; }
    if (a.text_mode === "overlay" || a.layer_decomposition || a.render_intent === "mockup" || a.structured?.preserve_assets?.length) return call;
    if (!Array.isArray(a.structured?.text) || a.structured.text.length < 4) return call;
    if (fixed && !ratioOf(fixed)) return call;
    const explicitLandscape=/横版|横着|宽幅|横向|横屏/.test(text),explicitPortrait=/竖版|纵向|竖屏|手机长图/.test(text);
    const existing = ratioOf(a.aspect_ratio), chars = a.structured.text.reduce((n,b)=>n+String(b.text||"").replace(/\s/g,"").length,0);
    if(!fixed&&!auto&&existing&&messages.some(m=>{
      if(m?.role!=="user"||require('./shared/image-delivery').isHistoryPreview(m))return false;
      const t=typeof m.content==='string'?m.content:Array.isArray(m.content)?m.content.filter(p=>p?.type==='text').map(p=>p.text||'').join('\n'):'';
      const match=t.match(/(?:输出|画布|宽高比|比例|做成|改成)\s*(\d+(?:\.\d+)?)\s*[:：比x×]\s*(\d+(?:\.\d+)?)/i);
      return match&&ratioOf(`${match[1]}:${match[2]}`)?.ratio===existing.ratio;
    }))return call; // Do not overwrite a user-established ratio remembered by the planner.
    const orientation=explicitLandscape?"landscape":explicitPortrait?"portrait":existing?.ratio>1?"landscape":"portrait";
    // Retain a suitable deliberate model choice; auto does not mean every
    // dense request must be rewritten to one universal long-image template.
    if(!fixed&&existing){
      const directionExplicit=explicitLandscape||explicitPortrait;
      const directionFits=!directionExplicit||(orientation==="landscape"?existing.ratio>1:existing.ratio<1);
      const requiredPortrait=chars>800?9/28:chars>500?9/21:9/16;
      const densityFits=chars<=500||(existing.ratio<1?existing.ratio<=requiredPortrait&&existing.ratio>=1/4:existing.ratio>=21/9&&existing.ratio<=4);
      if(directionFits&&densityFits)return call;
    }
    const canvas = planPosterCanvas({ blocks: a.structured.text, aspectRatio: fixed, orientation });
    if (a.aspect_ratio === canvas.aspectRatio) return call;
    return { ...call, function: { ...call.function, arguments: JSON.stringify({ ...a, aspect_ratio: canvas.aspectRatio }) } };
  });
}
async function reviewAndAdaptPosterCalls(calls,{review,...options}={}){
 const reviewed=typeof review==='function'?await review(calls):calls;
 // Content review can grow an existing draft after the initial tool-boundary
 // sizing. Re-evaluate the final copy, keeping explicit/remembered user ratios.
 return adaptPosterCanvasCalls(reviewed,options);
}
module.exports = { adaptPosterCanvasCalls,reviewAndAdaptPosterCalls };
