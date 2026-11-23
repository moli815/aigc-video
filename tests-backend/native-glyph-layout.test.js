"use strict";
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),g=require('../cloudfunctions/bf-image/native-glyph-layout');
const fontData=fs.readFileSync(path.resolve(__dirname,'fixtures/cjk-typography/BossAI-Test-Regular.otf'));
test('real outline metrics preserve every code point, punctuation and hard break with unclipped ink',()=>{
 const text='准确中文标题\n原文不能丢 01-23',r=g.measure({text,width:240,height:130,fontSize:22,fontData});
 assert.equal(r.lines.map(l=>l.text).join(''),text);assert.ok(r.paths.length>=2);assert.ok(r.boxes.every(b=>b.box[0]>=0&&b.box[1]>=0&&b.box[2]<=240&&b.box[3]<=130));assert.equal(r.fontSize,22);assert.equal(r.glyphCount,[...text].filter(c=>!(/\s/u.test(c))).length);
 const size=g.inferFontSize({text:'中文标题',inkHeight:20,fontData});assert.ok(size>20&&size<24,'CJK ink bounds differ from font em; do not use bbox × .75');
 assert.ok(g.svgOf(r,{width:240,height:130,color:'#152B38'}).includes('<path'));assert.ok(!g.svgOf(r,{width:240,height:130,color:'#152B38'}).includes('<text'));
});
test('overflow never clips, deletes copy or silently shrinks the font; unsupported shaping is rejected',()=>{
 assert.throws(()=>g.measure({text:'中文原文不能丢'.repeat(8),width:120,height:30,fontSize:22,fontData}),/GLYPH_HEIGHT_OVERFLOW/);
 assert.throws(()=>g.measure({text:'0123456789',width:12,height:50,fontSize:22,fontData}),/GLYPH_WIDTH_OVERFLOW/);
 for(const text of ['资料🙂归档','مرحبا','a\u0301'])assert.throws(()=>g.measure({text,width:120,height:80,fontSize:22,fontData}),/GLYPH_SHAPING_UNSUPPORTED/);
});
test('bounded font workers return identical copy/ink results and terminate before returning',async()=>{
 const areas=[{key:'body',box:[10,10,250,100],fontSize:22,weight:400,text:'准确中文原文不能丢',lineHeight:1.25}],fonts=[{weight:400,data:fontData},{weight:700,data:fs.readFileSync(path.resolve(__dirname,'fixtures/cjk-typography/BossAI-Test-Bold.otf'))}];
 const r=await g.prepareAreas({areas,fonts});assert.equal(r.length,1);assert.equal(r[0].layout.lines.map(l=>l.text).join(''),areas[0].text);assert.equal(r[0].fontSize,22);
 await assert.rejects(g.prepareAreas({areas,fonts,timeoutMs:1}),/GLYPH_WORKER_LIMIT/);
});

test('line worker budget covers the surface renderer 160-line contract without increasing copy or font heap limits',async()=>{
 const fonts=[{weight:400,data:fontData},{weight:700,data:fs.readFileSync(path.resolve(__dirname,'fixtures/cjk-typography/BossAI-Test-Bold.otf'))}],areas=Array.from({length:65},(_,i)=>({key:'line'+i,box:[0,0,180,40],fontSize:22,weight:400,text:'中文原文不能丢'}));
 const result=await g.prepareAreas({areas,fonts});assert.equal(result.length,65);assert.ok(result.every(r=>r.layout.lines.map(l=>l.text).join('')==='中文原文不能丢'));
 await assert.rejects(g.prepareAreas({areas:Array.from({length:161},(_,i)=>({...areas[0],key:'line'+i})),fonts}),/GLYPH_WORKER_INPUT/);
});
