"use strict";
// Candidate compiler, not connected to customer routing until acceptance passes.
// Official contract: qwen-image-generation-and-editing-api-reference (2026-11-05).
const MODELS=new Set(["qwen-image-3.0-pro","qwen-image-3.0"]);
function failure(code){return Object.assign(new Error(code),{code});}
function resolveQwenSize(value){
 const m=/^(\d+)[x*](\d+)$/.exec(String(value||""));
 if(!m)throw failure("QWEN_EXPLICIT_SIZE_REQUIRED");
 let w=Number(m[1]),h=Number(m[2]);
 if(!Number.isSafeInteger(w)||!Number.isSafeInteger(h)||w<1||h<1||Math.max(w/h,h/w)>8)throw failure("QWEN_RATIO_UNSUPPORTED");
 if(w*h<512*512)throw failure("QWEN_SIZE_TOO_SMALL");
 const scale=Math.min(1,Math.sqrt((2048*2048)/(w*h)));
 if(scale<1){w=Math.floor(w*scale/8)*8;h=Math.floor(h*scale/8)*8;}
 if(w*h>2048*2048||w*h<512*512||Math.max(w/h,h/w)>8)throw failure("QWEN_SIZE_UNSUPPORTED");
 return w+"x"+h;
}
function compileQwenImage(input,options={}){
 const model=options.model||"qwen-image-3.0-pro";
 if(!MODELS.has(model))throw failure("QWEN_MODEL_UNSUPPORTED");
 if(input.layer_decomposition===true||input.task_kind==="decompose")throw failure("QWEN_LAYERS_UNSUPPORTED");
 const refs=input.image==null?[]:Array.isArray(input.image)?input.image:[input.image];
 if(refs.length>3)throw failure("QWEN_REFERENCE_LIMIT");
 if(refs.some(x=>typeof x!=="string"||!x.trim()))throw failure("QWEN_REFERENCE_INVALID");
 const prompt=String(input.prompt||"").trim();if(!prompt)throw failure("QWEN_PROMPT_REQUIRED");
 // No truncation of copy, refs, or canvas ratio. Pixel-area normalization only.
 const payload={model,prompt,size:resolveQwenSize(input.size),n:1,watermark:false,
  prompt_extend:options.promptExtend!==false,prompt_extend_mode:"direct",enable_thinking:true};
 if(options.noText===true)payload.negative_prompt='文字，汉字，字母，数字，伪文字，水印，标题，表格，文档页面，海报排版，说明标注，界面，色卡，配色表，字体样张，拼贴说明板';
 if(refs.length)payload.image=refs.length===1?refs[0]:refs.slice();
 if(options.seed!=null){if(!Number.isInteger(options.seed)||options.seed<0||options.seed>2147483647)throw failure("QWEN_SEED_INVALID");payload.seed=options.seed;}
 if(options.protocol==='dashscope'){
  const {model,prompt,image,size,...parameters}=payload;
  const refs=Array.isArray(image)?image:image?[image]:[];
  return {model,input:{messages:[{role:'user',content:[...refs.map(image=>({image})),{text:prompt}]}]},parameters:{...parameters,size:size.replace('x','*')}};
 }
 return payload;
}
function qwenImageCost(payload,usage){
 if(!MODELS.has(payload.model))throw failure("QWEN_MODEL_UNSUPPORTED");
 const m=/^(\d+)[x*](\d+)$/.exec(payload.size||payload.parameters?.size);if(!m)throw failure("QWEN_EXPLICIT_SIZE_REQUIRED");
 const width=usage?.output_width??Number(m[1]),height=usage?.output_height??Number(m[2]);
 const inputs=usage?.input_image_count??(payload.input?(payload.input.messages||[]).flatMap(x=>x.content||[]).filter(x=>x.image).length:Array.isArray(payload.image)?payload.image.length:payload.image?1:0);
 const outputs=usage?.output_image_count??1;
 if(![width,height,inputs,outputs].every(Number.isSafeInteger)||width<1||height<1||inputs<0||outputs<1||inputs>3||outputs>6)throw failure("QWEN_USAGE_INVALID");
 const output=payload.model.endsWith("-pro")?(width*height>2250000?.50:.25):.18;
 return Number((output*outputs+.02*inputs).toFixed(4));
}
function parseQwenImageResponse(value){
 const urls=[...(value?.data||[]).map(x=>x?.url),...(value?.output?.choices||[]).flatMap(x=>x.message?.content||[]).map(x=>x.image)].filter(x=>typeof x==="string"&&x.startsWith("https://"));
 if(value?.error||value?.code||urls.length!==1)throw failure(value?.error?.code||value?.code||"QWEN_RESULT_INVALID");
 return {url:urls[0],usage:value.usage||null};
}
module.exports={compileQwenImage,resolveQwenSize,qwenImageCost,parseQwenImageResponse};
