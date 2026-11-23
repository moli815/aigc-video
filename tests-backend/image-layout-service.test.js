"use strict";
const test=require("node:test"),assert=require("node:assert/strict"),p=require("../cloudfunctions/shared/image-layout-protocol");
const raw={image:"data:image/png;base64,aGVsbG8=",references:[{index:1,role:"ui",aspect:16/9}],expected_text:["真实产品展示"]};
const result=()=>({confidence:.95,regions:[{index:1,quad:[[.1,.1],[.9,.1],[.9,.6],[.1,.6]]}],occupied:[[.1,.8,.6,.1]],issues:[],recognized_text:[{text:"真实产品展示",box:[.1,.8,.6,.1]}]});
test("layout accepts one preview only, strict roles and bounded copy",()=>{
 const input=p.requestOf(raw);assert.equal(input.image,raw.image);assert.equal(p.messagesOf(input)[1].content.filter(c=>c.type==="image_url").length,1);
 for(const bad of [{...raw,owner:"other"},{...raw,image:"https://foreign"},{...raw,references:[...raw.references,...raw.references]},{...raw,expected_text:["a".repeat(2001)]}])assert.throws(()=>p.requestOf(bad),/IMAGE_LAYOUT_INVALID/);
});
test("layout rejects invented slots, crossing quads, low confidence and ambiguous review prose",()=>{
 const input=p.requestOf(raw);assert.equal(p.responseOf(result(),input).regions.length,1);
 for(const patch of [{confidence:.6},{regions:[]},{regions:[{index:2,quad:result().regions[0].quad}]},{regions:[{index:1,quad:[[.1,.1],[.9,.6],[.9,.1],[.1,.6]]}]},{issues:["没有乱码"]}])assert.throws(()=>p.responseOf({...result(),...patch},input),/IMAGE_LAYOUT_UNCERTAIN/);
});
test("same-owner in-flight analysis and cache are billed once, cross-owner never shares cache",async()=>{
 const {createLayoutService}=require("../cloudfunctions/bf-api/image-layout-service");let calls=0,bills=0;const cache=new Map();
 const svc=createLayoutService({request:async()=>{calls++;await new Promise(r=>setTimeout(r,10));return {choices:[{message:{content:JSON.stringify(result())}}]};},bill:async()=>{bills++;},cacheGet:async k=>cache.get(k),cachePut:async(k,v)=>cache.set(k,v)});
 await Promise.all([svc.analyze("a",raw,"vision"),svc.analyze("a",raw,"vision")]);assert.equal(calls,1);assert.equal(bills,1);
 assert.equal((await svc.analyze("a",raw,"vision")).cached,true);await svc.analyze("b",raw,"vision");assert.equal(calls,2);assert.equal(bills,2);
 assert.ok([...cache.values()].every(s=>!s.includes("base64")&&!s.includes("hello")));
});
test("completed but malformed analysis records provider cost without caching or generating again",async()=>{
 const {createLayoutService}=require("../cloudfunctions/bf-api/image-layout-service");let billed=0,writes=0;
 const svc=createLayoutService({request:async()=>({choices:[{message:{content:"invalid"}}]}),bill:async()=>{billed++;},cachePut:async()=>{writes++;}});
 await assert.rejects(svc.analyze("a",raw,"vision"),/IMAGE_LAYOUT_UNCERTAIN/);assert.equal(billed,1);assert.equal(writes,0);
});
test("numeric review ignores original UI but refuses invented outside numbers",()=>{
 const {numericIssues}=require("../cloudfunctions/bf-image/image-protection-runtime");const layout=result();layout.recognized_text=[{text:"1030945",box:[.2,.2,.1,.1]},{text:"提升99%",box:[.1,.8,.2,.1]}];
 assert.deepEqual(numericIssues(layout,["提升99%"]),[]);assert.equal(numericIssues(layout,["提升效率"]).length,1);
});
test("real round-two overlap regression refuses to paste over readable campaign copy",()=>{
 const {copyOcclusions}=require("../cloudfunctions/bf-image/image-protection-runtime"),layout=result();
 layout.regions=[{index:1,quad:[[.26,.24],[.73,.24],[.73,.74],[.26,.74]]}];
 layout.recognized_text=[{text:"事件记录",box:[.24,.34,.07,.02]},{text:"标题",box:[.1,.07,.76,.08]}];
 assert.equal(copyOcclusions(layout).length,1);layout.recognized_text=[{text:"标题",box:[.1,.07,.76,.08]}];assert.deepEqual(copyOcclusions(layout),[]);
});
test("thin screen/text crossings are occlusions even when no corner or centre is contained",()=>{
 const {copyOcclusions}=require("../cloudfunctions/bf-image/image-protection-runtime");
 const layout={regions:[{index:1,quad:[[.60,.1],[.62,.1],[.62,.9],[.60,.9]]}],recognized_text:[{text:"合作电话",box:[.1,.4,.8,.05]}]};
 assert.equal(copyOcclusions(layout).length,1);
 layout.regions[0].quad=[[.91,.1],[.93,.1],[.93,.9],[.91,.9]];assert.equal(copyOcclusions(layout).length,0);
});
