"use strict";
const test=require('node:test'),assert=require('node:assert/strict'),{PNG}=require('../cloudfunctions/bf-image/node_modules/pngjs'),{audit}=require('../cloudfunctions/bf-image/native-text-coverage');
function input(){const data=Buffer.alloc(200*120*4);for(let y=30;y<50;y++)for(let x=35;x<95;x++){const i=(y*200+x)*4;data[i+3]=255;}return{bytes:PNG.sync.write({width:200,height:120,data}),width:400,height:240,rows:[{index:1,bounding_box:{absolute:[40,60,240,180]},text_recognition:{lines:[{bounding_box:{absolute:[75,90,135,110]}}]}}]};}
test('native alpha verifies independent layer/base dimensions through official parent geometry',async()=>{
 const i=input(),r=await audit(i);assert.equal(r.complete,true);assert.equal(r.uncoveredInkPixels,0);
});
test('OCR omission is detected from actual alpha, never mistaken for an empty original',async()=>{
 const i=input();i.rows[0].text_recognition.lines=[];const r=await audit(i);assert.equal(r.complete,false);assert.equal(r.uncoveredRatio,1);assert.deepEqual(r.missingRegions[0].box,[75,90,135,110]);
});
test('opaque artwork, false geometry and unknown layers cannot pass as text evidence',async()=>{
 const i=input(),png=PNG.sync.read(i.bytes);for(let n=3;n<png.data.length;n+=4)png.data[n]=255;
 await assert.rejects(audit({...i,bytes:PNG.sync.write(png)}),/ALPHA_NOT_TEXT_LAYER/);
 i.rows[0].bounding_box.absolute[0]=-1;await assert.rejects(audit(i),/GEOMETRY/);
 await assert.rejects(audit({...input(),rows:[]}),/ALPHA_CANVAS/);
});
