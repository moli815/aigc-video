"use strict";
const test=require('node:test'),assert=require('node:assert/strict');
const {PNG}=require('../cloudfunctions/bf-image/node_modules/pngjs'),{preview}=require('../cloudfunctions/bf-image/image-protection-runtime'),{probeImageSize}=require('../cloudfunctions/bf-image/media-guards');
test('dense tall PNG reaches the review service at original dimensions and with identical glyph pixels',async()=>{
 const width=1400,height=3000,data=Buffer.alloc(width*height*4,255);
 for(let y=1500;y<1515;y++)for(let x=800;x<1200;x++)if((x+y)%4===0){const at=(y*width+x)*4;data[at]=data[at+1]=data[at+2]=12;}
 const bytes=PNG.sync.write({width,height,data}),url=await preview(bytes),actual=Buffer.from(url.split(',')[1],'base64');
 assert.ok(bytes.length<2500000);assert.ok(url.startsWith('data:image/png;base64,'));assert.ok(actual.equals(bytes));assert.equal(probeImageSize(actual).h,height);assert.equal(probeImageSize(actual).w,width);
 assert.doesNotThrow(()=>require('../cloudfunctions/shared/image-layout-protocol').requestOf({image:url,references:[],expected_text:['确认原文']}));
});
test('large compressed payload may change JPEG quality but never crops or resizes review geometry',async()=>{
 const width=1000,height=1100,data=Buffer.alloc(width*height*4);let seed=37;
 for(let i=0;i<data.length;i+=4){for(let k=0;k<3;k++){seed=(Math.imul(seed,1664525)+1013904223)>>>0;data[i+k]=seed>>>24;}data[i+3]=255;}
 const bytes=PNG.sync.write({width,height,data});assert.ok(bytes.length>2500000);
 const url=await preview(bytes),actual=Buffer.from(url.split(',')[1],'base64'),size=probeImageSize(actual);
 assert.ok(url.startsWith('data:image/jpeg;base64,'));assert.ok(actual.length<=2500000);assert.deepEqual([size.w,size.h],[width,height]);
});
test('a high-entropy 2K image retains the previous bounded preview fallback instead of a new hard failure',async()=>{
 const width=2048,height=2048,data=Buffer.alloc(width*height*4);let seed=37;
 for(let i=0;i<data.length;i+=4){for(let k=0;k<3;k++){seed=(Math.imul(seed,1664525)+1013904223)>>>0;data[i+k]=seed>>>24;}data[i+3]=255;}
 const bytes=PNG.sync.write({width,height,data}),url=await preview(bytes),actual=Buffer.from(url.split(',')[1],'base64'),size=probeImageSize(actual);
 assert.ok(actual.length<=1500000);assert.equal(size.w,1280);assert.equal(size.h,1280);assert.doesNotThrow(()=>require('../cloudfunctions/shared/image-layout-protocol').requestOf({image:url,references:[],expected_text:[]}));
});
