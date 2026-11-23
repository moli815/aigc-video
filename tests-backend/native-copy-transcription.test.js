"use strict";
const test=require('node:test'),assert=require('node:assert/strict'),{PNG}=require('../cloudfunctions/bf-image/node_modules/pngjs'),{supplement,targets}=require('../cloudfunctions/bf-image/native-copy-transcription'),{auditMaskedRegion}=require('../cloudfunctions/bf-image/native-copy-refinement');
function fixture(){const data=Buffer.alloc(200*200*4);for(let y=10;y<40;y++)for(let x=10;x<100;x++){let i=(y*200+x)*4;data[i]=data[i+1]=data[i+2]=255;data[i+3]=255;}return{rows:[{index:1,bounding_box:{absolute:[0,0,200,200]},text_recognition:{lines:[]}}],index:1,width:200,height:200,layerBytes:PNG.sync.write({width:200,height:200,data}),regions:[{id:'r0',box:[10,10,50,40]},{id:'r1',box:[55,10,100,40]}],transcription:{regions:[{id:'r0',text:'实际'},{id:'r1',text:'文字'}]}};}
test('supplement joins measured same-baseline components, never accepts model geometry or missing IDs',()=>{
 const f=fixture(),r=supplement(f);assert.equal(r[0].text_recognition.lines[0].runs[0].text,'实际文字');assert.deepEqual(r[0].text_recognition.lines[0].bounding_box.absolute,[10,10,100,40]);
 assert.equal(f.rows[0].text_recognition.lines.length,0);
 for(const transcription of[{regions:[{id:'r0',text:'实际'}]},{regions:[{id:'r0',text:'实际',box:[0,0,200,200]},{id:'r1',text:'文字'}]},{regions:[{id:'r0',text:null},{id:'r1',text:'文字'}]},{regions:[{id:'r0',text:'实际'},{id:'r0',text:'文字'}]}])assert.throws(()=>supplement({...f,transcription}),/SUPPLEMENT_INVALID/);
});
function row(text,y){return{runs:[{text,style:{foreground_color:'#FFFFFF'}}],bounding_box:{absolute:[20,y,380,y+35]}};}

test('explicit numbered source entries may occupy different columns without dropping prefixes or words',()=>{
 const first='1. 交流现场场景',second='2. 整理设备清单',items=[{key:'steps',role:'body',text:first+'\n'+second}],a=row(first,30),b=row(second,30);a.bounding_box.absolute=[20,30,180,65];b.bounding_box.absolute=[220,30,390,65];
 const rows=[{index:1,bounding_box:{absolute:[0,0,400,500]},text_recognition:{lines:[a,b]}}],p=targets({items,rows,width:400,height:500,allowFormatting:true,allowNativeBadges:false});
 assert.deepEqual(p.items.map(i=>i.text),[first,second]);assert.equal(p.formats[0].prefixesPreserved,true);
 assert.throws(()=>targets({items,rows:rows.map(r=>({...r,text_recognition:{lines:[a]}})),width:400,height:500,allowFormatting:true}),/AMBIGUOUS_OR_MISSING/);
 assert.throws(()=>targets({items,rows,width:400,height:500}),/FORMAT_APPROVAL/);
 // A wrong or omitted number must not be accepted merely because the words match.
 const wrong=JSON.parse(JSON.stringify(rows));wrong[0].text_recognition.lines[1].runs[0].text='3. 整理设备清单';
 assert.throws(()=>targets({items,rows:wrong,width:400,height:500,allowFormatting:true}),/AMBIGUOUS_OR_MISSING/);
});
test('a printed heading colon survives paragraph splitting rather than making its canonical field unavailable',()=>{
 const rows=[{index:1,bounding_box:{absolute:[0,0,400,500]},text_recognition:{lines:[row('平台接入：',30),row('把终端接入统一平台',80)]}}];
 const p=targets({rows,width:400,height:500,allowFormatting:true,items:[{key:'b',role:'body',text:'平台接入：把终端接入统一平台'}]});
 assert.deepEqual(p.items.map(t=>t.text),['平台接入：','把终端接入统一平台']);assert.equal(p.formats[0].separator,'colon_preserved_before_line_break');assert.equal(p.items.map(i=>i.text).join(''),'平台接入：把终端接入统一平台');
});
test('splitting a unique paragraph retains its context when the same heading appears elsewhere',()=>{
 const rows=[{index:1,bounding_box:{absolute:[0,0,400,600]},text_recognition:{lines:[row('平台接入：',30),row('把终端接入统一平台',80),row('按项目保留设备资料',130),row('平台接入：',450)]}}],items=[{key:'b',role:'body',text:'平台接入：把终端接入统一平台按项目保留设备资料'}];
 const p=targets({rows,items,width:400,height:600,allowFormatting:true}),mod=require('../cloudfunctions/bf-image/native-copy-refinement');
 assert.equal(p.items.length,2);assert.throws(()=>mod.matchFieldsOf({rows,items:p.items,width:400,height:600}),/AMBIGUOUS/);
 const matches=mod.matchFieldsOf({rows,items:p.items,width:400,height:600,scopes:p.scopes});assert.deepEqual(matches[0].lineIds,['1:0']);assert.ok(matches.every(m=>!m.lineIds.includes('1:3')));
 assert.throws(()=>mod.matchFieldsOf({rows,items:p.items,width:400,height:600,scopes:[{key:p.items[0].key,lineIds:['9:99']}]}),/SCOPE_INVALID/);
});
test('wording remains canonical, separator formatting and untouched native badges require explicit host validation',()=>{
 const rows=[{index:1,bounding_box:{absolute:[0,0,400,500]},text_recognition:{lines:[row('平台接入',30),row('把终端接入统一平台',80),row('了解现场场景',190)]}}],base={rows,width:400,height:500};
 assert.throws(()=>targets({...base,items:[{key:'b',role:'body',text:'平台接入：把终端接入统一平台'}]}),/FORMAT_APPROVAL/);
 const p=targets({...base,allowFormatting:true,items:[{key:'b',role:'body',text:'平台接入：把终端接入统一平台'}]});assert.deepEqual(p.items.map(t=>t.text),['平台接入','把终端接入统一平台']);assert.equal(p.formats[0].separator,'colon_as_line_break');
 const numbered={...base,allowFormatting:true,items:[{key:'n',role:'body',text:'01 了解现场场景'}]};assert.throws(()=>targets(numbered),/BADGE_VERIFICATION/);
 assert.equal(targets({...numbered,allowNativeBadges:true}).formats[0].preservedPrefix,'01');
 assert.throws(()=>targets({...base,allowFormatting:true,items:[{key:'bad',role:'body',text:'另一段没有给出的原文'}]}),/AMBIGUOUS_OR_MISSING/);
});
test('native alpha permits a preserved textured backdrop but cannot hide unremoved glyphs or a changed scene',()=>{
 const width=80,height=60,data=Buffer.alloc(width*height*4);for(let y=0;y<height;y++)for(let x=0;x<width;x++){const i=(y*width+x)*4;for(let k=0;k<3;k++)data[i+k]=20+(x+y)%35;data[i+3]=255;}
 const base={width,height,data},a={width,height,data:Buffer.from(data)},mask={core:new Uint8Array(width*height),erase:new Uint8Array(width*height)};
 for(let y=20;y<35;y++)for(let x=20;x<45;x++){const n=y*width+x;mask.core[n]=mask.erase[n]=255;for(let k=0;k<3;k++)a.data[n*4+k]=245;}
 assert.equal(auditMaskedRegion(a,base,[5,5,70,50],mask).coreInkRemovedRatio,1);
 assert.throws(()=>auditMaskedRegion(a,a,[5,5,70,50],mask),/BASE_NOT_CLEAN/);
 const altered={...base,data:Buffer.from(data)};altered.data.fill(255);assert.throws(()=>auditMaskedRegion(a,altered,[5,5,70,50],mask),/BASE_NOT_CLEAN/);
 assert.throws(()=>auditMaskedRegion(a,base,[5,5,70,50],{core:new Uint8Array(width*height),erase:new Uint8Array(width*height)}),/BASE_NOT_CLEAN/);
});
test('missing native alpha may use an independently flat verified plate; a dirty core can never fall through',()=>{
 const {eraseAudit}=require('../cloudfunctions/bf-image/native-copy-refinement'),width=80,height=60,data=Buffer.alloc(width*height*4,255),base={width,height,data},a={width,height,data:Buffer.from(data)};
 for(let y=20;y<35;y++)for(let x=20;x<45;x++)for(let k=0;k<3;k++)a.data[(y*width+x)*4+k]=20;
 const mask={core:new Uint8Array(width*height),erase:new Uint8Array(width*height)},box=[5,5,70,50];
 const r=eraseAudit(a,base,box,['#141414'],mask);assert.equal(r.rect,true);assert.equal(r.check.mode,'missing_native_alpha_independent_flat_audit');
 assert.throws(()=>eraseAudit(a,a,box,['#141414'],mask),/BASE_NOT_CLEAN/);
 mask.core.fill(255);mask.erase.fill(255);assert.throws(()=>eraseAudit(a,base,box,['#141414'],mask),/BASE_NOT_CLEAN/);
});
