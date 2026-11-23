"use strict";
const test=require('node:test'),assert=require('node:assert/strict'),{PNG}=require('../cloudfunctions/bf-image/node_modules/pngjs'),{proposeNativeAreas}=require('../cloudfunctions/bf-image/flat-copy-restoration');
function fixture(){
 const width=400,height=100,data=Buffer.alloc(width*height*4,246);for(let i=3;i<data.length;i+=4)data[i]=255;
 const boxes=[[15,20,175,40],[220,20,380,40]],texts=['巡检记录已同步完成','设备资料集中归档管理'];
 for(const [left,,right]of boxes)for(let y=25;y<36;y++)for(let x=left+7;x<right-7;x++)if(x%12<6){const at=(y*width+x)*4;data[at]=12;data[at+1]=18;data[at+2]=24;}
 return{original:PNG.sync.write({width,height,data}),rows:[{index:1,bounding_box:{absolute:[0,0,width,height]},text_recognition:{lines:texts.map((text,i)=>({bounding_box:{absolute:boxes[i]},runs:[{text,style:{foreground_color:'#102038'}}]}))}}],items:texts.map((text,i)=>({key:'f'+i,role:'body',text}))};
}
test('proposal uniquely binds all canonical fields and derives disjoint geometry without a poster template',()=>{
 const f=fixture(),before=JSON.stringify(f.rows),p=proposeNativeAreas(f);
 assert.equal(p.areas.length,2);assert.equal(p.requiresReview,true);assert.equal(p.fullCopy,true);assert.equal(p.geometrySource,'official_lines_unique_canonical_match');
 assert.equal(JSON.stringify(f.rows),before);assert.deepEqual(p.areas.map(a=>a.text),f.items.map(a=>a.text));assert.ok(p.areas[0].box[2]<=p.areas[1].box[0]);assert.ok(p.areas.every(a=>a.color==='#102038'));
});
test('an unselected native line prevents full-copy approval and partial proposals remain explicitly unreviewed',()=>{
 const f=fixture();f.items=f.items.slice(0,1);assert.throws(()=>proposeNativeAreas(f),/NATIVE_TEXT_EXTRA_COPY/);
 const p=proposeNativeAreas({...f,requireFullCopy:false});assert.equal(p.areas.length,1);assert.equal(p.requiresReview,true);assert.equal(p.fullCopy,false);
});
test('coloured artwork within proposed text geometry cannot become a flat erasure',()=>{
 const f=fixture(),r=PNG.sync.read(f.original);for(let y=21;y<40;y++)for(let x=50;x<165;x++){const at=(y*r.width+x)*4;r.data[at]=220;r.data[at+1]=30;r.data[at+2]=70;}f.original=PNG.sync.write(r);
 assert.throws(()=>proposeNativeAreas(f),/FLAT_COPY_NO_SAFE_NATIVE_AREA/);
});
test('a left-column field cannot expand its repair surface across unrelated coloured artwork',()=>{
 const f=fixture(),r=PNG.sync.read(f.original);f.items=f.items.slice(0,1);f.rows[0].text_recognition.lines=f.rows[0].text_recognition.lines.slice(0,1);
 for(let y=20;y<40;y++)for(let x=195;x<395;x++){const at=(y*r.width+x)*4;r.data[at]=40;r.data[at+1]=140;r.data[at+2]=210;}
 f.original=PNG.sync.write(r);const p=proposeNativeAreas(f);assert.equal(p.areas.length,1);assert.ok(p.areas[0].box[2]<=180);assert.ok(p.areas[0].box[2]<195);
});
