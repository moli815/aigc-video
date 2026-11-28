"use strict";
const test=require("node:test"),assert=require("node:assert/strict"),m=require("../cloudfunctions/bf-api/account-image-memory");
const id="11111111-1111-4111-8111-111111111111",mid="22222222-2222-4222-8222-222222222222",other="33333333-3333-4333-8333-333333333333";
const file=(patch={})=>({accountId:"a",kind:"file",refId:id,version:3,payload:{id,categoryRaw:"image",textContent:"原OCR文字",asset:{id:"f".repeat(40)},...patch}});
const message=(patch={})=>({accountId:"a",kind:"message",refId:mid,payload:{id:mid,role:"user",createdAt:100,attachmentIds:id,text:"这是我们公司的logo，以后做海报请记住用原件",...patch}});
test("explicit logo statement binds the actual attached original and preserves OCR",()=>{
 const p=m.planImageMemory({owner:"a",files:[file()],messages:[message()]});assert.equal(p.bindings.length,1);assert.equal(p.preferred.company_logo.fileId,id);assert.match(p.mutations[0].payload.textContent,/原OCR文字/);assert.match(p.mutations[0].payload.textContent,/公司原始Logo/);assert.equal(p.mutations[0].baseVersion,3);
});
test("cross-account, deleted, assistant and unuploaded images never become brand facts",()=>{
 for(const msg of [{...message(),accountId:"b"},{...message(),deleted:true},message({role:"assistant"}),message({attachmentIds:other})])assert.equal(m.planImageMemory({owner:"a",files:[file()],messages:[msg]}).bindings.length,0);
 for(const f of [{...file(),accountId:"b"},{...file(),deleted:true},file({isDeleted:true}),file({asset:null})])assert.equal(m.planImageMemory({owner:"a",files:[f],messages:[message()]}).bindings.length,0);
});
test("ambiguous multi-image references and negations are not guessed",()=>{
 assert.equal(m.planImageMemory({owner:"a",files:[file()],messages:[message({attachmentIds:id+","+other})]}).bindings.length,0);
 for(const text of ["这不是我们公司的logo","这是我们客户公司的logo","这是合作保险公司的Logo","上次Logo为什么没放上去","以后不要记这个Logo"])assert.equal(m.explicitRole(text),null);
});
test("explicit ordinal and repeated indexing are deterministic and idempotent",()=>{
 const p=m.planImageMemory({owner:"a",files:[file()],messages:[message({attachmentIds:other+","+id,text:"图二是我们公司的Logo"})]});assert.equal(p.mutations.length,1);
 const again=m.planImageMemory({owner:"a",files:[{...file(),payload:p.mutations[0].payload}],messages:[message({attachmentIds:other+","+id,text:"图二是我们公司的Logo"})]});assert.equal(again.mutations.length,0);
});
test("latest explicit original is preferred, rather than the latest unrelated image",()=>{
 const f2={...file(),refId:other,payload:{...file().payload,id:other}};
 const msg2={...message(),refId:other,payload:{...message().payload,id:other,attachmentIds:other,createdAt:200}};
 const p=m.planImageMemory({owner:"a",files:[f2,file()],messages:[message(),msg2]});assert.equal(p.preferred.company_logo.fileId,other);assert.equal(p.bindings.length,2);
});
test("missing owner fails closed",()=>assert.throws(()=>m.planImageMemory({owner:"",messages:[],files:[]}),/OWNER_REQUIRED/));

test("a role cannot cross an attachment ordinal, even when separated by just a comma or a space",()=>{
 const first={...file({id:other}),refId:other};
 for(const separator of ["，",","," ","；","。\n",""]){
  const msg=message({attachmentIds:other+","+id,text:"图一是产品图"+separator+"图二是我们公司的 Logo。"});
  const result=m.planImageMemory({owner:"a",files:[first,file()],messages:[msg]});
  assert.deepEqual(result.bindings.map(b=>b.fileId),[id]);
 }
 const pair=message({attachmentIds:other+","+id,text:"图一是我们的平台界面截图，图二是我们公司的Logo。"});
 const result=m.planImageMemory({owner:"a",files:[first,file()],messages:[pair]});
 assert.equal(result.preferred.company_logo.fileId,id);assert.equal(result.preferred.platform_ui.fileId,other);
});
test("ordinals retain empty slots and accept explicit roles beyond the first six uploads",()=>{
 const ids=Array.from({length:13},(_,i)=>i===12?id:other);
 for(const declaration of ["第十三张是我们公司的Logo","附件13：我们公司的Logo","图13是我们的Logo"]){
  assert.equal(m.selectedId({attachmentIds:ids.join(","),text:declaration},"company_logo"),id);
 }
 assert.equal(m.selectedId({attachmentIds:"bad,"+id,text:"图一是我们的Logo"},"company_logo"),null);
 assert.equal(m.selectedId({attachmentIds:id,text:"这是我们的Logo，用在图一的页脚"},"company_logo"),id);
});
