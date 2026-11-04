"use strict";
const test=require('node:test'),assert=require('node:assert/strict'),crypto=require('node:crypto');
const {currentPointer,prepareMixedReferenceInput}=require('../cloudfunctions/shared/image-reference-merge');
const {createImageReferenceStore}=require('../cloudfunctions/shared/image-reference-store');
const digest=s=>crypto.createHash('sha256').update(s).digest('hex');
const owner='A',uuid='B665E22F-B174-4C75-931A-962EC43FE3E1';
function asset(owner,name){const sha256=digest(name),cloudPath='user/'+digest(owner).slice(0,24)+'/assets/'+sha256+'.png';return {_id:digest(owner+':'+sha256).slice(0,40),accountId:owner,state:'ready',sha256,cloudPath,mime:'image/png',byteCount:240,fileID:'cloud://env.bucket/'+cloudPath};}
const descriptor=r=>({id:r._id,sha256:r.sha256,mime:r.mime,byteCount:r.byteCount});
function fixture(){
 const base=asset(owner,'current'),historical=asset(owner,'historical'),rows=new Map([[base._id,base],[historical._id,historical]]);let signs=0,epoch=0,reads=0;
 const library={accountId:owner,kind:'file',refId:uuid,deleted:false,payload:{id:uuid,categoryRaw:'image',asset:descriptor(historical)}};
 const store=createImageReferenceStore({readFile:async()=>library,assetStore:{
  async verifyReferences(account,refs){for(const ref of refs){const row=rows.get(ref.id);if(!row||row.accountId!==account||row.state!=='ready')throw Error('ASSET_NOT_FOUND');assert.deepEqual(descriptor(row),ref);}},
  async sign(account,ids){signs++;return ids.map(id=>({id,url:'https://private.example/'+id+'?epoch='+(++epoch)}));}
 }});
 const url='https://bucket.cos.ap-shanghai.myqcloud.com/'+base.cloudPath+'?q-signature=old';
 const structured={image_references:{version:1,mode:'append',items:[{kind:'library',id:uuid,role:'企业Logo'}]}};
 const options={store,owner,structured,image:url,readAsset:async(account,id)=>{reads++;return rows.get(id);}};
 return {base,historical,rows,store,url,library,structured,options,get signs(){return signs;},get reads(){return reads;}};
}
test('current account URL and historical original merge in order, with generic current role and no persisted URL',async()=>{
 const f=fixture(),result=await prepareMixedReferenceInput(f.options);
 assert.deepEqual(result.referenceManifest.references.map(r=>r.asset.id),[f.base._id,f.historical._id]);assert.deepEqual(result.referenceManifest.references.map(r=>r.source.role),['当前底图','企业Logo']);
 assert.doesNotMatch(JSON.stringify(result),/https:|signature|base64|data:image/);assert.equal(f.signs,0);
 const one=await f.store.sign(owner,result.referenceManifest),two=await f.store.sign(owner,result.referenceManifest);assert.notEqual(one[0].url,two[0].url);assert.equal(f.signs,2);
});
test('expired or rotated URL query does not change identity or idempotency fingerprint',async()=>{
 const f=fixture(),one=await prepareMixedReferenceInput(f.options),two=await prepareMixedReferenceInput({...f.options,image:f.url.replace('old','new-expired')});assert.deepEqual(one,two);
 const changed=await prepareMixedReferenceInput({...f.options,referenceRoles:['本次海报']});assert.notEqual(changed.referenceFingerprint,one.referenceFingerprint);
});
test('foreign owner URL and a faulty cross-account lookup cannot grant access',async()=>{
 const f=fixture();await assert.rejects(prepareMixedReferenceInput({...f.options,owner:'B'}),/UNAVAILABLE/);assert.equal(f.reads,0);
 for(const patch of [{accountId:'B'},{_id:'f'.repeat(40)},{state:'pending'},{cloudPath:'other'},{mime:'application/pdf'},{fileID:'cloud://else/wrong'}]){
  await assert.rejects(prepareMixedReferenceInput({...f.options,readAsset:async()=>({...f.base,...patch})}),/UNAVAILABLE/);
 }assert.equal(f.signs,0);
});
test('URL schemes, untrusted hosts, credentials, fragments and alternate path encodings are rejected without downloads',()=>{
 const f=fixture();for(const bad of [f.url.replace('https:','http:'),f.url.replace('bucket.cos.ap-shanghai.myqcloud.com','evil.example'),f.url.replace('https://','https://name:secret@'),f.url+'#frag',f.url.replace('/user/','/%75ser/'),f.url.replace('.com/','.com:8443/'),'data:image/png;base64,YQ=='])assert.throws(()=>currentPointer(owner,bad));
 assert.equal(f.signs,0);
});
test('append requires a durable current base, while absent metadata leaves legacy image requests untouched',async()=>{
 const f=fixture();await assert.rejects(prepareMixedReferenceInput({...f.options,image:undefined}),/CURRENT_REQUIRED/);
 assert.deepEqual(await prepareMixedReferenceInput({...f.options,structured:{},image:'legacy-inline'}),{referenceManifest:null,referenceFingerprint:''});assert.equal(f.reads,0);
});
test('replace cannot discard a supplied current base, and keeps historical-only behavior when no base exists',async()=>{
 const f=fixture(),structured={image_references:{...f.structured.image_references,mode:'replace'}};
 await assert.rejects(prepareMixedReferenceInput({...f.options,structured}),/CONFLICT/);
 const result=await prepareMixedReferenceInput({...f.options,structured,image:undefined});assert.deepEqual(result.referenceManifest.references.map(r=>r.asset.id),[f.historical._id]);assert.equal(f.reads,0);
});
test('count and role mismatch fail before supplier signing; duplicate resolved originals are rejected',async()=>{
 const f=fixture();await assert.rejects(prepareMixedReferenceInput({...f.options,image:[f.url,f.url,f.url,f.url]}),/LIMIT/);assert.equal(f.reads,0);
 await assert.rejects(prepareMixedReferenceInput({...f.options,referenceRoles:['底图','人物']}),/ROLES_INVALID/);
 f.library.payload.asset=descriptor(f.base);await assert.rejects(prepareMixedReferenceInput(f.options),/DUPLICATE/);assert.equal(f.signs,0);
});
test('saved manifest does not permit deleted or replaced original on later retry',async()=>{
 for(const mutate of [f=>f.rows.get(f.base._id).state='deleted',f=>f.library.deleted=true,f=>f.library.payload.asset=descriptor(f.base)]){
  const f=fixture(),result=await prepareMixedReferenceInput(f.options);mutate(f);await assert.rejects(f.store.sign(owner,result.referenceManifest));assert.equal(f.signs,0);
 }
});
test('storage failures are distinguishable from invalid originals without returning unsafe error messages',()=>{
 const {referenceFailure,bindReferenceRequest}=require('../cloudfunctions/shared/image-reference-merge');
 assert.equal(referenceFailure(Error('ASSET_NOT_FOUND')).status,422);const f=referenceFailure(Error('secret-url://token'));assert.equal(f.status,503);assert.doesNotMatch(JSON.stringify(f),/secret-url|token/);
 assert.equal(bindReferenceRequest('fp',{structured:{a:1,b:2},prompt:'同一图'}),bindReferenceRequest('fp',{prompt:'同一图',structured:{b:2,a:1}}));
 assert.notEqual(bindReferenceRequest('fp',{prompt:'原图'}),bindReferenceRequest('fp',{prompt:'改图'}));
});
