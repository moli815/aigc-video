"use strict";
const test=require('node:test'),assert=require('node:assert/strict');
const {blockingIssues,createProtectionRuntime}=require('../cloudfunctions/bf-image/image-protection-runtime');
const crypto=require('node:crypto'),{PNG}=require('../cloudfunctions/bf-image/node_modules/pngjs');
test('only an opted-in canonical text stage may defer garbled glyphs; missing facts and occlusions still block',()=>{
 const codes=['GARBLED_TEXT','MISSING_COPY','UNSUPPORTED_COPY','INSTRUCTION_LEAK','OCCLUSION','OTHER'];
 const layout={issues:codes.map(code=>({code,detail:'fixture'}))};
 assert.deepEqual(blockingIssues(layout).map(x=>x.code),codes);
 assert.deepEqual(blockingIssues(layout,'true').map(x=>x.code),codes);
 assert.deepEqual(blockingIssues(layout,true).map(x=>x.code),codes.slice(1));
});
test('actual protection stage requires trusted host opt-in and composes originals before later canonical typography',async()=>{
 const owner='alice',hash=b=>crypto.createHash('sha256').update(b).digest('hex'),rows=new Map(),files=new Map();
 const encode=(w,h)=>PNG.sync.write({width:w,height:h,data:Buffer.alloc(w*h*4,255)});
 async function archive(o,bytes,mime){assert.equal(o,owner);const sha256=hash(bytes),id=hash(o+':'+sha256).slice(0,40),cloudPath='user/'+hash(o).slice(0,24)+'/assets/'+sha256+'.png',url='https://fixture.myqcloud.com/'+cloudPath;
  rows.set(id,{_id:id,accountId:o,state:'ready',privateACL:true,sha256,byteCount:bytes.length,mime,cloudPath,fileID:'cloud://fixture/'+cloudPath});files.set(url,bytes);return{id,sha256,byteCount:bytes.length,mime};}
 const source=await archive(owner,encode(64,64),'image/png'),urlOf=id=>'https://fixture.myqcloud.com/'+rows.get(id).cloudPath;
 const layout={confidence:.95,regions:[{index:1,quad:[[.1,.2],[.7,.2],[.7,.8],[.1,.8]]}],occupied:[],recognized_text:[],issues:[{code:'GARBLED_TEXT',detail:'正文笔画错误'}]};
 const runtime=createProtectionRuntime({assetStore:{archive,verifyReferences:async(o,list)=>{assert.equal(o,owner);assert.ok(list.every(a=>rows.has(a.id)));},sign:async(o,ids)=>ids.map(id=>({id,url:urlOf(id)}))},readAsset:async(o,id)=>rows.get(id),fetcher:async url=>new Response(files.get(url)),locate:async()=>layout});
 const args={owner,authorization:'test-only',image:urlOf(source.id),structured:{deferGarbledText:true,text:[{key:'b',role:'body',text:'正确原文'}]},plan:{native:true,protected_references:[{index:1,role:'ui'}],deferGarbledText:true}};
 const prepared=await runtime.prepare(args);assert.equal(prepared.deferGarbledText,false);
 const draft=await archive(owner,encode(360,240),'image/png');await assert.rejects(runtime.finish(prepared,urlOf(draft.id)),/VISUAL_REVIEW_REQUIRED/);
 const trusted=await runtime.prepare({...args,deferGarbledText:true});assert.equal(trusted.deferGarbledText,true);
 const result=await runtime.finish(trusted,urlOf(draft.id));assert.ok(result.asset.id);assert.ok(result.protection);
 layout.issues.push({code:'MISSING_COPY',detail:'缺栏目'});await assert.rejects(runtime.finish(trusted,urlOf(draft.id)),/VISUAL_REVIEW_REQUIRED/);
});
