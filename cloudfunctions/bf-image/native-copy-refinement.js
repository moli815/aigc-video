"use strict";
// Refine all confirmed visible copy using official rich-text line geometry and a clean
// provider base. No VLM coordinate guess, free-form HTML, global template or OCR
// text as truth. Not enabled on the production generation route.
const crypto=require('node:crypto'),{PNG}=require('pngjs');
const {normalize}=require('./shared/poster-text-audit');
const surface=require('./surface-typography'),{decode}=require('./protected-asset-compositor');
const fail=code=>{throw Object.assign(Error(code),{code});};
function distanceAtMost(a,b,k){
 if(Math.abs(a.length-b.length)>k)return k+1;
 let prev=new Int16Array(b.length+1);prev.fill(k+1);for(let j=0;j<=Math.min(k,b.length);j++)prev[j]=j;
 for(let i=1;i<=a.length;i++){
  const cur=new Int16Array(b.length+1);cur.fill(k+1);if(i<=k)cur[0]=i;let best=k+1;
  for(let j=Math.max(1,i-k);j<=Math.min(b.length,i+k);j++){cur[j]=Math.min(prev[j]+1,cur[j-1]+1,prev[j-1]+(a[i-1]===b[j-1]?0:1));best=Math.min(best,cur[j]);}
  if(best>k)return k+1;prev=cur;
 }
 return prev[b.length];
}
function copyLimit(text){return text.length<4?0:Math.min(3,Math.max(1,Math.floor(text.length*.06)));}
// Word repair may replace a Chinese recognition error, but must not match a
// different step number, amount, model name or structural separator.
function stableTokens(text){return(text.match(/[A-Za-z0-9]+|[^\p{L}\p{N}]/gu)||[]).join('\0');}
// Map each measured native line to a canonical character range. Recognition
// may drop or duplicate a stroke/character; equal-length-only matching cannot
// repair those errors. The unique, bounded whole-field match remains required.
function canonicalLineCounts(canonical,observedLines,limit){
 const observed=observedLines.join(''),w=observed.length+1,n=canonical.length;
 if(!n||n>1000||observed.length>1003||distanceAtMost(canonical,observed,limit)>limit)fail('NATIVE_TEXT_COPY_COVERAGE');
 const dp=new Uint16Array((n+1)*w);
 for(let i=0;i<=n;i++)dp[i*w]=i;for(let j=0;j<w;j++)dp[j]=j;
 for(let i=1;i<=n;i++)for(let j=1;j<w;j++)dp[i*w+j]=Math.min(dp[(i-1)*w+j]+1,dp[i*w+j-1]+1,dp[(i-1)*w+j-1]+(canonical[i-1]===observed[j-1]?0:1));
 const steps=[];let i=n,j=observed.length;
 while(i||j){const v=dp[i*w+j];if(i&&j&&v===dp[(i-1)*w+j-1]+(canonical[i-1]===observed[j-1]?0:1)){steps.push([1,1]);i--;j--;}
  else if(i&&v===dp[(i-1)*w+j]+1){steps.push([1,0]);i--;}else{steps.push([0,1]);j--;}}
 const prefixes=[0];i=0;j=0;for(const [a,b]of steps.reverse()){i+=a;j+=b;prefixes[j]=i;}
 let consumed=0,previous=0;return observedLines.map((line,index)=>{consumed+=line.length;const end=index===observedLines.length-1?n:prefixes[consumed],count=end-previous;previous=end;if(count<1)fail('NATIVE_TEXT_COPY_COVERAGE');return count;});
}
function boxOf(raw,width,height){
 const b=raw?.absolute;
 if(!Array.isArray(b)||b.length!==4||b.some(n=>!Number.isInteger(n))||b[0]<0||b[1]<0||b[2]<=b[0]||b[3]<=b[1]||b[2]>width||b[3]>height)fail('NATIVE_TEXT_GEOMETRY');
 return b;
}
function normalizedBox(b,w,h){return[b[0]/w,b[1]/h,(b[2]-b[0])/w,(b[3]-b[1])/h];}
function complement(surfaces,width,height){
 const xs=[...new Set([0,width,...surfaces.flatMap(b=>[b[0],b[2]])])].sort((a,b)=>a-b),ys=[...new Set([0,height,...surfaces.flatMap(b=>[b[1],b[3]])])].sort((a,b)=>a-b),out=[];
 for(let y=0;y<ys.length-1;y++)for(let x=0;x<xs.length-1;x++){
  const b=[xs[x],ys[y],xs[x+1],ys[y+1]],cx=(b[0]+b[2])/2,cy=(b[1]+b[3])/2;
  if(!surfaces.some(s=>cx>=s[0]&&cx<s[2]&&cy>=s[1]&&cy<s[3]))out.push(normalizedBox(b,width,height));
 }
 return out;
}
// Spatial line grouping as used by document layout extractors (e.g. pdfplumber):
// native line coordinates remain the authority, not a guessed global template.
// A single transparent layer may contain several columns/paragraphs. Match only
// unique contiguous line ranges to confirmed copy; never consume an entire layer.
function candidatesOf(row,target,limit,width,height){
 const raw=row.text_recognition?.lines;
 if(!Number.isInteger(row.index)||row.index<1||!Array.isArray(raw)||!raw.length||raw.length>150)return [];
 const parent=boxOf(row.bounding_box,width,height),entries=raw.map((line,index)=>{
  if(!Array.isArray(line.runs)||!line.runs.length||line.runs.length>32||line.runs.some(s=>typeof s.text!=='string'||s.text.length>1000))fail('NATIVE_TEXT_STYLES');
  const b=boxOf(line.bounding_box,width,height);if(b[0]<parent[0]||b[1]<parent[1]||b[2]>parent[2]||b[3]>parent[3])fail('NATIVE_TEXT_GEOMETRY');
  return {line,index,b,n:normalize(line.runs.map(s=>s.text).join(''))};
 }).sort((a,b)=>a.b[1]-b.b[1]||a.b[0]-b.b[0]);
 const groups=[];
 for(const e of entries){
  const matches=groups.filter(g=>{const p=g.at(-1),h=Math.max(p.b[3]-p.b[1],e.b[3]-e.b[1]);
   return e.b[1]>p.b[1]+h*.4&&e.b[1]-p.b[3]>=-Math.max(3,h*.12)&&e.b[1]-p.b[3]<=h*2&&Math.abs(e.b[0]-p.b[0])<=Math.max(8,width*.005,h*2.2)&&Math.min(e.b[2],p.b[2])-Math.max(e.b[0],p.b[0])>=Math.min(e.b[2]-e.b[0],p.b[2]-p.b[0])*.5;});
  // A nearby large heading remains within the old vertical tolerance for
  // several following body lines. Counting it as a second predecessor split
  // perfectly present paragraphs into fragments. Prefer the uniquely nearest
  // preceding baseline; same-baseline ambiguity still creates a separate group.
  matches.sort((a,b)=>b.at(-1).b[1]-a.at(-1).b[1]);
  if(matches.length&&(!matches[1]||matches[0].at(-1).b[1]>matches[1].at(-1).b[1]))matches[0].push(e);else groups.push([e]);
 }
 const out=[];
 for(const group of groups)for(let start=0;start<group.length;start++){
  let n='';for(let end=start;end<group.length;end++){
   n+=group[end].n;if(n.length>target.length+limit)break;
   if(n.length>=target.length-limit){
    // A missing separator or badge denotes spatial formatting, not a dropped
    // Chinese character. Leave those to the explicit formatting adapter;
    // otherwise a colon-less heading/body pair can erase the intervening art.
    if(stableTokens(n)!==stableTokens(target))continue;
    const d=distanceAtMost(n,target,limit);if(d<=limit){const selected=group.slice(start,end+1);out.push({r:{...row,text_recognition:{lines:selected.map(e=>e.line)}},d,lineIds:selected.map(e=>row.index+':'+e.index)});}}
  }
 }
 return out;
}
function matchFieldsOf({rows,items,width,height,requireFullCopy=false,scopes=[]}){
 if(![width,height].every(n=>Number.isInteger(n)&&n>0&&n<=8192)||width*height>4624220||!Array.isArray(rows)||rows.length>100||!Array.isArray(items)||!items.length||items.length>64||new Set(items.map(i=>i.key)).size!==items.length||items.some(i=>!['title','subtitle','body','label','contact','footer'].includes(i.role)||typeof i.key!=='string'||!i.key||i.key.length>80||typeof i.text!=='string'||i.text.length>1000||normalize(i.text).length<1)||items.reduce((n,i)=>n+i.text.length,0)>8000)fail('NATIVE_TEXT_CONTRACT');
 if(new Set(rows.map(r=>r.index)).size!==rows.length)fail('NATIVE_TEXT_GEOMETRY');
 const knownIds=new Set(rows.flatMap(r=>(r.text_recognition?.lines||[]).map((_,i)=>r.index+':'+i)));
 if(!Array.isArray(scopes)||scopes.length>items.length||new Set(scopes.map(s=>s.key)).size!==scopes.length||scopes.some(s=>!items.some(i=>i.key===s.key)||!Array.isArray(s.lineIds)||!s.lineIds.length||s.lineIds.length>150||new Set(s.lineIds).size!==s.lineIds.length||s.lineIds.some(id=>!knownIds.has(id))))fail('NATIVE_TEXT_SCOPE_INVALID');
 const scopeMap=new Map(scopes.map(s=>[s.key,new Set(s.lineIds)])),used=new Set(),matches=[];
 for(const item of items){
  const scope=scopeMap.get(item.key),target=normalize(item.text),limit=copyLimit(target),candidates=rows.flatMap(r=>candidatesOf(r,target,limit,width,height)).filter(c=>!scope||c.lineIds.every(id=>scope.has(id))).sort((a,b)=>a.d-b.d);
  if(!candidates.length||candidates[1]?.d===candidates[0].d||candidates[0].lineIds.some(id=>used.has(id)))fail('NATIVE_TEXT_AMBIGUOUS_OR_MISSING');
  const {r,d,lineIds}=candidates[0];lineIds.forEach(id=>used.add(id));matches.push({item,r,d,lineIds});
 }
 if(requireFullCopy)for(const row of rows)for(const [index]of(row.text_recognition?.lines||[]).entries())if(!used.has(row.index+':'+index))fail('NATIVE_TEXT_EXTRA_COPY');
 return matches;
}
function planOf({rows,items,width,height,bodyWeight=400,preserveNativeSize=false,labelKeys=[],requireFullCopy=false,scopes=[]}){
 if(![400,700].includes(bodyWeight))fail('NATIVE_TEXT_CONTRACT');
 const assignments=matchFieldsOf({rows,items,width,height,requireFullCopy,scopes}),used=new Set(assignments.flatMap(m=>m.lineIds)),matched=[],blocks=[],lines=[],surfaces=[];
 for(const {item,r,d,lineIds}of assignments){
  const target=normalize(item.text),limit=copyLimit(target);
  const rawLines=r.text_recognition.lines,position=rawLines.map(l=>boxOf(l.bounding_box,width,height)),lineCounts=canonicalLineCounts(target,rawLines.map(l=>normalize(l.runs.map(s=>s.text).join(''))),limit);
  for(let i=1;i<position.length;i++)if(position[i][1]<=position[i-1][1])fail('NATIVE_TEXT_READING_ORDER');
  const parent=boxOf(r.bounding_box,width,height);if(position.some(b=>b[0]<parent[0]||b[1]<parent[1]||b[2]>parent[2]||b[3]>parent[3]))fail('NATIVE_TEXT_GEOMETRY');
  const region=[Math.max(0,Math.min(...position.map(b=>b[0]))-5),Math.max(0,position[0][1]-5),Math.min(width,Math.max(...position.map(b=>b[2]))+5),Math.min(height,position.at(-1)[3]+5)];
  const characters=[...item.text.replace(/\r?\n/g,'')],fontSize=Math.ceil(Math.max(22,Math.min(width,height)*.013,preserveNativeSize?Math.floor(Math.min(...position.map(b=>b[3]-b[1]))*.75):0));let at=0;
  if(position.some(b=>b[3]-b[1]<fontSize*.8))fail('NATIVE_TEXT_CAPACITY');
  for(const [i,l]of rawLines.entries()){
   if(!Array.isArray(l.runs)||!l.runs.length||l.runs.some(s=>typeof s.text!=='string'))fail('NATIVE_TEXT_STYLES');
   let colors=[...new Set(l.runs.map(s=>s.style?.foreground_color))];if(colors.some(c=>!/^#[0-9a-f]{6}$/i.test(c||'')))fail('NATIVE_TEXT_STYLES');
   if(colors.length!==1){
    const rgb=colors.map(c=>c.slice(1).match(/../g).map(h=>parseInt(h,16))),neutral=rgb.every(c=>Math.max(...c)-Math.min(...c)<=12),light=rgb.every(c=>Math.min(...c)>=180),dark=rgb.every(c=>Math.max(...c)<=80);
    // Approximate neutral shading is not an intentional multicolour highlight.
    // Only the optional native-size adapter normalises it to the clearer ink.
    if(!preserveNativeSize||!neutral||!light&&!dark)fail('NATIVE_TEXT_STYLES');
    colors=[colors[rgb.map(c=>c.reduce((n,x)=>n+x,0)).indexOf((light?Math.max:Math.min)(...rgb.map(c=>c.reduce((n,x)=>n+x,0))))]];
   }
   const count=lineCounts[i],start=at;let taken=0;
   while(at<characters.length&&taken<count)taken+=[...normalize(characters[at++])].length;
   while(at<characters.length&&!normalize(characters[at]))at++;
   const text=characters.slice(start,at).join('');if(taken!==count)fail('NATIVE_TEXT_COPY_COVERAGE');
   const b=position[i],top=b[1]-2,h=Math.ceil(fontSize*1.2)+1;
   if(top<region[1]||top+h>region[3]||i<position.length-1&&top+h>position[i+1][1]-2)fail('NATIVE_TEXT_CAPACITY');
   const measuredBold=preserveNativeSize&&l.runs.every(s=>s.style?.bold===true);
   const key=item.key+':line'+i;lines.push({key,role:item.role,text});blocks.push({key,box:normalizedBox([region[0]+2,top,region[2]-2,top+h],width,height),fontSize,nativeInkHeight:b[3]-b[1],weight:measuredBold||labelKeys.includes(item.key)||['title','subtitle','label'].includes(item.role)?700:bodyWeight,color:colors[0],align:'left',lineHeight:1.2,letterSpacing:0});
  }
  if(at!==characters.length)fail('NATIVE_TEXT_COPY_COVERAGE');
  surfaces.push(region);matched.push({key:item.key,layer:r.index,lineIds,ocrSubstitutions:d,canonicalSource:'confirmed_input_not_ocr'});
 }
 for(const row of rows)for(const [index,line]of(row.text_recognition?.lines||[]).entries())if(!used.has(row.index+':'+index)){
  if(requireFullCopy===true)fail('NATIVE_TEXT_EXTRA_COPY');
  const b=boxOf(line.bounding_box,width,height);if(surfaces.some(s=>s[0]<b[2]&&b[0]<s[2]&&s[1]<b[3]&&b[1]<s[3]))fail('NATIVE_TEXT_UNSELECTED_OVERLAP');
 }
 // Adjacent OCR lines may have overlapping padding. Both approved erasures
 // copy the identical clean base. Actual glyph blocks must still be disjoint
 // (surface.validate), and all unselected text above remains protected.
 const plan={surfaces:surfaces.map(b=>({box:normalizedBox(b,width,height),color:'#FFFFFF'})),blocks,protected:complement(surfaces,width,height)};
 surface.validate(plan,lines,width,height);
 return{plan,lines,matched,surfaces};
}
// Only reasonably flat text surfaces are accepted. Background and foreground
// colours are measured independently, so white-on-dark copy follows the same
// checks as dark-on-light. Photographs/texture/low-contrast copy fail closed.
function auditRegion(a,base,b,colors){
 const rgb=colors.map(c=>c.slice(1).match(/../g).map(h=>parseInt(h,16))),edge=[[],[],[]];
 for(let y=b[1];y<b[3];y++)for(let x=b[0];x<b[2];x++)if(x===b[0]||x===b[2]-1||y===b[1]||y===b[3]-1){const i=(y*a.width+x)*4;for(let k=0;k<3;k++)edge[k].push(base.data[i+k]);}
 const bg=edge.map(v=>v.sort((x,y)=>x-y)[Math.floor(v.length/2)]),delta=(p,q)=>Math.max(...p.map((v,k)=>Math.abs(v-q[k])));
 if(rgb.some(c=>delta(c,bg)<85))fail('NATIVE_TEXT_LOW_CONTRAST');
 let oldInk=0,newInk=0,count=0,edgeError=0,edgeCount=0,nonFlat=0;
 const ink=p=>rgb.some(c=>delta(p,c)<65&&delta(p,bg)>45);
 for(let y=b[1];y<b[3];y++)for(let x=b[0];x<b[2];x++){
  const i=(y*a.width+x)*4,old=[...a.data.subarray(i,i+3)],clean=[...base.data.subarray(i,i+3)];count++;
  if(a.data[i+3]!==255||base.data[i+3]!==255)fail('NATIVE_TEXT_BASE_NOT_CLEAN_OR_ALIGNED');
  if(ink(old))oldInk++;if(ink(clean))newInk++;if(delta(clean,bg)>32)nonFlat++;
  if(x===b[0]||x===b[2]-1||y===b[1]||y===b[3]-1){for(let k=0;k<3;k++)edgeError+=Math.abs(old[k]-clean[k]);edgeCount+=3;}
 }
 const metrics={oldInkRatio:oldInk/count,remainingInkRatio:newInk/count,nonFlatRatio:nonFlat/count,boundaryMeanDelta:edgeError/edgeCount};
 if(oldInk/count<.008||newInk/count>.008||nonFlat/count>.035||edgeError/edgeCount>25)throw Object.assign(Error('NATIVE_TEXT_BASE_NOT_CLEAN_OR_ALIGNED'),{code:'NATIVE_TEXT_BASE_NOT_CLEAN_OR_ALIGNED',metrics});
 return metrics;
}
async function inkMaskOf(textLayers,rows,width,height){
 const {cv}=await require('./protected-asset-compositor').engine(),alpha=new Uint8Array(width*height);
 for(const layer of textLayers){const r=decode(layer.bytes),parent=boxOf(rows.find(row=>row.index===layer.index)?.bounding_box,width,height);let source,resized;
  try{const bytes=new Uint8Array(r.width*r.height);for(let n=0;n<bytes.length;n++)bytes[n]=r.data[n*4+3];source=cv.matFromArray(r.height,r.width,cv.CV_8UC1,bytes);resized=new cv.Mat();cv.resize(source,resized,new cv.Size(parent[2]-parent[0],parent[3]-parent[1]),0,0,cv.INTER_AREA);
   for(let y=parent[1];y<parent[3];y++)for(let x=parent[0];x<parent[2];x++){const at=y*width+x;alpha[at]=Math.max(alpha[at],resized.data[(y-parent[1])*(parent[2]-parent[0])+x-parent[0]]);}
  }finally{source?.delete();resized?.delete();}
 }
 let source,dilated,kernel;try{source=cv.matFromArray(height,width,cv.CV_8UC1,alpha);dilated=new cv.Mat();kernel=cv.getStructuringElement(cv.MORPH_RECT,new cv.Size(5,5));cv.dilate(source,dilated,kernel);return{core:alpha,erase:Uint8Array.from(dilated.data)};}finally{source?.delete();dilated?.delete();kernel?.delete();}
}
function auditMaskedRegion(a,base,b,mask){
 let outside=0,outsideChanged=0,core=0,coreChanged=0;
 for(let y=b[1];y<b[3];y++)for(let x=b[0];x<b[2];x++){
  const at=y*a.width+x,i=at*4,d=Math.max(...[0,1,2].map(k=>Math.abs(a.data[i+k]-base.data[i+k])));
  if(a.data[i+3]!==255||base.data[i+3]!==255)fail('NATIVE_TEXT_BASE_NOT_CLEAN_OR_ALIGNED');
  if(mask.erase[at]<=4){outside++;if(d>25)outsideChanged++;}
  if(mask.core[at]>=200){core++;if(d>35)coreChanged++;}
 }
 const metrics={mode:'native_alpha_mask',outsideInkChangedRatio:outsideChanged/Math.max(1,outside),coreInkRemovedRatio:coreChanged/Math.max(1,core),corePixels:core};
 if(core<12||coreChanged/core<.9||outsideChanged/Math.max(1,outside)>.03)throw Object.assign(Error('NATIVE_TEXT_BASE_NOT_CLEAN_OR_ALIGNED'),{code:'NATIVE_TEXT_BASE_NOT_CLEAN_OR_ALIGNED',metrics});
 return metrics;
}
function eraseAudit(a,base,b,colours,mask){
 if(!mask)return{check:auditRegion(a,base,b,colours),rect:true};
 try{return{check:auditMaskedRegion(a,base,b,mask),rect:false};}
 catch(e){
  if(e.metrics?.corePixels!==0)throw e;
  return{check:{...auditRegion(a,base,b,colours),mode:'missing_native_alpha_independent_flat_audit'},rect:true};
 }
}
async function refine({original,cleanBase,rows,items,fonts,satori,resvg,bodyWeight=400,textLayers,preserveNativeSize=false,labelKeys=[],requireFullCopy=false,scopes=[],nativeGlyphs=false}){
 const a=decode(original),base=decode(cleanBase);if(a.width!==base.width||a.height!==base.height)fail('NATIVE_TEXT_CANVAS');
 if(textLayers!==undefined){
  if(!Array.isArray(textLayers)||!textLayers.length||textLayers.length>8)fail('NATIVE_TEXT_ALPHA_CANVAS');
  for(const layer of textLayers){const coverage=await require('./native-text-coverage').audit({bytes:layer.bytes,rows:rows.filter(r=>r.index===layer.index),width:a.width,height:a.height});if(!coverage.complete)fail('NATIVE_TEXT_RECOGNITION_INCOMPLETE');}
 }
 const p=planOf({rows,items,width:a.width,height:a.height,bodyWeight,preserveNativeSize,labelKeys,requireFullCopy,scopes}),plate={width:a.width,height:a.height,data:Buffer.from(a.data)},checks=[],mask=textLayers?await inkMaskOf(textLayers,rows,a.width,a.height):null;
 for(const [regionIndex,b]of p.surfaces.entries()){
  const colours=[...new Set(p.plan.blocks.filter(t=>{const x=t.box[0]*a.width,y=t.box[1]*a.height;return x>=b[0]&&x<b[2]&&y>=b[1]&&y<b[3];}).map(t=>t.color))];
  let rectangularErase=false;
  try{
   // Missing native alpha is handled only by the independently strict flat
   // audit, never by weakening photo/gradient, contrast or residual checks.
   const decision=eraseAudit(a,base,b,colours,mask);checks.push(decision.check);rectangularErase=decision.rect;
  }catch(e){e.regionKey=p.matched[regionIndex].key;throw e;}
  for(let y=b[1];y<b[3];y++)for(let x=b[0];x<b[2];x++)if(rectangularErase||mask.erase[y*a.width+x]>4){const i=(y*a.width+x)*4;base.data.copy(plate.data,i,i,i+4);}
 }
 const result=await surface.render({canvas:PNG.sync.write(plate),items:p.lines,plan:p.plan,fonts,satori,resvg,decomposedBackground:true,nativeGlyphs});
 const rendered=decode(result.png),allowed=new Uint8Array(a.width*a.height);let outsideChanges=0;
 for(const b of p.surfaces)for(let y=b[1];y<b[3];y++)allowed.fill(1,y*a.width+b[0],y*a.width+b[2]);
 for(let n=0;n<allowed.length;n++)if(!allowed[n]){const i=n*4;if(!a.data.subarray(i,i+4).equals(rendered.data.subarray(i,i+4)))outsideChanges++;}
 if(outsideChanges)fail('NATIVE_TEXT_PROTECTION');
 return{...result,manifest:{...result.manifest,version:'native-copy-refinement-candidate-v2',matched:p.matched,cleanBaseChecks:checks,outsideChanges,nativeGlyphs,geometrySource:'official_rich_text_lines',copyHash:crypto.createHash('sha256').update(JSON.stringify(items.map(t=>[t.key,t.text]))).digest('hex')}};
}
module.exports={planOf,refine,matchFieldsOf,distanceAtMost,canonicalLineCounts,auditRegion,auditMaskedRegion,eraseAudit,hasCandidate:({rows,text,width,height})=>rows.some(row=>candidatesOf(row,normalize(text),copyLimit(normalize(text)),width,height).length>0)};
