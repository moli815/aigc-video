"use strict";
// Bounded local typography experiment, NOT enabled by the HTTP runtime.
// OpenCV's documented text-mask/inpaint path + embedded real font outlines.
// No palette, poster template, wording generation or external model call.
const {PNG}=require('pngjs'),geo=require('./protected-asset-compositor'),crypto=require('node:crypto');
const fail=(code,extra)=>{throw Object.assign(Error(code),{code,...extra});};
const delta=(a,b)=>Math.max(...a.map((v,k)=>Math.abs(v-b[k])));
// Offline proposal only: geometry comes from uniquely matched provider lines,
// not the fixed coordinates of the reviewed sample. This does not enable the
// HTTP renderer or turn provider OCR into canonical copy / semantic proof.
function proposeNativeAreas({original,rows,items,requireFullCopy=true,scopes=[]}){
 const raster=geo.decode(original),{width,height}=raster;
 const matches=require('./native-copy-refinement').matchFieldsOf({rows,items,width,height,requireFullCopy,scopes});
 const all=rows.flatMap(row=>(row.text_recognition?.lines||[]).map((line,i)=>({id:row.index+':'+i,b:line.bounding_box.absolute})));
 const overlap=(a,b,axis)=>Math.max(0,Math.min(a[axis+2],b[axis+2])-Math.max(a[axis],b[axis]));
 function rowSeparator(upper,lower,colour){
  const a=(upper[1]+upper[3])/2,b=(lower[1]+lower[3])/2,fallback=Math.floor((a+b)/2);
  if(b<=a||b-a>64||!/^#[a-f0-9]{6}$/i.test(colour||''))return fallback;
  const left=Math.max(0,Math.max(upper[0],lower[0])),right=Math.min(width,Math.min(upper[2],lower[2])),start=Math.ceil(a+2),end=Math.floor(b-2);
  if(right-left<12||end<=start)return fallback;
  const rgb=colour.slice(1).match(/../g).map(v=>parseInt(v,16)),sample=(x,y)=>Array.from(raster.data.subarray((y*width+x)*4,(y*width+x)*4+3));
  const corners=[sample(Math.max(0,left-4),start),sample(Math.min(width-1,right+4),start),sample(Math.max(0,left-4),end),sample(Math.min(width-1,right+4),end)];
  const bg=[0,1,2].map(k=>corners.map(p=>p[k]).sort((a,b)=>a-b)[2]);
  if(delta(rgb,bg)<100)return fallback;
  const spans=[];for(let y=start;y<=end;y++){
   let ink=0;for(let x=left;x<right;x++){const p=sample(x,y);if(delta(p,rgb)<80&&delta(p,bg)>60)ink++;}
   if(ink<=Math.max(1,(right-left)*.005)){const last=spans.at(-1);if(last&&last[1]===y-1)last[1]=y;else spans.push([y,y]);}
  }
  const best=spans.filter(s=>s[1]>s[0]).sort((x,y)=>(y[1]-y[0])-(x[1]-x[0])||Math.abs((x[0]+x[1])/2-fallback)-Math.abs((y[0]+y[1])/2-fallback))[0];
  return best?Math.floor((best[0]+best[1]+1)/2):fallback;
 }
 const proposed=matches.map(({item,r,lineIds,d})=>{
  const own=new Set(lineIds),lines=r.text_recognition.lines,boxes=lines.map(l=>l.bounding_box.absolute),first=boxes[0],last=boxes.at(-1);
  const union=[Math.min(...boxes.map(b=>b[0])),Math.min(...boxes.map(b=>b[1])),Math.max(...boxes.map(b=>b[2])),Math.max(...boxes.map(b=>b[3]))];
  if(boxes.some((b,i)=>i&&b[1]<=boxes[i-1][1]))fail('FLAT_COPY_READING_ORDER');
  const heights=boxes.map(b=>b[3]-b[1]),fontSize=Math.max(11,Math.floor(Math.min(...heights)*.75));
  const colour=lines[0]?.runs?.[0]?.style?.foreground_color;
  if(!/^#[a-f0-9]{6}$/i.test(colour||''))fail('FLAT_COPY_CONTRACT');
  // Native text may occupy a left/middle column. Extending every right edge
  // to the canvas margin swallowed unrelated photos and neighbouring cards.
  // Measured ink bounds, not the full page, define this local repair surface.
  let top=0,bottom=height,right=Math.min(width,union[2]+5);
  for(const other of all){if(own.has(other.id))continue;const b=other.b;
   if(overlap(union,b,1)>Math.min(union[3]-union[1],b[3]-b[1])*.4&&b[0]>=union[2]-2)right=Math.min(right,Math.floor((union[2]+b[0])/2));
   if(overlap(union,b,0)>Math.min(union[2]-union[0],b[2]-b[0])*.5){
    const centre=(b[1]+b[3])/2;
    if(centre<(first[1]+first[3])/2)top=Math.max(top,rowSeparator(b,first,colour));
    else if(centre>(last[1]+last[3])/2)bottom=Math.min(bottom,rowSeparator(last,b,colour));
   }
  }
  if(right<union[2]||top>=bottom)fail('FLAT_COPY_NEIGHBOUR_CONFLICT',{key:item.key});
  const errors=[];
  for(const padding of [5,4,3,2,1,0]){
   const area={key:item.key,text:item.text,box:[Math.max(0,union[0]-5),Math.max(top,union[1]-padding),Math.floor(right),Math.min(bottom,union[3]+padding)],fontSize,weight:['title','subtitle','label'].includes(item.role)?700:400,color:colour,lineHeight:1.25};
   try{const measured=sampleMask(raster,area);return{area,evidence:{lineIds,ocrSubstitutions:d,padding,mask:measured.metrics}};}catch(e){errors.push({code:e.code||e.message,box:area.box,edge:e.edge,maxAlpha:e.maxAlpha});}
  }
  fail('FLAT_COPY_NO_SAFE_NATIVE_AREA',{key:item.key,causes:errors});
 });
 for(let i=0;i<proposed.length;i++)for(const other of proposed.slice(i+1))if(overlap(proposed[i].area.box,other.area.box,0)>0&&overlap(proposed[i].area.box,other.area.box,1)>0)fail('FLAT_COPY_OVERLAP');
 return{areas:proposed.map(p=>p.area),evidence:proposed.map(({area,evidence})=>({key:area.key,...evidence})),geometrySource:'official_lines_unique_canonical_match',requiresReview:true,fullCopy:requireFullCopy===true};
}
function checkArea(area,width,height){
 const b=area?.box;if(!Array.isArray(b)||b.length!==4||b.some(n=>!Number.isInteger(n))||b[0]<0||b[1]<0||b[2]>width||b[3]>height||b[2]<=b[0]||b[3]<=b[1]||b[2]-b[0]<12||b[3]-b[1]<12)fail('FLAT_COPY_GEOMETRY');
 if(typeof area.key!=='string'||!area.key||typeof area.text!=='string'||!area.text.trim()||area.text.length>1000||!/^#[a-f0-9]{6}$/i.test(area.color||'')||!Number.isFinite(area.fontSize)||area.fontSize<11||area.fontSize>100||![400,700].includes(area.weight))fail('FLAT_COPY_CONTRACT');
 return b;
}
function sampleMask(r,area){
 const b=checkArea(area,r.width,r.height),width=b[2]-b[0],height=b[3]-b[1],data=Buffer.alloc(width*height*4),channels=[[],[],[]];
 for(let y=0;y<height;y++)for(let x=0;x<width;x++){
  const from=((y+b[1])*r.width+x+b[0])*4,to=(y*width+x)*4;r.data.copy(data,to,from,from+4);
  if(data[to+3]!==255)fail('FLAT_COPY_ALPHA');
  if(x<2||x>=width-2||y<2||y>=height-2)for(let k=0;k<3;k++)channels[k].push(data[to+k]);
 }
 const background=channels.map(v=>v.sort((a,b)=>a-b)[Math.floor(v.length/2)]),mask=new Uint8Array(width*height);let ink=0,unknown=0,boundary=0,edge=0;
 // Destination ink is an editorial choice, not evidence of the original ink.
 // Measure source foreground independently before two-colour alpha matting.
 const samples=Array.from({length:width*height},(_,i)=>Array.from(data.subarray(i*4,i*4+3))).sort((a,b)=>delta(b,background)-delta(a,background));
 const darkest=samples.slice(0,Math.max(4,Math.floor(samples.length*.02))),foreground=[0,1,2].map(k=>darkest.map(p=>p[k]).sort((a,b)=>a-b)[Math.floor(darkest.length/2)]);
 const axis=foreground.map((v,k)=>v-background[k]),denominator=axis.reduce((n,v)=>n+v*v,0),alphas=new Uint8Array(width*height);
 if(delta(background,foreground)<100)fail('FLAT_COPY_LOW_CONTRAST');
 for(let y=0;y<height;y++)for(let x=0;x<width;x++){
  const i=y*width+x,p=Array.from(data.subarray(i*4,i*4+3)),difference=delta(p,background),alpha=p.reduce((n,v,k)=>n+(v-background[k])*axis[k],0)/denominator;
  // Antialiased strokes lie between foreground and background, not just close
  // to solid black/white. A two-colour matting residual rejects coloured art.
  const glyph=difference>20&&alpha>=.08&&alpha<=1.12&&delta(p,background.map((v,k)=>v+Math.min(1,alpha)*axis[k]))<=18;
  if(glyph){mask[i]=255;alphas[i]=Math.round(Math.min(1,alpha)*255);ink++;}else if(difference>24)unknown++;
  if(x<2||x>=width-2||y<2||y>=height-2){edge++;if(difference>18)boundary++;}
 }
 // Weak, boundary-connected shading belongs to the panel, not its lettering.
 // Hysteresis keeps it intact. A component joining a strong glyph to that
 // boundary is clipped/ambiguous and must be rejected, never partly erased.
 const visited=new Uint8Array(mask.length),queue=new Int32Array(mask.length);let backgroundEdgePixelsPreserved=0;
 function preserveBoundary(seed){if(!mask[seed]||visited[seed])return;let head=0,tail=1,maxAlpha=0;queue[0]=seed;visited[seed]=1;
  while(head<tail){const at=queue[head++],x=at%width,y=Math.floor(at/width);maxAlpha=Math.max(maxAlpha,alphas[at]);for(let dy=-1;dy<=1;dy++)for(let dx=-1;dx<=1;dx++){const xx=x+dx,yy=y+dy,n=yy*width+xx;if(xx>=0&&xx<width&&yy>=0&&yy<height&&mask[n]&&!visited[n]){visited[n]=1;queue[tail++]=n;}}}
  if(maxAlpha>=180)fail('FLAT_COPY_EDGE_INK',{key:area.key,edge:[seed%width,Math.floor(seed/width)],maxAlpha});for(let i=0;i<tail;i++)mask[queue[i]]=0;backgroundEdgePixelsPreserved+=tail;
 }
 for(let x=0;x<width;x++){preserveBoundary(x);preserveBoundary((height-1)*width+x);}for(let y=0;y<height;y++){preserveBoundary(y*width);preserveBoundary(y*width+width-1);}
 const metrics={inkRatio:ink/mask.length,unexplainedRatio:unknown/mask.length,boundaryVariation:boundary/edge,backgroundEdgePixelsPreserved};
 // Photographs/texture, an icon within a text box and non-flat edge evidence
 // are rejected. These are independent gates, not relaxation of native-layer
 // alpha consistency, and a rejected group never becomes a delivery.
 if(metrics.inkRatio<.01||metrics.inkRatio>.48||metrics.unexplainedRatio>.025||metrics.boundaryVariation>.08)fail('FLAT_COPY_BACKGROUND_UNSAFE',{key:area.key,metrics});
 return{width,height,data,mask,background,metrics};
}
async function restore({original,areas,fonts,satori,resvg,pixelRatio=2,geometryEvidence,glyphLayout=false}){
 // This mask cannot prove that a monochrome graphic is text. Do not mistake
 // connected-component size heuristics for semantic verification. Only use
 // reviewed test geometry; automatic production fallback is intentionally OFF.
 if(geometryEvidence!=='reviewed_test_fixture')fail('FLAT_COPY_REVIEWED_GEOMETRY_REQUIRED');
 const r=geo.decode(original);if(![1,2].includes(pixelRatio)||r.width*r.height*pixelRatio*pixelRatio>8e6||!Array.isArray(areas)||!areas.length||areas.length>64||new Set(areas.map(a=>a.key)).size!==areas.length||areas.reduce((n,a)=>n+(a.text?.length||0),0)>8000)fail('FLAT_COPY_LIMIT');
 const boxes=areas.map(a=>checkArea(a,r.width,r.height));
 for(let i=0;i<boxes.length;i++)for(const b of boxes.slice(i+1))if(boxes[i][0]<b[2]&&b[0]<boxes[i][2]&&boxes[i][1]<b[3]&&b[1]<boxes[i][3])fail('FLAT_COPY_OVERLAP');
 const outlines=glyphLayout?await require('./native-glyph-layout').prepareAreas({areas,fonts}):null;
 if(outlines)areas=areas.map((area,i)=>{if(outlines[i]?.key!==area.key)fail('FLAT_COPY_CONTRACT');return{...area,fontSize:outlines[i].fontSize};});
 const source={width:r.width,height:r.height,data:Buffer.from(r.data)},patches=[],checks=[],{cv}=await geo.engine();
 // Validate and prepare every operation before touching a deliverable.
 for(const area of areas){
  if(area.fontSize*pixelRatio<22)fail('FLAT_COPY_CAPACITY');
  const q=sampleMask(r,area);let rgba,bgr,mask,dilated,kernel,clean,out;
  try{
   rgba=cv.matFromArray(q.height,q.width,cv.CV_8UC4,q.data);bgr=new cv.Mat();cv.cvtColor(rgba,bgr,cv.COLOR_RGBA2BGR);
   mask=cv.matFromArray(q.height,q.width,cv.CV_8UC1,q.mask);
   dilated=new cv.Mat();kernel=cv.getStructuringElement(cv.MORPH_RECT,new cv.Size(3,3));cv.dilate(mask,dilated,kernel);
   // Do not let dilation run outside the approved area. Adjacent art and icons
   // remain untouched even when their colour resembles the font.
   clean=new cv.Mat();cv.inpaint(bgr,dilated,clean,3,cv.INPAINT_TELEA);out=new cv.Mat();cv.cvtColor(clean,out,cv.COLOR_BGR2RGBA);
   let remaining=0,painted=0;for(let i=0;i<q.mask.length;i++)if(dilated.data[i]){painted++;const p=[out.data[i*4],out.data[i*4+1],out.data[i*4+2]];if(delta(p,q.background)>24)remaining++;}
   if(remaining/Math.max(1,painted)>.01)fail('FLAT_COPY_RESIDUAL_INK',{key:area.key,remainingRatio:remaining/Math.max(1,painted)});
   // Transfer only measured, locally dilated text ink, not a rectangular plate.
   const [x0,y0]=area.box;for(let y=0;y<q.height;y++)for(let x=0;x<q.width;x++)if(dilated.data[y*q.width+x]){const src=(y*q.width+x)*4,dst=((y+y0)*r.width+x+x0)*4;Buffer.from(out.data.buffer,out.data.byteOffset+src,4).copy(source.data,dst);}
   checks.push({key:area.key,...q.metrics,remainingRatio:remaining/Math.max(1,painted)});
  }finally{for(const m of[rgba,bgr,mask,dilated,kernel,clean,out])m?.delete();}
  const width=q.width,height=q.height;let measured=[],svg,outline;
  if(glyphLayout){
   const glyph=require('./native-glyph-layout');outline=outlines.find(p=>p.key===area.key).layout;svg=glyph.svgOf(outline,{width,height,color:area.color});
   checks.at(-1).glyphLayout={copyHash:outline.copyHash,glyphCount:outline.glyphCount,fontSize:outline.fontSize,inkHeight:outline.inkHeight,lines:outline.lines.map(({text,...l})=>l),boxes:outline.boxes};
  }else{
  const tree={type:'div',props:{style:{display:'flex',width,height,fontFamily:'Noto CJK',fontSize:area.fontSize,fontWeight:area.weight,color:area.color},children:{type:'div',props:{'data-copy-key':area.key,style:{display:'flex',width,flexShrink:0,whiteSpace:'pre-wrap',wordBreak:'break-word',lineHeight:area.lineHeight??1.25},children:area.text}}}};
  svg=await satori(tree,{width,height,fonts,embedFont:true,loadAdditionalAsset:async()=>fail('FLAT_COPY_FONT_MISSING'),onStyleError:()=>fail('FLAT_COPY_STYLE_UNSUPPORTED'),onNodeDetected:n=>{if(n.props?.['data-copy-key'])measured.push(n);}});
  if(measured.length!==1||measured.some(n=>!Number.isFinite(n.height)||n.height>height+.5||n.width>width+.5))fail('FLAT_COPY_OVERFLOW',{key:area.key});
  }
  let renderer,frame;try{renderer=new resvg.Resvg(svg,{font:{loadSystemFonts:false},fitTo:{mode:'width',value:width*pixelRatio}});frame=renderer.render();const raw=PNG.sync.read(Buffer.from(frame.asPng()));if(raw.width!==width*pixelRatio||raw.height!==height*pixelRatio)fail('FLAT_COPY_RASTER');patches.push({area,raw});}finally{frame?.free?.();renderer?.free?.();}
 }
 async function resize(a){if(pixelRatio===1)return Buffer.from(a.data);let m,d;try{m=cv.matFromArray(a.height,a.width,cv.CV_8UC4,a.data);d=new cv.Mat();cv.resize(m,d,new cv.Size(a.width*pixelRatio,a.height*pixelRatio),0,0,cv.INTER_CUBIC);return Buffer.from(d.data);}finally{m?.delete();d?.delete();}}
 const control=await resize(r),result=await resize(source),width=r.width*pixelRatio,height=r.height*pixelRatio;
 for(const {area,raw}of patches){const color=area.color.slice(1).match(/../g).map(v=>parseInt(v,16));for(let y=0;y<raw.height;y++)for(let x=0;x<raw.width;x++){
  const i=(y*raw.width+x)*4,alpha=raw.data[i+3]/255;if(!alpha)continue;const target=((area.box[1]*pixelRatio+y)*width+area.box[0]*pixelRatio+x)*4;for(let k=0;k<3;k++)result[target+k]=Math.round(color[k]*alpha+result[target+k]*(1-alpha));
 }}
 // INTER_CUBIC has a two-source-pixel support radius. Audit its actual scaled
 // support rather than incorrectly treating two output pixels as two source
 // pixels. No change beyond that finite support is allowed.
 const support=2*pixelRatio;let outsideChanges=0;for(let y=0;y<height;y++)for(let x=0;x<width;x++){if(boxes.some(b=>x>=b[0]*pixelRatio-support&&x<b[2]*pixelRatio+support&&y>=b[1]*pixelRatio-support&&y<b[3]*pixelRatio+support))continue;const i=(y*width+x)*4;if(!result.subarray(i,i+4).equals(control.subarray(i,i+4)))outsideChanges++;}
 if(outsideChanges)fail('FLAT_COPY_PROTECTION',{metrics:{outsideChanges}});
 return{png:PNG.sync.write({width,height,data:result}),control:PNG.sync.write({width,height,data:control}),manifest:{version:'flat-copy-restoration-experiment-v1',width,height,pixelRatio,areas:areas.map(a=>({...a,textHash:crypto.createHash('sha256').update(a.text).digest('hex'),text:undefined})),checks,outsideChanges,controlBasis:'same_resampling_of_original_not_native_resolution_gain',modelCalls:0,copySource:'confirmed_copy_not_ocr'}};
}
module.exports={sampleMask,restore,proposeNativeAreas};
