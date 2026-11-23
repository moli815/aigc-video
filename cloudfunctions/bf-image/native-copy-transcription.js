"use strict";
const {decode}=require('./protected-asset-compositor'),{hasCandidate}=require('./native-copy-refinement');
const fail=code=>{throw Object.assign(Error(code),{code});};
// The supplementary model may name only measured components. It cannot supply
// coordinates, expected words, new fields or arbitrary drawing instructions.
function supplement({rows,regions,transcription,layerBytes,index,width,height}){
 if(!Array.isArray(regions)||regions.length>128||new Set(regions.map(r=>r.id)).size!==regions.length||regions.some(r=>!/^r\d+$/.test(r.id||''))||!Array.isArray(transcription?.regions)||transcription.regions.length!==regions.length)fail('NATIVE_TEXT_SUPPLEMENT_INVALID');
 const row=rows.find(r=>r.index===index),layer=decode(layerBytes);if(!row||layer.width!==width||layer.height!==height)fail('NATIVE_TEXT_ALPHA_CANVAS');
 const texts=new Map();for(const t of transcription.regions){if(Object.keys(t).some(k=>!['id','text'].includes(k))||typeof t.id!=='string'||texts.has(t.id)||typeof t.text!=='string'||!t.text.trim()||t.text.length>120)fail('NATIVE_TEXT_SUPPLEMENT_INVALID');texts.set(t.id,t.text);}
 const additions=regions.map(r=>{
  if(!texts.has(r.id)||!Array.isArray(r.box)||r.box.length!==4||r.box.some(n=>!Number.isInteger(n))||r.box[0]<0||r.box[1]<0||r.box[2]>width||r.box[3]>height||r.box[2]<=r.box[0]||r.box[3]<=r.box[1])fail('NATIVE_TEXT_SUPPLEMENT_INVALID');
  const channels=[[],[],[]];for(let y=r.box[1];y<r.box[3];y++)for(let x=r.box[0];x<r.box[2];x++){const i=(y*width+x)*4;if(layer.data[i+3]>200)for(let k=0;k<3;k++)channels[k].push(layer.data[i+k]);}
  if(channels[0].length<12)fail('NATIVE_TEXT_SUPPLEMENT_EMPTY');const color='#'+channels.map(v=>v.sort((a,b)=>a-b)[Math.floor(v.length/2)].toString(16).padStart(2,'0')).join('');
  return{b:[...r.box],text:texts.get(r.id),color};
 }).sort((a,b)=>a.b[1]-b.b[1]||a.b[0]-b.b[0]);
 // Rejoin only components on the same baseline with a small measured gap.
 const nearColor=(a,b)=>[1,3,5].every(k=>Math.abs(parseInt(a.slice(k,k+2),16)-parseInt(b.slice(k,k+2),16))<=8);
 const merged=[];for(const a of additions){const matches=merged.filter(p=>Math.abs(p.b[1]-a.b[1])<Math.min(p.b[3]-p.b[1],a.b[3]-a.b[1])*.25&&a.b[0]>=p.b[2]&&a.b[0]-p.b[2]<=Math.max(p.b[3]-p.b[1],a.b[3]-a.b[1])*.8&&nearColor(p.color,a.color));
  if(matches.length===1){const p=matches[0];p.text+=a.text;p.b=[p.b[0],Math.min(p.b[1],a.b[1]),a.b[2],Math.max(p.b[3],a.b[3])];}else merged.push(a);
 }
 return rows.map(r=>r.index!==index?r:{...r,text_recognition:{...r.text_recognition,lines:[...(r.text_recognition?.lines||[]),...merged.map(m=>({bounding_box:{absolute:m.b},runs:[{text:m.text,style:{foreground_color:m.color,bold:false}}]}))]}});
}
// Formatting is explicit in the report: ':' and list bullets may become a
// line break/separate labels; numeric badges remain native and require visual
// verification. Never rewrite factual wording or silently drop a body field.
function targets({items,rows,width,height,allowFormatting=false,allowNativeBadges=false}){
 const out=[],formats=[],labelKeys=[],scopes=[];
 for(const item of items){
  // A single canonical list field may be displayed in separate columns. Only
  // split explicitly numbered source lines, preserve every prefix and exact
  // word, and require EACH complete entry to match real measured lines.
  // This never licenses missing native badges or invents a space for a step.
  const numberedLines=item.text.split(/\r?\n/).filter(t=>t.trim());
  const sequence=numberedLines.map(t=>/^\s*(\d{1,2})[.．、]\s*\S/.exec(t));
  if(allowFormatting&&numberedLines.length>=2&&numberedLines.length<=16&&sequence.every((m,i)=>m&&Number(m[1])===i+1)){
   if(numberedLines.some(text=>!hasCandidate({rows,text,width,height})))fail('NATIVE_TEXT_AMBIGUOUS_OR_MISSING');
   numberedLines.forEach((text,i)=>out.push({...item,key:item.key+':entry'+i,text}));
   formats.push({key:item.key,separator:'numbered_lines_as_spatial_entries',entries:numberedLines.length,prefixesPreserved:true});continue;
  }
  const named=item.text.match(/^([^：:]{2,12})[：:]([\s\S]+)$/),numbered=item.text.match(/^(\d{2})\s+([\s\S]+)$/);
  const contact=item.role==='contact'&&item.text.match(/^([^\d\r\n]{2,16}?)\s+(\+?[\d][\d -]{6,31})$/);
  const marked=named?named[1]+item.text[named[1].length]:null;
  const separateHeading=allowFormatting&&named&&hasCandidate({rows,text:named[2],width,height})&&
   (hasCandidate({rows,text:marked,width,height})||hasCandidate({rows,text:named[1],width,height}));
  if(hasCandidate({rows,text:item.text,width,height})&&!separateHeading){out.push({...item});continue;}
  if(!allowFormatting)fail('NATIVE_TEXT_FORMAT_APPROVAL_REQUIRED');
  let fragments;
  if(named){
   // Preserve a printed colon when the native heading actually contains it.
   // Splitting at ':' must not make a perfectly matching heading unavailable.
   fragments=[hasCandidate({rows,text:marked,width,height})?marked:named[1],named[2]];
   formats.push({key:item.key,separator:fragments[0]===marked?'colon_preserved_before_line_break':'colon_as_line_break'});labelKeys.push(item.key+':part0');
  }
  else if(numbered){if(!allowNativeBadges)fail('NATIVE_TEXT_BADGE_VERIFICATION_REQUIRED');fragments=[numbered[2]];formats.push({key:item.key,separator:'native_number_badge',preservedPrefix:numbered[1],requiresOriginalVisualAcceptance:true});}
  else if(contact){fragments=[contact[1],contact[2]];formats.push({key:item.key,separator:'contact_space_as_line_break',digitsPreserved:true});labelKeys.push(item.key+':part0');}
  else if(/\s*[·•]\s*/.test(item.text)){fragments=item.text.split(/\s*[·•]\s*/);formats.push({key:item.key,separator:'bullets_as_spatial_labels'});}
  else fail('NATIVE_TEXT_AMBIGUOUS_OR_MISSING');
  if(fragments.some(t=>!t||!hasCandidate({rows,text:t,width,height})))fail('NATIVE_TEXT_AMBIGUOUS_OR_MISSING');
  // A complete uniquely matched paragraph supplies context for its own
  // heading/body fragments. The same short heading may also appear in a
  // diagram elsewhere; splitting must not lose that already-proven context.
  let parentScope;try{parentScope=require('./native-copy-refinement').matchFieldsOf({rows,items:[item],width,height})[0].lineIds;}catch{}
  fragments.forEach((text,i)=>{const key=item.key+':part'+i;out.push({...item,key,text});if(parentScope)scopes.push({key,lineIds:[...parentScope]});});
 }
 if(out.length>64)fail('NATIVE_TEXT_CONTRACT');return{items:out,formats,labelKeys,scopes};
}
module.exports={supplement,targets};
