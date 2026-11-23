"use strict";
const crypto=require('node:crypto');
// Audit the original PNG, not a nearest-neighbour thumbnail. This preserves
// input evidence; a VLM transcription still cannot certify glyph sharpness.
function prepareAuditInput(bytes,{model='',providerBase=''}={}){
 if(!Buffer.isBuffer(bytes)||bytes.length<24||bytes.length>24*1024*1024||!bytes.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10])))throw Error('AUDIT_PNG_REQUIRED');
 const width=bytes.readUInt32BE(16),height=bytes.readUInt32BE(20);
 if(!width||!height||width*height>40e6)throw Error('AUDIT_PIXEL_LIMIT');
 let host='';try{host=new URL(providerBase).hostname;}catch{}
 const highResolution=/(^|\.)(?:dashscope\.aliyuncs\.com|maas\.aliyuncs\.com)$/.test(host)&&/^qwen(?:3(?:\.[5-8])?(?:-vl)?|4)(?:-|$)/i.test(model);
 return {part:{type:'image_url',image_url:{url:'data:image/png;base64,'+bytes.toString('base64'),detail:'high'}},
   options:highResolution?{vl_high_resolution_images:true}:{},
   evidence:{width,height,bytes:bytes.length,sha256:crypto.createHash('sha256').update(bytes).digest('hex'),resampled:false,providerHighResolutionRequested:highResolution,glyphAcceptance:'separate_visual_review_required'}};
}
module.exports={prepareAuditInput};
