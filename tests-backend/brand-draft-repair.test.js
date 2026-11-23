"use strict";
const test=require("node:test");
const assert=require("node:assert/strict");
const {PNG}=require("../cloudfunctions/bf-image/node_modules/pngjs");
const {clearGeneratedMarks}=require("../cloudfunctions/bf-image/brand-draft-repair");
const {requestOf,responseOf}=require("../cloudfunctions/shared/image-layout-protocol");
const {requestedBrand}=require("../cloudfunctions/bf-api/poster-brand-guidance");

test("new brand layout distinguishes generated branding from content and round trips boxes",()=>{
  const input=requestOf({image:"data:image/png;base64,AA==",references:[{index:1,role:"logo",aspect:4}],placement_only:true});
  const layout=responseOf({objects:[
    {kind:"content",label:"防护功能图标",bbox_2d:[100,100,400,200]},
    {kind:"generated_brand_mark",label:"额外品牌标识",bbox_2d:[100,400,300,450]}
  ]},input);
  assert.equal(layout.occupied.length,1);
  assert.equal(layout.generated_marks.length,1);
  assert.equal(layout.generated_marks[0][1],.4);
  assert.deepEqual(responseOf(layout,input),layout);
  assert.equal(requestedBrand("给我们公司做海报，双方Logo都要"),false);
});

test("local brand cleanup changes only the marked pixels and rejects collisions",async()=>{
  const png=new PNG({width:200,height:100});
  for(let i=0;i<png.data.length;i+=4)png.data.set([20,45,65,255],i);
  for(let y=41;y<48;y++)for(let x=34;x<61;x++)png.data.set([247,250,248,255],(y*200+x)*4);
  const source=PNG.sync.write(png),mark=[.16,.4,.16,.09];
  const final=PNG.sync.read(await clearGeneratedMarks(source,[mark],[[.16,.10,.4,.15]]));
  for(let y=0;y<100;y++)for(let x=0;x<200;x++){
    if(y>=40&&y<50&&x>=32&&x<64)continue;
    assert.deepEqual(final.data.subarray((y*200+x)*4,(y*200+x+1)*4),png.data.subarray((y*200+x)*4,(y*200+x+1)*4));
  }
  assert.ok(final.data[(45*200+50)*4]<40);
  await assert.rejects(clearGeneratedMarks(source,[mark],[[.26,.42,.14,.1]]),/POSTER_BRAND_MASK_UNSAFE/);
  await assert.rejects(clearGeneratedMarks(source,[[.1,.2,.5,.2]],[]),/POSTER_BRAND_MASK_UNSAFE/);
});

