"use strict";
// Isolated local HTTP integration fixture. No cloud credentials, real platform,
// customer DB, provider request or persistent key is accessible through this hook.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),Module=require('node:module'),http=require('node:http');
const root=path.resolve(__dirname,'..'),assets=new Map(),files=new Map(),dbState=new Map(),hash=b=>crypto.createHash('sha256').update(b).digest('hex');
const account='native_http_member',secret='ephemeral-in-memory-native-http-fixture',model='doubao-seedream-5-5-261028',calls={primary:0,decompose:0,vision:0};
const clone=x=>structuredClone(x);let queue=Promise.resolve(),differentCanvas=false,providerRejected=false;
function locked(fn){const p=queue.then(fn);queue=p.catch(()=>{});return p;}
function coll(name,tx){const target=()=>tx||dbState;
 const doc=id=>({get:async()=>({data:tx?(target().get(name+':'+id)||null):target().has(name+':'+id)?[clone(target().get(name+':'+id))]:[]}),
  set:async value=>{const fn=()=>target().set(name+':'+id,{_id:id,...clone(value)});return tx?fn():locked(fn);},
  update:async patch=>{const fn=()=>{const key=name+':'+id,row=target().get(key);if(!row)throw Error('FIXTURE_DOC_MISSING');for(const [k,v]of Object.entries(patch))row[k]=v&&v.__inc!==undefined?Number(row[k]||0)+v.__inc:clone(v);return{updated:1};};return tx?fn():locked(fn);},remove:async()=>{target().delete(name+':'+id);return{deleted:1};}});
 const query=(where={},limit=100)=>({where:x=>query(x,limit),limit:n=>query(where,n),orderBy:()=>query(where,limit),get:async()=>({data:[...target()].filter(([k,v])=>k.startsWith(name+':')&&Object.entries(where).every(([p,w])=>v[p]===w)).slice(0,limit).map(([,v])=>clone(v))})});
 return{doc,where:x=>query(x),limit:n=>query({},n),get:()=>query().get(),add:async value=>{const id=value._id||crypto.randomUUID();if(target().has(name+':'+id))throw Error('EXISTS');await doc(id).set(value);return{id};}};
}
const db={collection:n=>coll(n),command:{inc:n=>({__inc:n})},createCollection:async()=>{},runTransaction:fn=>locked(async()=>{const staged=clone(dbState),out=await fn({collection:n=>coll(n,staged)});dbState.clear();for(const [k,v]of staged)dbState.set(k,v);return out;})};
const fontRoot=path.join(root,'outputs/commercial-text-repair-20261104/fonts'),fonts=[400,700].map(w=>{const bytes=fs.readFileSync(path.join(fontRoot,'NotoSansCJKsc-'+(w===400?'Regular':'Bold')+'.otf')),id='cloud://fixture/font'+w;files.set('https://fixture.myqcloud.com/font'+w,bytes);return{fileId:id,sha256:hash(bytes),weight:w};});
const policy={enabled:true,fonts,nativeCopy:{enabled:true,accountIds:[account],maxOutputs:3}};
if(process.env.FIXTURE_NATIVE_MIN_CHARS)policy.nativeCopy.minChars=Number(process.env.FIXTURE_NATIVE_MIN_CHARS);
const dense605=process.env.FIXTURE_DENSE_605==='1',layerRoot=path.join(root,dense605?'outputs/dense-text-continuation-20261117/layers':'outputs/poster-adaptation-20261116/native-55');
if(dense605)policy.nativeCopy.maxOutputs=2;
if(process.env.FIXTURE_PRODUCTION_IMAGE_MODE==='1'){policy.designEngine='poster';policy.minChars=420;policy.nativeCommercial=false;policy.nativeCopy.enabled=false;}
if(process.env.FIXTURE_COMPOSITION_MIN_CHARS)policy.minChars=Number(process.env.FIXTURE_COMPOSITION_MIN_CHARS);
dbState.set('bf_config:runtime',{_id:'runtime',data:{IMAGE_COMPOSITION_POLICY:JSON.stringify(policy),IMAGE_MODEL:model,IMAGE_MODEL_PRO:model,IMAGE_ROUTING_MODE:'pro_only',IMAGE_API_KEY:'fixture-only-no-real-key',CHAT_PROVIDER:'qwen',CHAT_MODEL_VISION:'fixture-vision',CHAT_API_KEY:'fixture-only-no-real-key'}});
dbState.set('bf_config:supplier_cost_catalog',{models:{'aliyun-bailian:fixture-vision':{input:1,output:2}}});
dbState.set('bf_accounts:'+account,{_id:account,status:'active',expiresAt:new Date(Date.now()+3600000),chatUsedCny:0,imageUsedCny:0,dayUsedCny:0,weekUsedCny:0,nativeCopyReservedCny:0});
if(process.env.FIXTURE_COST_POLICY==='1'){
 const data=dbState.get('bf_config:runtime').data;
 Object.assign(data,{USAGE_BILLING_MODE:'supplier_cost',USAGE_COST_MULTIPLIER:1,IMAGE_PRICE_MULTIPLIER:1,CHAT_MODEL:'fixture-vision',CHAT_MODEL_STANDARD:'fixture-vision',CHAT_MODEL_PRO:'fixture-vision',CHAT_MODEL_UTILITY:'fixture-vision',CHAT_MODEL_UTILITY_LITE:'fixture-vision',TIERS_OVERRIDE:JSON.stringify({plus:{poolCapCny:80}})});
 Object.assign(dbState.get('bf_accounts:'+account),{tier:'plus',costBudgetPolicy:{version:1,tier:'plus',capCny:80,multiplier:1}});
}
const signed=(owner,id)=>'https://fixture.myqcloud.com/asset/'+id;
const store={verifyReferences:async(owner,list)=>{if(list.some(a=>assets.get(a.id)?.owner!==owner||assets.get(a.id)?.asset.sha256!==a.sha256))throw Error('FIXTURE_FOREIGN_ASSET');},archive:async(owner,bytes,mime)=>{const sha256=hash(bytes),id=hash(owner+':'+sha256).slice(0,40),asset={id,sha256,byteCount:bytes.length,mime};assets.set(id,{owner,asset});files.set(signed(owner,id),bytes);if(process.env.FIXTURE_ARTIFACT_DIR){fs.mkdirSync(process.env.FIXTURE_ARTIFACT_DIR,{recursive:true});fs.writeFileSync(path.join(process.env.FIXTURE_ARTIFACT_DIR,id+'.png'),bytes);}return asset;},sign:async(owner,ids)=>ids.map(id=>{if(assets.get(id)?.owner!==owner)throw Error('FIXTURE_FOREIGN_ASSET');return{id,url:signed(owner,id)};})};
for(const source of JSON.parse(process.env.FIXTURE_OWNED_INPUTS || '[]')){
 const bytes=fs.readFileSync(source),sha256=hash(bytes),id=hash(account+':'+sha256).slice(0,40);
 const cloudPath='user/'+hash(account).slice(0,24)+'/assets/'+sha256+'.png';
 const asset={id,sha256,byteCount:bytes.length,mime:'image/png'};
 dbState.set('bf_assets:'+id,{...asset,_id:id,accountId:account,state:'ready',privateACL:true,cloudPath,fileID:'cloud://fixture/'+cloudPath});
 assets.set(id,{owner:account,asset});files.set(signed(account,id),bytes);
}
const app={database:()=>db,getTempFileURL:async({fileList})=>({fileList:fileList.map(f=>({tempFileURL:'https://fixture.myqcloud.com/'+f.fileID.split('/').at(-1)}))})};
const originalLoad=Module._load;
Module._load=function(name,parent){if(name==='@cloudbase/node-sdk')return{init:()=>app};const mod=originalLoad.apply(this,arguments);if(name==='./commercial-composer' && process.env.FIXTURE_CAPTURE_MANIFEST) return {...mod,compose:async input=>{
 const result=await mod.compose(input);
 fs.writeFileSync(process.env.FIXTURE_CAPTURE_MANIFEST,JSON.stringify(result.manifest));
 return result;
 }};if(/(?:^|\/)shared\/asset-store$/.test(name))return{...mod,createAssetStore:()=>store};return mod;};
const originalFetch=globalThis.fetch;
globalThis.fetch=async(url,options={})=>{
 const address=String(url);if(files.has(address))return new Response(files.get(address),{headers:{'content-type':'image/png'}});
 if(address.startsWith('http://fixture-api/api/me')){const a=dbState.get('bf_accounts:'+account);if(new Date(a.expiresAt).getTime()<Date.now())return Response.json({error:'MEMBERSHIP_EXPIRED',message:'expired'},{status:403});const used=a.chatUsedCny+a.imageUsedCny;return Response.json({ok:true,memberUntil:a.expiresAt,limits:{month:{enabled:true,remainingPct:Math.max(0,(10-used)/10*100)}},usage:{pool:{capCny:10,usedCny:used}}});}
 if(address==='https://ark.cn-beijing.volces.com/api/v3/images/generations'){
  const p=JSON.parse(options.body);if(process.env.FIXTURE_CAPTURE_PROVIDER)fs.writeFileSync(process.env.FIXTURE_CAPTURE_PROVIDER,JSON.stringify({model:p.model,prompt:p.prompt,size:p.size,output_format:p.output_format,...(process.env.FIXTURE_CAPTURE_SOURCE_ORDER?{sourceOrder:(Array.isArray(p.image)?p.image:p.image?[p.image]:[]).map(hash)}:{}),imageCount:Array.isArray(p.image)?p.image.length:p.image?1:0,scope:'actual compiled request against local supplier fixture; no real model call'},null,2));if(p.layer_decomposition){calls.decompose++;if(p.size!=='auto')throw Error('FIXTURE_DECOMPOSITION_MUST_USE_OFFICIAL_AUTO');if(providerRejected)return Response.json({error:{code:'InvalidParameter',message:'fixture definite request rejection'}},{status:400});const r=JSON.parse(fs.readFileSync(path.join(layerRoot,'report.json')));return Response.json({model,usage:r.usage||r.response?.usage,data:r.rows.map(row=>{const url='https://fixture.myqcloud.com/'+row.file;let bytes=fs.readFileSync(path.join(layerRoot,row.file));if(differentCanvas&&row.file==='layer-0.png'){const {PNG}=require('../cloudfunctions/bf-image/node_modules/pngjs');bytes=PNG.sync.write({width:1670,height:2508,data:Buffer.alloc(1670*2508*4,255)});}files.set(url,bytes);return{...row,url};})});}
  calls.primary++;const bytes=fs.readFileSync(process.env.FIXTURE_PRIMARY_IMAGE || path.join(root,dense605?'outputs/server-admin-audit-20261117/dense-copy/followup.png':'outputs/poster-adaptation-20261116/native-55/control-resized.png')),url='https://fixture.myqcloud.com/primary.png';files.set(url,bytes);return Response.json({model,usage:{input_images:0,generated_images:1},data:[{url,size:process.env.FIXTURE_PRIMARY_IMAGE ? p.size : dense605?'1584x2816':'1672x2508'}]});
 }
 if(address.includes('dashscope.aliyuncs.com/compatible-mode/v1/chat/completions')){calls.vision++;throw Error('UNEXPECTED_FIXTURE_VISION');}
 if(address.startsWith('http://127.0.0.1:'))return originalFetch(url,options);
 throw Error('FIXTURE_NETWORK_FORBIDDEN');
};
process.env.TOKEN_SECRET=secret;process.env.IMAGE_API_KEY='fixture-only-no-real-key';process.env.BF_API_BASE='http://fixture-api/api';process.env.TCB_ENV='fixture-local';
const oldCreate=http.createServer.bind(http);http.createServer=(listener)=>oldCreate((req,res)=>{
 if(req.url==='/__fixture/different-canvas'){differentCanvas=true;res.end('{}');return;}
 if(req.url==='/__fixture/provider-rejected'){providerRejected=true;res.end('{}');return;}
 if(req.url==='/__fixture/provider-restored'){providerRejected=false;differentCanvas=false;res.end('{}');return;}
 if(req.url.startsWith('/__fixture/account/')){const mode=req.url.split('/').at(-1),a=dbState.get('bf_accounts:'+account);if(!['expired','empty','active'].includes(mode)){res.writeHead(400);res.end('{}');return;}a.expiresAt=new Date(Date.now()+(mode==='expired'?-3600000:3600000));a.chatUsedCny=mode==='empty'?10:0;res.end('{}');return;}
 if(req.url==='/__fixture/state'){const a=dbState.get('bf_accounts:'+account);res.setHeader('Content-Type','application/json');res.end(JSON.stringify({calls,account:a,jobs:[...dbState].filter(([k])=>k.startsWith('bf_image_jobs:')).map(([,v])=>({state:v.state,copyPhase:v.copyPhase,costCommitted:v.costCommitted,diagnostic:v.diagnostic||v.copyDiagnostic,costs:v.costs})),events:[...dbState].filter(([k])=>k.startsWith('bf_billing_events:')).map(([,v])=>v)}));return;}
 return listener(req,res);
});
const listen=http.Server.prototype.listen;http.Server.prototype.listen=function(port,...args){return listen.call(this,Number(process.env.NATIVE_FIXTURE_PORT||19173),...args);};
