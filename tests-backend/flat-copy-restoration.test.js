"use strict";
const test=require('node:test'),assert=require('node:assert/strict'),mod=require('../cloudfunctions/bf-image/flat-copy-restoration');
function fixture(light=true){
 const width=200,height=80,bg=light?[246,246,246]:[18,24,30],fg=light?[12,18,24]:[245,245,245],data=Buffer.alloc(width*height*4);
 for(let i=0;i<data.length;i+=4){bg.forEach((v,k)=>data[i+k]=v);data[i+3]=255;}
 for(let y=25;y<40;y++)for(let x=30;x<150;x++)if(x%12<6){const i=(y*width+x)*4;fg.forEach((v,k)=>data[i+k]=v);}
 return{r:{width,height,data},area:{key:'test',box:[5,5,190,70],text:'经过确认的正确文字',fontSize:14,weight:400,color:light?'#B01020':'#FFDD22'}};
}
test('flat mask measures original ink independently of destination font colour on light and dark designs',()=>{
 for(const light of [true,false]){const {r,area}=fixture(light),out=mod.sampleMask(r,area);assert.ok(out.metrics.inkRatio>.02);assert.ok(out.metrics.unexplainedRatio<.025);assert.equal(out.mask[(25-5)*out.width+36-5],255);assert.equal(out.mask[(25-5)*out.width+30-5],0);}
});
test('weak boundary-connected panel shading is preserved, strong clipped lettering is rejected',()=>{
 const {r,area}=fixture();for(let y=5;y<70;y++)for(let k=0;k<3;k++)r.data[(y*r.width+5)*4+k]=215;
 const out=mod.sampleMask(r,area);assert.ok(out.metrics.backgroundEdgePixelsPreserved>0);assert.equal(out.mask[0],0);
 for(let y=25;y<40;y++)for(let k=0;k<3;k++)r.data[(y*r.width+5)*4+k]=10;
 assert.throws(()=>mod.sampleMask(r,area),/FLAT_COPY_EDGE_INK/);
});
test('coloured imagery and low contrast cannot masquerade as a safe flat text background',()=>{
 const {r,area}=fixture();for(let y=20;y<50;y++)for(let x=80;x<150;x++){const i=(y*r.width+x)*4;r.data[i]=220;r.data[i+1]=30;r.data[i+2]=70;}
 assert.throws(()=>mod.sampleMask(r,area),/BACKGROUND_UNSAFE/);
 const f=fixture();for(let i=0;i<f.r.data.length;i+=4)for(let k=0;k<3;k++)f.r.data[i+k]=235+Math.round((f.r.data[i+k]-12)/234*10);
 assert.throws(()=>mod.sampleMask(f.r,f.area),/LOW_CONTRAST/);
});
test('unreviewed or model-asserted geometry never enables this offline repair experiment',async()=>{
 for(const geometryEvidence of [undefined,true,'validated_native_text_lines'])await assert.rejects(mod.restore({geometryEvidence}),/REVIEWED_GEOMETRY_REQUIRED/);
});
