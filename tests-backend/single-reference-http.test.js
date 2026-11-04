"use strict";
const test=require('node:test'),assert=require('node:assert/strict'),crypto=require('node:crypto'),vm=require('node:vm');
const {harness,U}=require('./reference-http-fixture.cjs');
const hash=s=>crypto.createHash('sha256').update(s).digest('hex');
async function fixture(){const h=await harness(),sha256=hash('current-actual-image'),id=hash('A:'+sha256).slice(0,40),cloudPath='user/'+hash('A').slice(0,24)+'/assets/'+sha256+'.png';
 await h.db.collection('bf_assets').doc(id).set({accountId:'A',state:'ready',privateACL:true,sha256,mime:'image/png',byteCount:24,cloudPath,fileID:'cloud://env.bucket/'+cloudPath});
 return {...h,currentId:id,currentUrl:'https://bucket.cos.ap-shanghai.myqcloud.com/'+cloudPath+'?q-signature=old'};}
const body=(h,rid='mixed')=>({requestId:rid,prompt:'将历史素材的人物合成到当前提供的背景中，保留人物服装和面部特征。',task_kind:'edit',quality_tier:'high',size:'1536x1536',image:h.currentUrl,structured:{image_references:{version:1,mode:'append',items:[{kind:'library',id:U[1],role:'人物原图'}]}}});
test('real single handler sends current plus historical pixels in order and records actual image count',async()=>{
 const h=await fixture(),r=await h.request('/image',body(h));assert.equal(r.status,200);assert.equal(h.calls.length,1);assert.equal(h.calls[0].image.length,2);assert.ok(h.calls[0].image[0].includes(new URL(h.currentUrl).pathname.slice(1))); assert.match(h.calls[0].image[1],/image-1/);assert.match(h.calls[0].prompt,/人物原图/);assert.equal(h.charges.length,1);
 const rows=(await h.db.collection('bf_image_jobs').get()).data;assert.equal(rows[0].referenceManifest.references.length,2);assert.doesNotMatch(JSON.stringify(rows[0].referenceManifest),/https:|signature|base64/);assert.equal(rows[0].model,h.calls[0].model);assert.equal(h.charges[0].cost,rows[0].upstreamCostCny*2);
 const ledger=(await h.db.collection('bf_model_calls').get()).data.find(r=>r.kind==='image');assert.equal(ledger.inputImages,2);
});
test('identical replay and rotated signatures reuse one result; changed roles or removal conflict before provider',async()=>{
 const h=await fixture(),input=body(h);await h.request('/image',input);const replay=await h.request('/image',{...input,image:input.image.replace('old','rotated')});assert.equal(replay.status,200);assert.equal(replay.body.cached,true);assert.equal(replay.body.cost,0);
 const changed=structuredClone(input);changed.structured.image_references.items[0].role='另一用途';assert.equal((await h.request('/image',changed)).status,409);
 assert.equal((await h.request('/image',{...input,prompt:'换成另一项任务'})).status,409);
 assert.equal((await h.request('/image',{...input,structured:{}})).status,409);assert.equal(h.calls.length,1);assert.equal(h.charges.length,1);
});
test('missing, foreign, deleted or unsupported references cannot trigger supplier calls or charges',async()=>{
 for(const mutate of [b=>delete b.image,b=>b.image=b.image.replace('/user/','/foreign/'),b=>b.structured.preserve_assets=[{reference_index:2}],b=>b.task_kind='series']){
  const h=await fixture(),input=body(h);mutate(input);assert.equal((await h.request('/image',input)).status,422);assert.equal(h.calls.length,0);assert.equal(h.charges.length,0);
 }
 const h=await fixture();await h.db.collection('bf_assets').doc(h.currentId).update({state:'deleted'});assert.equal((await h.request('/image',body(h))).status,422);assert.equal(h.calls.length,0);
 assert.equal((await (await fixture()).request('/image',body(h),'B')).status,422);
});
test('concurrent mixed requests have exactly one supplier execution and a conflicting selection cannot win',async()=>{
 const h=await fixture(),input=body(h),other=structuredClone(input);other.structured.image_references.items[0].role='不同素材角色';
 const r=await Promise.all([h.request('/image',input),h.request('/image',input),h.request('/image',other)]);assert.equal(h.calls.length,1);assert.equal(h.charges.length,1);assert.ok(r.some(r=>r.status===409));assert.ok(r.some(r=>r.status===200));
});
test('low remaining budget and feature-off reject before new supplier work; legacy input still works',async()=>{
 const h=await fixture();h.setRemaining(.01);assert.equal((await h.request('/image',body(h))).status,402);assert.equal(h.calls.length,0);
 const off=await fixture();vm.runInContext('RT.IMAGE_MIXED_REFERENCES_POLICY="{}"',off.context);assert.equal((await off.request('/image',body(off))).status,422);assert.equal(off.calls.length,0);
 const legacy=await off.request('/image',{requestId:'ordinary',prompt:'画一只小狗',size:'1536x1536'});assert.equal(legacy.status,200);assert.equal(off.calls.length,1);assert.equal(off.calls[0].image,undefined);
});
test('multiple current slots retain their order and roles before the historical original',async()=>{
 const h=await fixture(),sha256=hash('second-current'),id=hash('A:'+sha256).slice(0,40),cloudPath='user/'+hash('A').slice(0,24)+'/assets/'+sha256+'.png';
 await h.db.collection('bf_assets').doc(id).set({accountId:'A',state:'ready',privateACL:true,sha256,mime:'image/png',byteCount:24,cloudPath,fileID:'cloud://env.bucket/'+cloudPath});
 const input=body(h);input.image=[h.currentUrl,'https://bucket.cos.ap-shanghai.myqcloud.com/'+cloudPath+'?rotated'];input.reference_roles=['当前底图','当前产品'];
 const r=await h.request('/image',input);assert.equal(r.status,200);assert.equal(h.calls[0].image.length,3);assert.match(h.calls[0].image[1],new RegExp(sha256));assert.match(h.calls[0].image[2],/image-1/);assert.match(h.calls[0].prompt,/当前产品/);
});
test('definitive provider rejection permits only the same reference selection to retry and re-sign',async()=>{
 const h=await fixture(),input=body(h);h.failNext();const failed=await h.request('/image',input);assert.equal(failed.status,502);assert.equal(h.charges.length,0);
 const changed=structuredClone(input);changed.structured.image_references.items[0].role='不同用途';assert.equal((await h.request('/image',changed)).status,409);assert.equal(h.calls.length,1);
 const recovered=await h.request('/image',input);assert.equal(recovered.status,200);assert.equal(h.calls.length,2);assert.notEqual(h.calls[0].image[0],h.calls[1].image[0]);assert.equal(h.charges.length,1);
});
