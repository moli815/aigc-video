"use strict";
// Existing, lockfile-pinned Satori dependencies: OpenType outlines and UAX #14.
// Offline candidate: no invented words, font fallback, ellipsis or auto-shrink.
const path=require('node:path'),crypto=require('node:crypto');
const dependency=name=>require(require.resolve(name,{paths:[path.dirname(require.resolve('satori'))]}));
const cache=new WeakMap(),fail=code=>{throw Object.assign(Error(code),{code});};
function fontOf(data){
 if(!Buffer.isBuffer(data)||data.length>20*1024*1024)fail('GLYPH_FONT_INVALID');
 if(!cache.has(data))cache.set(data,dependency('@shuding/opentype.js').parse(data.buffer.slice(data.byteOffset,data.byteOffset+data.byteLength)));
 return cache.get(data);
}
function metrics(text,font){
 let top=-Infinity,bottom=Infinity;
 for(const c of text){if(/\s/u.test(c))continue;const g=font.charToGlyph(c);if(!g?.index)fail('GLYPH_MISSING');const m=g.getMetrics();
  if(![m.xMin,m.xMax,m.yMin,m.yMax].every(Number.isFinite))fail('GLYPH_FONT_INVALID');top=Math.max(top,m.yMax);bottom=Math.min(bottom,m.yMin);
 }
 if(!Number.isFinite(top)||!Number.isFinite(bottom))fail('GLYPH_EMPTY');return{top,bottom,inkEm:(top-bottom)/font.unitsPerEm};
}
function measure({text,width,height,fontSize,fontData,lineHeight=1.25,align='left'}){
 if(typeof text!=='string'||!text.trim()||text.length>1000||![width,height,fontSize,lineHeight].every(Number.isFinite)||width<12||height<12||fontSize<11||fontSize>160||lineHeight<1.05||lineHeight>1.8||!['left','center','right'].includes(align))fail('GLYPH_LAYOUT_INVALID');
 // This outlined renderer handles the project's Chinese/Latin copy. Reject
 // scripts requiring an unavailable shaping engine instead of mis-shaping them.
 if(/[\p{Script=Arabic}\p{Script=Hebrew}\p{Mark}\p{Extended_Pictographic}]/u.test(text))fail('GLYPH_SHAPING_UNSUPPORTED');
 const font=fontOf(fontData),m=metrics(text,font),scale=fontSize/font.unitsPerEm,lineAdvance=fontSize*lineHeight;
 const Breaker=dependency('linebreak'),lines=[];let offset=0;
 for(const paragraph of text.match(/[^\r\n]*(?:\r\n|\n|\r|$)/g).filter(Boolean)){
  const content=paragraph.replace(/[\r\n]+$/,''),newline=paragraph.slice(content.length),breaks=[],breaker=new Breaker(content);let br;
  while((br=breaker.nextBreak()))breaks.push(br.position);
  let at=0;
  if(!content.length)lines.push({text:newline,draw:'',start:offset,end:offset+newline.length,advance:0});
  while(at<content.length){
   let end=null,advance=0;
   for(const pos of breaks){if(pos<=at)continue;const w=font.getAdvanceWidth(content.slice(at,pos),fontSize,{kerning:true});if(w>width+.01)break;end=pos;advance=w;}
   if(end===null)fail('GLYPH_WIDTH_OVERFLOW');
   const tail=end===content.length?newline:'',draw=content.slice(at,end);
   lines.push({text:draw+tail,draw,start:offset+at,end:offset+end+tail.length,advance});at=end;
  }
  offset+=paragraph.length;
 }
 if(lines.map(l=>l.text).join('')!==text)fail('GLYPH_COPY_LOSS');
 const inkHeight=m.inkEm*fontSize+(lines.length-1)*lineAdvance;
 if(inkHeight>height+.01)fail('GLYPH_HEIGHT_OVERFLOW');
 const boxes=[],paths=[];
 for(const [i,line]of lines.entries()){
  const x=align==='left'?0:align==='right'?width-line.advance:(width-line.advance)/2,baseline=m.top*scale+i*lineAdvance;
  let left=Infinity,right=-Infinity,top=Infinity,bottom=-Infinity;
  font.forEachGlyph(line.draw,x,baseline,fontSize,{kerning:true},(g,gx,gy,size)=>{if(!g.path?.commands?.length)return;const b=g.getMetrics(),s=size/font.unitsPerEm;left=Math.min(left,gx+b.xMin*s);right=Math.max(right,gx+b.xMax*s);top=Math.min(top,gy-b.yMax*s);bottom=Math.max(bottom,gy-b.yMin*s);});
  if(Number.isFinite(left)){
   if(left<-.01||top<-.01||right>width+.01||bottom>height+.01)fail('GLYPH_OUTLINE_CLIPPED');
   boxes.push({start:line.start,end:line.end,box:[left,top,right,bottom]});paths.push(font.getPath(line.draw,x,baseline,fontSize,{kerning:true}).toPathData(3));
  }
 }
 return{paths,lines:lines.map(({draw,...l})=>l),boxes,inkHeight,fontSize,lineHeight,copyHash:crypto.createHash('sha256').update(text).digest('hex'),glyphCount:[...text].filter(c=>!(/\s/u.test(c))).length};
}
function inferFontSize({text,inkHeight,fontData}){
 if(!Number.isFinite(inkHeight)||inkHeight<=0)fail('GLYPH_LAYOUT_INVALID');return inkHeight/metrics(text,fontOf(fontData)).inkEm;
}
function svgOf(layout,{width,height,color}){
 if(!/^#[a-f0-9]{6}$/i.test(color||''))fail('GLYPH_COLOR_INVALID');
 return `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}"><g fill="${color}">${layout.paths.map(d=>`<path d="${d}"/>`).join('')}</g></svg>`;
}
// Font parsers own large CJK glyph tables. Finish and exit a bounded worker
// BEFORE OpenCV inpainting starts; keeping both engines' heaps alive caused
// the 1024MB function candidate to approach its memory ceiling.
async function prepareAreas({areas,fonts,timeoutMs=12000}){
 if(!Array.isArray(areas)||!areas.length||areas.length>160||!Array.isArray(fonts)||fonts.length!==2||fonts.some(f=>![400,700].includes(f.weight)||!Buffer.isBuffer(f.data)||f.data.length>20*1024*1024)||new Set(fonts.map(f=>f.weight)).size!==2||areas.reduce((n,a)=>n+(a.text?.length||0),0)>8000||!Number.isInteger(timeoutMs)||timeoutMs<1||timeoutMs>20000)fail('GLYPH_WORKER_INPUT');
 const {Worker}=require('node:worker_threads'),deadline=Date.now()+timeoutMs;
 async function batch(group,font){return new Promise((resolve,reject)=>{
  let message,workerError,timedOut=false;const worker=new Worker(__filename,{workerData:{kind:'bossai-glyph-layout-v1',areas:group,fonts:[{weight:font.weight,data:font.data}]},resourceLimits:{maxOldGenerationSizeMb:320,stackSizeMb:4}});
  const timer=setTimeout(()=>{timedOut=true;void worker.terminate();},Math.max(1,deadline-Date.now()));
  worker.on('message',m=>{message=m;});worker.on('error',e=>{workerError=e.code||'GLYPH_WORKER_FAILED';});
  worker.once('exit',code=>{clearTimeout(timer);if(timedOut||workerError||code!==0||!message?.ok)return reject(Object.assign(Error(message?.code||'GLYPH_WORKER_LIMIT'),{code:message?.code||'GLYPH_WORKER_LIMIT',workerCode:workerError,key:message?.key}));resolve(message.results);});
 });}
 const byKey=new Map();for(const font of fonts){const group=areas.filter(a=>a.weight===font.weight);if(group.length)for(const r of await batch(group,font))byKey.set(r.key,r);}
 if(byKey.size!==areas.length||areas.some(a=>!byKey.has(a.key)))fail('GLYPH_WORKER_INPUT');return areas.map(a=>byKey.get(a.key));
}
const {isMainThread,parentPort,workerData}=require('node:worker_threads');
if(!isMainThread&&workerData?.kind==='bossai-glyph-layout-v1'){
 let key;try{
  const fonts=workerData.fonts.map(f=>({...f,data:Buffer.from(f.data)})),results=[];
  for(const area of workerData.areas){
   key=area.key;const font=fonts.find(f=>f.weight===area.weight);if(!font)fail('GLYPH_FONT_INVALID');
   const width=area.box[2]-area.box[0],height=area.box[3]-area.box[1],inferred=area.fitNativeFont===true?inferFontSize({text:area.text,inkHeight:area.observedInkHeight,fontData:font.data}):area.fontSize,maximum=Math.max(area.fontSize,inferred);let result;
   // Only enlarge toward the measured native ink height. The input minimum
   // remains the minimum; overflowing copy never becomes smaller or shorter.
   for(let size=maximum;size>=area.fontSize-.001;size-=.125){try{const fontSize=Math.max(area.fontSize,size),layout=measure({text:area.text,width,height,fontSize,fontData:font.data,lineHeight:area.lineHeight??1.25});result={key,layout,fontSize,inferred};break;}catch(e){if(!/GLYPH_(HEIGHT|WIDTH)_OVERFLOW/.test(e.code||''))throw e;}}
   if(!result)result={key,fontSize:area.fontSize,inferred,layout:measure({text:area.text,width,height,fontSize:area.fontSize,fontData:font.data,lineHeight:area.lineHeight??1.25})};results.push(result);
  }
  parentPort.postMessage({ok:true,results});
 }catch(e){parentPort.postMessage({ok:false,code:e.code||'GLYPH_WORKER_FAILED',key});}
 parentPort.close();
}
module.exports={measure,inferFontSize,svgOf,prepareAreas};
