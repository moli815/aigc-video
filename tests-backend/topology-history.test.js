'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const {prepareSingleReferenceGuidance}=require('../cloudfunctions/bf-api/image-single-reference-guidance');
const {selectFacts}=require('../cloudfunctions/bf-api/account-context');
const {planImageMemory}=require('../cloudfunctions/bf-api/account-image-memory');
const {syncRecordKey}=require('../cloudfunctions/shared/sync-identifiers');
const {createSyncedImageReferenceStore}=require('../cloudfunctions/shared/image-reference-store');
const {currentImageNeedsCompanyLogo}=require('../cloudfunctions/bf-api/poster-brand-guidance');
const owner='one', logo='ADFC0E7F-3741-4FDF-A59E-CE8EE442A12A',decl='55555555-5555-4111-8111-555555555555';
const tools=['recall_history','image_generate','image_edit','image_series'].map(name=>({function:{name,parameters:{properties:{structured:{}}}}}));
const turn=text=>({role:'user',content:[{type:'text',text},{type:'image_url',image_url:{url:'test-photo'}}]});
const task=turn('把这张拓扑图做成宣传海报，加上以前给过的企业 Logo、公司介绍和最新联系方式。');
function record(kind,id,props){return {accountId:owner,kind,refId:id,deleted:false,payload:{id,...props}};}
const file=record('file',logo,{categoryRaw:'image',asset:{id:'a'.repeat(40),sha256:'1'.repeat(64),mime:'image/png',byteCount:92}});
const msg=record('message',decl,{role:'user',text:'这是我们公司的Logo。',attachmentIds:logo,createdAt:10});
const indexed={...file,payload:planImageMemory({owner,messages:[msg],files:[file]}).mutations[0].payload};
function prepare(rows,more=[]){
 const db={collection(){return {where(){return this;},orderBy(){return this;},limit(){return this;},
   async get(){return {data:rows.filter(r=>r.kind==='file')};},
   doc(key){return {get:async()=>({data:rows.filter(r=>syncRecordKey(owner,r.kind,r.refId)===key)})};}};}};
 const referenceStore=createSyncedImageReferenceStore({db,assetStore:{verifyReferences:async(who)=>assert.equal(who,owner),sign:async()=>[]}});
 return prepareSingleReferenceGuidance({messages:[task,...more],tools,owner,policy:{enabled:true,audience:'all'},db,referenceStore,bindCompanyLogo:true});
}
const recall=[{role:'assistant',tool_calls:[{id:'r',function:{name:'recall_history'}}]},{role:'tool',tool_call_id:'r',content:'图片ID：'+logo}];
function call(args){return {function:{name:'image_generate',arguments:JSON.stringify(args)}};}
test('existing iOS source contract carries the current topology first and verified branded original second',async()=>{
 for(const more of [[],recall]){
  const p=await prepare([indexed,msg],more);
  for(const args of [{source:'attached'},{source:'none',library_refs:[logo]}]){
   const out=JSON.parse(p.finalize(p.normalize([call({...args,prompt:'保留设备和连接关系'})]))[0].function.arguments);
   assert.equal(out.source,'attached');assert.equal(out.source_index,1);assert.equal(out.library_refs,undefined);
   assert.equal(out.prompt,'保留设备和连接关系');assert.deepEqual(out.structured.image_references,{version:1,mode:'append',items:[{id:logo,kind:'library',role:'公司Logo原件'}]});
  }
 }
});
test('missing declaration, foreign declaration, or two different originals cannot silently produce an unbranded or misbranded image',async()=>{
 const otherFile='BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB',otherMsg='CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC';
 const file2=record('file',otherFile,{categoryRaw:'image',asset:{...file.payload.asset,id:'b'.repeat(40)}});
 const msg2=record('message',otherMsg,{...msg.payload,id:otherMsg,createdAt:12,attachmentIds:otherFile});
 const second={...file2,payload:planImageMemory({owner,messages:[msg2],files:[file2]}).mutations[0].payload};
 for(const rows of [[indexed],[indexed,{...msg,accountId:'two'}],[indexed,msg,second,msg2]]){
  const p=await prepare(rows);assert.deepEqual(p.tools.map(t=>t.function.name),['recall_history']);
 }
 const p=await prepare([indexed],recall);assert.equal(p.tools.length,0);assert.match(p.messages.at(-1).content,/补发/);
});
test('brand original recovery respects exclusions, current attachments and local edit intent',()=>{
 assert.equal(currentImageNeedsCompanyLogo([task]),true);
 for(const s of ['重新画这张图，不要加企业Logo','这是我们公司的Logo，放到之前的海报上','加上合作方的企业Logo','改右上角两行、保留橙线'])
  assert.equal(currentImageNeedsCompanyLogo([turn(s)]),false);
 const two=turn('这张图加企业Logo');two.content.push(two.content[1]);assert.equal(currentImageNeedsCompanyLogo([two]),false);
});
test('stored brand text uses the latest synced revision for the hotline and preserves client-written company profile',()=>{
 const fact=(text,n)=>({...record('memory',logo,{source:'brand-memory',text}),revision:n,updatedAt:100+n});
 const rows=[fact('公司联系方式：400-620-7319',3),fact('公司联系方式：400-620-7999',1),record('memory',decl,{content:'公司简介：园区报警设备远程运维。'})];
 assert.deepEqual(selectFacts({owner,query:'做公司海报',messages:[],memories:rows}).map(f=>f.text),['公司联系方式：400-620-7319','公司简介：园区报警设备远程运维。']);
});
