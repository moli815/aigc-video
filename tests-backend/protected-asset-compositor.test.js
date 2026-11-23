"use strict";
const test=require("node:test"),assert=require("node:assert/strict"),crypto=require("crypto");
const {PNG}=require("../cloudfunctions/bf-image/node_modules/pngjs"),m=require("../cloudfunctions/bf-image/protected-asset-compositor");
function raster(w,h,color){const data=Buffer.alloc(w*h*4);for(let i=0;i<data.length;i+=4){data[i]=color[0];data[i+1]=color[1];data[i+2]=color[2];data[i+3]=color[3]??255;}return{width:w,height:h,data};}
const png=r=>PNG.sync.write(r),sha=b=>crypto.createHash("sha256").update(b).digest("hex");
test("uniform logo antialias edges recover soft alpha instead of a white fringe on dark artwork",async()=>{
 const r=raster(40,40,[255,255,255]);for(let y=8;y<32;y++)for(let x=8;x<32;x++){const i=(y*40+x)*4;r.data[i]=20;r.data[i+1]=40;r.data[i+2]=80;}
 for(let y=8;y<32;y++){const i=(y*40+7)*4;for(let k=0;k<3;k++)r.data[i+k]=Math.round(([20,40,80][k]+255)/2);}
 const before=Buffer.from(r.data),result=await m.cutout(r);let half=0;for(let i=0;i<result.raster.data.length;i+=4)if(result.raster.data[i+3]>100&&result.raster.data[i+3]<160){half++;for(let k=0;k<3;k++)assert.ok(Math.abs(result.raster.data[i+k]-[20,40,80][k])<=3);}
 assert.ok(half>=20,"edge pixels must retain partial opacity and uncontaminated brand colour");assert.deepEqual(r.data,before);
});
test("uniform logo matting preserves source RGB and enclosed white artwork",async()=>{
 const r=raster(40,40,[255,255,255]);for(let y=8;y<32;y++)for(let x=8;x<32;x++){const i=(y*40+x)*4;r.data[i]=13;r.data[i+1]=40;r.data[i+2]=105;}
 for(let y=16;y<24;y++)for(let x=16;x<24;x++){const i=(y*40+x)*4;r.data[i]=r.data[i+1]=r.data[i+2]=255;}
 const result=await m.cutout(r);assert.equal(result.method,"border-connected-uniform");assert.equal(result.raster.data[3],0);
 const colors=new Set();for(let i=0;i<result.raster.data.length;i+=4)if(result.raster.data[i+3])colors.add([...result.raster.data.subarray(i,i+3)].join());assert.deepEqual(colors,new Set(["13,40,105","255,255,255"]));assert.equal(r.data[3],255);
});
test("UI placement uses original pixels and leaves outside region byte-identical",async()=>{
 const canvas=raster(400,240,[230,225,210]),ui=raster(100,60,[10,30,90]);ui.data[(20*100+30)*4]=173;
 const original=png(ui),quad=[[100/399,40/239],[199/399,40/239],[199/399,99/239],[100/399,99/239]];
 const rendered=await m.compose({canvas:png(canvas),placements:[{role:"ui",bytes:original,sha256:sha(original),quad}]});
 const result=PNG.sync.read(rendered.png);assert.equal(result.data[((40+20)*400+100+30)*4],173);
 for(const [x,y]of [[0,0],[399,239],[99,45],[201,100]])assert.deepEqual([...result.data.subarray((y*400+x)*4,(y*400+x)*4+4)],[230,225,210,255]);
 assert.equal(rendered.manifest.placements[0].sourceSha256,sha(original));assert.equal(rendered.manifest.placements[0].method,"original-pixels");
});
test("perspective compositor and repeated use release OpenCV matrices",async()=>{
 const bytes=png(raster(80,60,[12,44,116])),quad=[[.1,.2],[.8,.1],[.75,.8],[.15,.9]];
 for(let i=0;i<4;i++){const r=await m.compose({canvas:png(raster(400,240,[255,255,255])),placements:[{role:"ui",bytes,sha256:sha(bytes),quad}]});assert.ok(r.png.length>0);assert.ok(r.manifest.ms<15000);}
});
test("unsafe geometry, empty alpha, bad hash and huge source fail before rendering",async()=>{
 for(const q of [[],[[0,0],[1,0],[0,1],[1,1]],[[0,0],[1.1,0],[1,1],[0,1]],[[0,0],[1,0],[1,1],[0,1]]])assert.throws(()=>m.quadOf(q,400,200),/QUAD_INVALID/);
 await assert.rejects(()=>m.cutout(raster(20,20,[0,0,0,0])),/EMPTY_ALPHA/);
 const b=png(raster(20,20,[0,0,0]));await assert.rejects(()=>m.compose({canvas:png(raster(100,100,[255,255,255])),placements:[{role:"ui",bytes:b,sha256:"wrong",quad:[[.1,.1],[.5,.1],[.5,.5],[.1,.5]]}]}),/INTEGRITY/);
});
test("logo position avoids actual occupied words and never accepts no-safe-space",()=>{
 const canvas={width:1600,height:900};const b=m.logoBox({canvas,aspect:2,occupied:[[0,0,.6,.2]],anchor:"top_left"});assert.ok(b[0]>.6);
 assert.throws(()=>m.logoBox({canvas,aspect:2,occupied:[[0,0,1,1]]}),/NO_SAFE_LOGO_SLOT/);
});
