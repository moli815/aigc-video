"use strict";
const test=require('node:test'),assert=require('node:assert/strict'),geo=require('../cloudfunctions/bf-image/protected-asset-compositor'),mod=require('../cloudfunctions/bf-image/native-layer-registration');
const fs=require('node:fs'),path=require('node:path');
function texture(){const width=600,height=900,data=Buffer.alloc(width*height*4);let seed=47;for(let i=0;i<data.length;i+=4){seed=(Math.imul(seed,1664525)+1013904223)>>>0;const v=seed>>>24;data[i]=v;data[i+1]=v;data[i+2]=v;data[i+3]=255;}return{width,height,data};}
async function scaled(bytes,matrix,width,height){const {PNG}=require('../cloudfunctions/bf-image/node_modules/pngjs'),r=geo.decode(bytes),{cv}=await geo.engine();let a,b,h;try{a=cv.matFromArray(r.height,r.width,cv.CV_8UC4,r.data);b=new cv.Mat();h=cv.matFromArray(3,3,cv.CV_64FC1,matrix);cv.warpPerspective(a,b,h,new cv.Size(width,height),cv.INTER_LINEAR,cv.BORDER_REPLICATE);return PNG.sync.write({width,height,data:Buffer.from(b.data)});}finally{a?.delete();b?.delete();h?.delete();}}
async function changed(source,shift=0){const {cv}=await geo.engine();let a,b,h;try{a=cv.matFromArray(source.height,source.width,cv.CV_8UC4,source.data);b=new cv.Mat();h=cv.matFromArray(3,3,cv.CV_64FC1,[602/600,0,shift,0,904/900,0,0,0,1]);cv.warpPerspective(a,b,h,new cv.Size(602,904),cv.INTER_LINEAR,cv.BORDER_REPLICATE);return{width:602,height:904,data:Buffer.from(b.data)};}finally{a?.delete();b?.delete();h?.delete();}}
test('distributed source evidence can register a minor provider canvas change without resizing the original',async()=>{
 const source=texture(),before=Buffer.from(source.data),target=await changed(source),r=await mod.estimate(source,target);
 assert.ok(r.metrics.inliers>=30);assert.ok(r.metrics.occupiedCells>=5);assert.ok(r.metrics.meanError<2);assert.ok(r.metrics.cornerDelta<3);assert.ok(before.equals(source.data));
 const p=mod.project(r.matrix,300,450);assert.ok(Math.abs(p[0]-301)<1);assert.ok(Math.abs(p[1]-452)<1);
});
test('a shifted crop and a blank canvas cannot qualify as a harmless dimensional change',async()=>{
 const source=texture();await assert.rejects(mod.estimate(source,await changed(source,20)),/REGISTRATION_UNCERTAIN/);
 const blank={width:source.width,height:source.height,data:Buffer.alloc(source.data.length,255)};await assert.rejects(mod.estimate(blank,blank),/REGISTRATION_UNCERTAIN/);
});

test('uniform auto-tier quantisation uses measured registration and leaves original pixels untouched',async()=>{
 const {PNG}=require('../cloudfunctions/bf-image/node_modules/pngjs'),source=texture(),original=PNG.sync.write(source),target=await scaled(original,[.96875,0,0,0,.96875,0,0,0,1],581,872);
 const layer={bytes:target,row:{index:1,bounding_box:{absolute:[0,0,581,872]},text_recognition:{lines:[{bounding_box:{absolute:[60,100,200,130]},runs:[{text:'经过核对的文字'}]}]}}};
 const before=Buffer.from(original),r=await mod.align({original,cleanBase:target,layers:[layer]});
 assert.ok(r.registration.metrics.inliers>=30);assert.ok(r.registration.metrics.cornerDelta<3);assert.ok(original.equals(before));
 assert.deepEqual(geo.decode(r.cleanBase).width,source.width);assert.deepEqual(r.layers[0].row.bounding_box.absolute,[0,0,600,900]);
 assert.ok(r.layers[0].row.text_recognition.lines[0].bounding_box.absolute[0]>=60);
});

test('matching aspect alone cannot qualify blank, shifted, or distorted auto-tier output',async()=>{
 const {PNG}=require('../cloudfunctions/bf-image/node_modules/pngjs'),source=texture(),original=PNG.sync.write(source),blank=PNG.sync.write({width:581,height:872,data:Buffer.alloc(581*872*4,255)});
 await assert.rejects(mod.align({original,cleanBase:blank,layers:[]}),/REGISTRATION_UNCERTAIN/);
 const shifted=await scaled(original,[.96875,0,20,0,.96875,0,0,0,1],581,872);
 await assert.rejects(mod.align({original,cleanBase:shifted,layers:[]}),/REGISTRATION_UNCERTAIN/);
 const distorted=await scaled(original,[.8,0,0,0,.96875,0,0,0,1],480,872);
 await assert.rejects(mod.align({original,cleanBase:distorted,layers:[]}),/CANVAS_CHANGED/);
});
test('real text-cleared auto canvas uses all-nine-cell and independent-scale evidence rather than an arbitrary 65 percent feature span',async()=>{
 const dir=path.resolve(__dirname,'../outputs/native-copy-rollout-20261117/live-4/assets'),source=geo.decode(fs.readFileSync(path.join(dir,'9b87cb8a57561aea077ce7c34f5b9947d3db87e9.png'))),target=geo.decode(fs.readFileSync(path.join(dir,'66991039e95a1c6d94c70ca09bf4839f5ffe5a15.png')));
 const r=await mod.estimate(source,target);assert.equal(r.metrics.occupiedCells,9);assert.ok(r.metrics.inliers>=300);assert.ok(r.metrics.spanY<.65);assert.ok(r.metrics.fixedCanvasP95<=r.metrics.analysisPixelSize);assert.equal(r.metrics.coverageMode,'quantised_canvas_with_independent_scale_proof');
});
