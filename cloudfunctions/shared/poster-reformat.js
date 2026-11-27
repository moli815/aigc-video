"use strict";
// Explicit whole-artwork reflow is different from generating an illustration
// and from crop/outpaint. This contract travels through existing structured.
const VERSION=1;
function excluded(a){return !!a.structured?.print_catalog||a.structured?.exact_logo_addition===true||a.layer_decomposition===true||Number(a.requested_count||a.requestedCount||1)>1||['series','decompose'].includes(a.task_kind||a.taskKind)||a.text_mode==='overlay'||a.structured?.preserve_assets?.length||['mockup'].includes(a.render_intent||a.renderIntent);}
function normalizeDirection(text){
 return String(text||"")
  .replace(/(?:不要|别|避免|禁止|不用|勿|不能|不可)[^，。；、\n]{0,6}?(横版|横向|横屏|横图)/g,"竖版")
  .replace(/(?:不要|别|避免|禁止|不用|勿|不能|不可)[^，。；、\n]{0,6}?(竖版|竖向|竖屏|竖图)/g,"横版");
}
function ratioOf(text,current){
 const normalized=normalizeDirection(text);
 // A target after “改成/转为” may follow a description of the input canvas.
 const target=normalized.split(/(?:改成|改为|转成|转为|换成|调整为)\s*(?=[横竖0-9])/).at(-1);
 // A horizontal footer is a layout detail, even on a portrait canvas.
 const canvas=target.replace(/(?:横向|竖向)(?:的)?(?:服务保障条|条带|横条|线条|分隔线|时间线|进度条|排列|排布)/g,'');
 const direction=[...canvas.matchAll(/竖(?:版|向|屏|图)|横(?:版|向|屏|图)/g)].at(-1)?.[0];
 const portrait=direction?.startsWith('竖'),landscape=direction?.startsWith('横');
 const valid=(w,h)=>w>0&&h>0&&w/h>=1/4&&w/h<=4&&(!portrait||h>w)&&(!landscape||w>h);
 const nums=[...canvas.matchAll(/(\d{1,4}(?:\.\d+)?)\s*(?:[:：×xX*]|比)\s*(\d{1,4}(?:\.\d+)?)/g)];
 const n=nums.filter(m=>valid(+m[1],+m[2])).at(-1);
 if(n){const a=+n[1],b=+n[2],gcd=(x,y)=>y?gcd(y,x%y):x,g=gcd(Math.round(a*100),Math.round(b*100));return`${Math.round(a*100)/g}:${Math.round(b*100)/g}`;}
 const m=/^(\d+(?:\.\d+)?):(\d+(?:\.\d+)?)$/.exec(String(current||''));
 if(m&&valid(+m[1],+m[2]))return current;
 return portrait?'9:16':landscape?'16:9':null;
}
function derive(text,args={}){
 if(excluded(args)||typeof text!=='string'||!text.trim()||text.length>12000)return null;
 // A style reference for an unrelated new subject is not an artwork to reflow.
 if(/只(?:参考|借鉴).{0,8}(?:风格|配色)|(?:只|仅)(?:加|贴|换).{0,8}(?:logo|标志)|(?:只|仅).{0,8}(?:扩图|补边|裁切|裁剪)/i.test(text))return null;
 const source=/(?:原图|原海报|这张|该图|图[一二1-9]|附件|参考图|背景图|横图|竖图)/.test(text);
 const change=/(?:改|转|重排|重新排|根据|基于|生成|做|制作|输出)/.test(text);
 const target=/(?:竖(?:版|向|屏|图)|横(?:版|向|屏|图)|\d\s*[:：×xX*]\s*\d)/.test(text);
 if(!source||!change||!target)return null;
 const ratio=ratioOf(text,args.aspect_ratio||args.aspectRatio);if(!ratio)return null;
 return{version:VERSION,mode:'recompose',target_aspect_ratio:ratio,user_request:text.trim()};
}
function metadata(raw,args){
 if(!raw||raw.version!==VERSION||raw.mode!=='recompose'||typeof raw.user_request!=='string')return null;
 const intent=derive(raw.user_request,{...args,aspect_ratio:raw.target_aspect_ratio});
 return intent&&intent.target_aspect_ratio===raw.target_aspect_ratio?intent:null;
}
function mark(args,userText){
 const out={...args,structured:{...args.structured}};delete out.structured.poster_reformat;
 const hasSource=['attached','last','both'].includes(args.source)||Array.isArray(args.source_indexes)&&args.source_indexes.length>0||['edit','reference'].includes(args.task_kind||args.taskKind);
 const intent=hasSource?derive(userText,args):null;
 if(intent){out.structured.poster_reformat=intent;out.aspect_ratio=intent.target_aspect_ratio;}
 return out;
}
function normalize(body){
 if(excluded(body)||require('./verbatim-image-prompt').original(body.structured))return body;
 const kind=body.task_kind||body.taskKind||'',hasImage=Array.isArray(body.image)?body.image.length>0:!!body.image;
 // A finalized new poster may mention attachment slots and aspect in the
 // visual brief. Only a real user-derived reflow marker can override it.
 const allowLegacyInference=body.structured?.poster_delivery?.version!==1;
 const intent=metadata(body.structured?.poster_reformat,body)||(allowLegacyInference&&hasImage&&['edit','reference','generate',''].includes(kind)?derive(body.prompt,body):null);
 if(!intent)return body;
 // Pixel size may describe the input or a stale client canvas. Preserve its
 // resolution budget, but resolve the newly requested aspect on the server.
 const dimensions=/^(\d+)x(\d+)$/i.exec(String(body.size||''));
 const size=dimensions?(+dimensions[1]*+dimensions[2]>2610000?'2K':'1.5K'):body.size;
 return{...body,...(size?{size}:{}),task_kind:'reference',aspect_ratio:intent.target_aspect_ratio,structured:{...body.structured,poster_reformat:intent}};
}
function plan(input){
 if(excluded(input))return null;
 const intent=metadata(input.structured?.poster_reformat,input);if(!intent)return null;
 const images=Array.isArray(input.image)?input.image:input.image?[input.image]:[];
 if(!images.length)throw Object.assign(Error('REFORMAT_REFERENCE_REQUIRED'),{code:'REFORMAT_REFERENCE_REQUIRED'});
 const rich=/工业质感|产品细节|相关元素|有层次|商业质感|现场实景|丰富/.test(intent.user_request);
 const art=rich?"\n用用户要求的实景材质和光影建立连续背景。用相关局部特写、结构线或简洁图标解释不同栏目，接近可发布的商业海报。沿原图色系，主体与文案清晰分层，栏目随内容调整尺寸、错落组织，避免三个同样的矩形加一块纯色底。装饰全用无字图形。名称和说明逐字沿用原图，禁止新增标题、流程说明、小字标注、编号和图标配字。":"";
 const strict=/不加新内容|别加新内容|不新增|不得改字|原文保留/.test(intent.user_request);
 const required=Array.isArray(input.structured?.text)?input.structured.text.map(row=>row?.text).filter(row=>typeof row==="string"&&row.trim()):[];
 const copy=strict?"\n必须印出这些原版文案："+required.map(text=>JSON.stringify(text)).join("、")+"。其余只允许原图产品自身标签原样出现。背景不出现显示器、带字仪表、数字看板、流程文字、装饰字符或标牌。用纯实物、材质、光影和无字图案丰富。":"";
 const roles=images.length>1?'\n'+images.map((_,i)=>`图${i+1}：${String(input.referenceRoles?.[i]||(i===0?'待改版的原海报':'用户补充素材')).slice(0,120)}`).join('\n'):'';
 return{intent,prompt:`将输入原图完整重排为${intent.target_aspect_ratio}的平面宣传海报，设计填满目标画布。用户本轮要求：${JSON.stringify(intent.user_request)}。${roles}\n按用户要求重新安排各栏目位置、大小与阅读顺序，保留原图的全部业务内容、名称解释、流程、品牌Logo、联系方式和真实产品/大屏素材；用户明确更新的信息以本轮要求为准。未要求换风格时延续原图美术，要求换风格时遵循用户指定风格。不要整体缩小贴在空白画布，不裁掉栏目，不换成无关场景配图再套正文模板，不生成纸张或拍摄样机。原文准确清晰，不添加原图或用户未提供的口号、数据和承诺。${art}${copy}`};
}
module.exports={VERSION,derive,ratioOf,normalizeDirection,mark,normalize,metadata,plan};
