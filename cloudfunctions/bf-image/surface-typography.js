"use strict";
// Reuse a native composition; restore real glyphs only on measured flat ink
// surfaces. No HTML/SVG from a model, no fixed column template, no text rewrite.
const crypto=require("crypto"),{PNG}=require("pngjs"),{decode}=require("./protected-asset-compositor");
const error=code=>Object.assign(new Error(code),{code});
function rect(raw,w,h,minimum=12){
 if(!Array.isArray(raw)||raw.length!==4||raw.some(n=>!Number.isFinite(n))||raw[0]<0||raw[1]<0||raw[2]<=0||raw[3]<=0||raw[0]+raw[2]>1.00001||raw[1]+raw[3]>1.00001)throw error("SURFACE_BOX_INVALID");
 const x=Math.round(raw[0]*w),y=Math.round(raw[1]*h),width=Math.round(raw[2]*w),height=Math.round(raw[3]*h);
 if(width<minimum||height<minimum||x+width>w||y+height>h)throw error("SURFACE_BOX_INVALID");return {x,y,width,height};
}
const intersects=(a,b)=>a.x<b.x+b.width&&b.x<a.x+a.width&&a.y<b.y+b.height&&b.y<a.y+a.height;
const contains=(a,b)=>b.x>=a.x&&b.y>=a.y&&b.x+b.width<=a.x+a.width&&b.y+b.height<=a.y+a.height;
function validate(plan,items,width,height){
 if(!plan||!Array.isArray(plan.surfaces)||!Array.isArray(plan.blocks)||!Array.isArray(plan.protected)||plan.surfaces.length>64||plan.blocks.length>160)throw error("SURFACE_PLAN_INVALID");
 if(!Array.isArray(items)||!items.length||items.length>160||items.some(t=>!t?.key||typeof t.text!=="string"||!t.text.trim()||t.text.length>8000)||items.reduce((n,t)=>n+t.text.length,0)>16000||new Set(items.map(t=>t.key)).size!==items.length)throw error("SURFACE_COPY_INVALID");
 const source=new Map(items.map(t=>[t.key,t])),protectedAreas=plan.protected.map(b=>rect(b,width,height,1));
 if(!protectedAreas.length)throw error("SURFACE_PROTECTION_REQUIRED");
 const surfaces=plan.surfaces.map(s=>{const box=rect(s.box,width,height);if(!/^#[0-9a-f]{6}$/i.test(s.color||"")||protectedAreas.some(p=>intersects(box,p)))throw error("SURFACE_UNSAFE_ERASE");return {...box,color:s.color};});
 const used=new Set(),blocks=plan.blocks.map(b=>{
  if(!source.has(b.key)||used.has(b.key))throw error("SURFACE_COPY_COVERAGE");used.add(b.key);
  const box=rect(b.box,width,height),item=source.get(b.key),minimum=["title"].includes(item.role)?width*.035:Math.max(22,Math.min(width,height)*.013);
  if(!Number.isFinite(b.fontSize)||b.fontSize<minimum||b.fontSize>width*.15||![400,700].includes(b.weight)||!/^#[0-9a-f]{6}$/i.test(b.color||"")||!["left","center","right"].includes(b.align))throw error("SURFACE_TYPE_INVALID");
  const lineHeight=b.lineHeight??1.38,letterSpacing=b.letterSpacing??0;
  if(!Number.isFinite(lineHeight)||lineHeight<1.2||lineHeight>1.8||!Number.isFinite(letterSpacing)||letterSpacing<0||letterSpacing>b.fontSize*.12)throw error('SURFACE_TYPE_INVALID');
  if(!surfaces.some(s=>contains(s,box))||protectedAreas.some(p=>intersects(box,p)))throw Object.assign(error("SURFACE_TYPE_UNSAFE"),{key:b.key});
  return {...box,key:b.key,text:item.text,role:item.role,fontSize:b.fontSize,weight:b.weight,color:b.color,align:b.align,lineHeight,letterSpacing};
 });
 if(used.size!==items.length||items.some(t=>!used.has(t.key)))throw error("SURFACE_COPY_COVERAGE");
 for(let i=0;i<blocks.length;i++)if(blocks.slice(i+1).some(b=>intersects(blocks[i],b)))throw error("SURFACE_TEXT_OVERLAP");
 return {surfaces,blocks,protectedAreas};
}
function perimeterAudit(r,s){
 const color=s.color.slice(1).match(/../g).map(h=>parseInt(h,16)),samples=[];
 for(let x=s.x;x<s.x+s.width;x+=Math.max(1,Math.floor(s.width/80)))for(const y of [s.y,s.y+s.height-1])samples.push((y*r.width+x)*4);
 for(let y=s.y;y<s.y+s.height;y+=Math.max(1,Math.floor(s.height/80)))for(const x of [s.x,s.x+s.width-1])samples.push((y*r.width+x)*4);
 const mismatch=samples.filter(i=>color.some((c,k)=>Math.abs(r.data[i+k]-c)>26)).length/samples.length;
 if(mismatch>.035)throw error("SURFACE_BACKGROUND_NOT_FLAT");
 let total=0,nonBackground=0;for(let y=s.y;y<s.y+s.height;y+=Math.max(1,Math.floor(s.height/100)))for(let x=s.x;x<s.x+s.width;x+=Math.max(1,Math.floor(s.width/100))){total++;const i=(y*r.width+x)*4;if(color.some((c,k)=>Math.abs(r.data[i+k]-c)>26))nonBackground++;}
 if(nonBackground/total>.30)throw error("SURFACE_BACKGROUND_NOT_FLAT");
 return {samples:samples.length,mismatch,nonBackgroundRatio:nonBackground/total};
}
async function render({canvas,items,plan,fonts,satori,resvg,decomposedBackground=false,nativeGlyphs=false}){
 const r=decode(canvas),p=validate(plan,items,r.width,r.height),audits=decomposedBackground?[]:p.surfaces.map((s,index)=>{try{return perimeterAudit(r,s);}catch(e){throw Object.assign(e,{surfaceIndex:index});}});
 let outlines;
 if(nativeGlyphs){
  if(plan.blocks.some(b=>!Number.isFinite(b.nativeInkHeight)||b.nativeInkHeight<8||b.nativeInkHeight>b.fontSize*2||b.align!=='left'||(b.letterSpacing??0)!==0))throw error('SURFACE_NATIVE_METRICS_INVALID');
  outlines=await require('./native-glyph-layout').prepareAreas({areas:p.blocks.map((b,i)=>({key:b.key,text:b.text,box:[0,0,b.width,b.height],fontSize:b.fontSize,weight:b.weight,lineHeight:b.lineHeight,fitNativeFont:true,observedInkHeight:plan.blocks[i].nativeInkHeight})),fonts});
 }
 // Validate and render every block before mutating the destination. A failing
 // font/overflow/geometry leaves the caller's draft intact; no auto-shrink.
 const patches=[];
 for(const b of p.blocks){let measured=[],unsupported=false;
  let svg;
  if(outlines){const matched=outlines.find(o=>o.key===b.key);if(!matched)throw error('SURFACE_COPY_COVERAGE');svg=require('./native-glyph-layout').svgOf(matched.layout,{width:b.width,height:b.height,color:b.color});b.fontSize=matched.fontSize;b.glyphCount=matched.layout.glyphCount;b.glyphCopyHash=matched.layout.copyHash;}
  else{
  const tree={type:"div",props:{style:{display:"flex",width:b.width,height:b.height,fontFamily:"Noto CJK",fontSize:b.fontSize,fontWeight:b.weight,color:b.color,alignItems:"flex-start"},children:{type:"div",props:{"data-copy-key":b.key,style:{display:"flex",width:b.width,flexShrink:0,whiteSpace:"pre-wrap",wordBreak:"break-word",lineHeight:b.lineHeight,letterSpacing:b.letterSpacing,textAlign:b.align},children:b.text}}}};
  svg=await satori(tree,{width:b.width,height:b.height,fonts,embedFont:true,loadAdditionalAsset:async()=>{throw error("SURFACE_GLYPH_UNAVAILABLE");},onStyleError:()=>{unsupported=true;},onNodeDetected:n=>{if(n.props?.["data-copy-key"])measured.push(n);}});
  if(unsupported||measured.length!==1||measured.some(n=>!Number.isFinite(n.height)||n.height>b.height+1||n.width>b.width+1))throw error("SURFACE_TEXT_OVERFLOW");
  }
  let engine,frame;try{engine=new resvg.Resvg(svg,{font:{loadSystemFonts:false},fitTo:{mode:"width",value:b.width*2}});frame=engine.render();const raw=PNG.sync.read(Buffer.from(frame.asPng()));patches.push({b,raw});}finally{frame?.free?.();engine?.free?.();}
 }
 const output=Buffer.from(r.data);
 if(!decomposedBackground)for(const s of p.surfaces){const rgb=s.color.slice(1).match(/../g).map(h=>parseInt(h,16));for(let y=s.y;y<s.y+s.height;y++)for(let x=s.x;x<s.x+s.width;x++){const i=(y*r.width+x)*4;output[i]=rgb[0];output[i+1]=rgb[1];output[i+2]=rgb[2];output[i+3]=255;}}
 for(const {b,raw}of patches){if(raw.width!==b.width*2||raw.height!==b.height*2)throw error("SURFACE_RASTER_SIZE");const inkColor=b.color.slice(1).match(/../g).map(h=>parseInt(h,16));for(let y=0;y<b.height;y++)for(let x=0;x<b.width;x++){
  const pixels=[((y*2)*raw.width+x*2)*4,((y*2)*raw.width+x*2+1)*4,((y*2+1)*raw.width+x*2)*4,((y*2+1)*raw.width+x*2+1)*4],alpha=pixels.reduce((n,i)=>n+raw.data[i+3],0)/1020,at=((b.y+y)*r.width+b.x+x)*4;
  if(!alpha)continue;const destinationAlpha=output[at+3]/255,resultAlpha=alpha+destinationAlpha*(1-alpha);
  // These blocks are single-colour text. Use exact configured ink with the
  // glyph coverage mask instead of unpremultiplying quantised low-alpha PNG RGB.
  for(let k=0;k<3;k++)output[at+k]=Math.round((inkColor[k]*alpha+output[at+k]*destinationAlpha*(1-alpha))/resultAlpha);output[at+3]=Math.round(255*resultAlpha);
 }}
 const png=PNG.sync.write({width:r.width,height:r.height,data:output});
 return {png,manifest:{version:"surface-typography-experiment-v1",width:r.width,height:r.height,copyHash:crypto.createHash("sha256").update(JSON.stringify(items.map(t=>[t.key,t.text]))).digest("hex"),sourceHash:crypto.createHash("sha256").update(canvas).digest("hex"),boxes:p.blocks.map(({text,...b})=>b),surfaces:p.surfaces,protected:p.protectedAreas,backgroundAudits:audits}};
}
module.exports={validate,render,perimeterAudit,rect};
