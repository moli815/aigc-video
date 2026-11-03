"use strict";
// Isolated live acceptance: two account-owned synced originals, one paid child.
// Keeps normal vendor/usage audit records; removes only this test's accounts/assets.
const fs=require("node:fs"),path=require("node:path"),crypto=require("node:crypto"),assert=require("node:assert/strict");
const sdk=require(path.resolve("cloudfunctions/bf-api/node_modules/@cloudbase/node-sdk"));
const credentials=JSON.parse(fs.readFileSync(path.join(process.env.USERPROFILE,".config/.cloudbase/auth.json"),"utf8")).credential;
const app=sdk.init({env:"xmy-test-d5g8c0xcifcefcfd5",region:"ap-shanghai",secretId:credentials.tmpSecretId,secretKey:credentials.tmpSecretKey,sessionToken:credentials.tmpToken}),db=app.database();
const {createAssetStore}=require("../cloudfunctions/shared/asset-store"),{createSyncService}=require("../cloudfunctions/bf-api/domains/sync-v2");
const store=createAssetStore({db,app}),sync=createSyncService({db,assetStore:store});
const host="https://xmy-test-d5g8c0xcifcefcfd5-1449098021.ap-shanghai.app.tcloudbase.com",folder="outputs/series-reference-20261104";
const prefix="series-ref-"+crypto.randomBytes(5).toString("hex"),accounts=[],ids=[crypto.randomUUID().toUpperCase(),crypto.randomUUID().toUpperCase()];
let taskId="",ownerToken="",paidPending=false;const report={at:new Date().toISOString(),checks:[],imagesRequested:0};
function check(name,fields={}){const row={name,...fields};report.checks.push(row);console.log(JSON.stringify(row));}
async function request(route,body,token,expected=200){const r=await fetch(host+route,{method:body===undefined?"GET":"POST",headers:{"Content-Type":"application/json",...(token?{Authorization:"Bearer "+token}:{})},body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(360000)});const text=await r.text();assert.equal(r.status,expected,route+" HTTP "+r.status);return JSON.parse(text);}
async function account(suffix){const id=prefix+suffix,salt=crypto.randomBytes(16).toString("hex"),password=crypto.randomBytes(24).toString("hex"),now=new Date();
 await db.collection("bf_accounts").doc(id).set({username:id,displayName:"组图素材隔离验证",status:"active",tier:"ultra",expiresAt:new Date(Date.now()+3600000),createdAt:now,cycleAnchorAt:now,quotaOverrideCny:10,pwv:0,sv:0,chatUsedCny:0,imageUsedCny:0,passwordHash:"scrypt$"+salt+"$"+crypto.scryptSync(password,salt,64).toString("hex")});accounts.push(id);
 return {id,token:(await request("/api/login",{username:id,password})).token};
}
(async()=>{try{
 for(const p of ["/api/health","/img/ping"])await request(p);
 const a=await account("-a"),b=await account("-b");ownerToken=a.token;
 const fixtureFiles=["outputs/design-policy-20261103/coffee-native-pro.image","outputs/review-20261103/server-repair-pro.image"];
 const descriptors=[];
 for(let i=0;i<fixtureFiles.length;i++){
  const bytes=fs.readFileSync(fixtureFiles[i]),mime=bytes[0]===137?"image/png":"image/jpeg";
  const asset=await store.archive(a.id,bytes,mime);descriptors.push(asset);
  await sync.push(a.id,[{kind:"file",refId:ids[i],payload:{id:ids[i],name:"已同步素材"+(i+1),categoryRaw:"image",ext:mime==="image/png"?"png":"jpg",asset}}]);
 }
 check("two original images privately archived and synced",{count:descriptors.length});
 const tool={type:"function",function:{name:"image_series",description:"生成2至4张关联图片",parameters:{type:"object",properties:{prompt:{type:"string"},count:{type:"integer"},quality_tier:{type:"string",enum:["fast","high"]}},required:["prompt"]}}};
 const messages=[{role:"user",content:"我要用之前保存的两张原图制作关联的商业活动拼贴画。请先检索素材。"},
  {role:"assistant",tool_calls:[{id:"call_recall_fixture",type:"function",function:{name:"recall_history",arguments:JSON.stringify({queries:["已同步素材"],include_images:false})}}]},
  {role:"tool",tool_call_id:"call_recall_fixture",content:ids.map((id,i)=>"图片ID："+id+"；名称：已同步素材"+(i+1)).join("\n")},
  {role:"user",content:"使用刚才检索的两张原图做2张不同构图的商业拼贴画。第一张提供底图氛围和主要主体，第二张作为另一主题素材融合进去；两张里的主体都要出现，保持各自外观特征，统一自然光与材质。不要任何文字、水印或标语，使用Pro。直接生成，不要只提供方案。"}];
 const planned=await request("/api/chat",{stream:false,chatMode:"standard",max_tokens:4500,messages,tools:[tool],tool_choice:{type:"function",function:{name:"image_series"}}},a.token);
 const args=JSON.parse(planned.choices?.[0]?.message?.tool_calls?.[0]?.function?.arguments||"{}");
 assert.equal(args.count,2);assert.deepEqual(args.structured?.image_references?.items?.map(i=>i.id),ids);assert.equal(args.structured.image_references.mode,"replace");
 fs.writeFileSync(folder+"/live-tool-arguments.json",JSON.stringify(args,null,2));check("real model uses metadata despite shipped schema lacking structured",{references:2});
 const rid=crypto.randomUUID(),body={requestId:rid,prompt:args.prompt,requested_count:2,size:"1536x1536",quality_tier:args.quality_tier,structured:args.structured};
 const started=await request("/img/series/start",body,a.token);taskId=started.taskId;assert.ok(taskId);
 const saved=(await db.collection("bf_image_series").doc(taskId).get()).data[0];assert.equal(saved.referenceManifest.references.length,2);assert.doesNotMatch(JSON.stringify(saved.referenceManifest),/https:|base64/);
 const replay=await request("/img/series/start",body,a.token);assert.equal(replay.taskId,taskId);
 const changed=structuredClone(body);changed.structured.image_references.items.reverse();await request("/img/series/start",changed,a.token,409);
 await request("/img/series/start",body,b.token,422);await request("/img/series/step",{taskId,index:1},b.token,403);
 const pre=(await db.collection("bf_model_calls").where({accountId:a.id,kind:"image"}).get()).data;assert.equal(pre.length,0);
 check("start replay stable, changed references and foreign account rejected without image call");
 report.imagesRequested=1;paidPending=true;const start=Date.now();
 const step=await request("/img/series/step",{taskId,index:1},a.token);paidPending=false;
 assert.equal(step.succeeded,1);const item=step.items.find(i=>i.index===1);assert.ok(item.ok);
 const media=await fetch(item.url,{signal:AbortSignal.timeout(30000)});assert.equal(media.status,200);fs.writeFileSync(folder+"/two-reference-result.image",Buffer.from(await media.arrayBuffer()));
 const ledger=(await db.collection("bf_model_calls").where({accountId:a.id,kind:"image"}).get()).data;assert.equal(ledger.length,1);assert.equal(ledger[0].inputImages,2);assert.equal(ledger[0].status,"succeeded");
 check("one real child received two image inputs",{ms:Date.now()-start,model:item.model,customerChargeCny:item.cost,orderId:ledger[0].orderId,supplierCostEstimateCny:ledger[0].supplierCostEstimateCny});
 await request("/img/series/step",{taskId,index:1},a.token);const retry=await request("/img/series/retry",{requestId:rid,indices:[1]},a.token);assert.deepEqual(retry.retriedIndices,[]);
 assert.equal((await db.collection("bf_model_calls").where({accountId:a.id,kind:"image"}).get()).data.length,1);
 await request("/img/series/cancel",{taskId},a.token);check("successful child replay and legacy retry endpoint add no image call");
 report.ok=true;
}catch(e){report.ok=false;report.error=String(e.message).replace(/https?:\/\/\S+/g,"[url]").slice(0,250);console.error(report.error);process.exitCode=1;}
finally{
 if(paidPending){report.cleanupDeferred=true;report.deferredAccountIds=accounts;report.taskId=taskId;}
 else try{
  if(taskId&&ownerToken)await request("/img/series/cancel",{taskId},ownerToken);
  for(const owner of accounts){
   for(const collection of ["bf_assets","bf_sync_v2","bf_sync_meta","bf_image_series","bf_quota_reservations"]){
    const rows=(await db.collection(collection).where({accountId:owner}).limit(100).get()).data||[];
    for(const row of rows){assert.equal(row.accountId,owner);if(collection==="bf_assets"&&row.fileID)await app.deleteFile({fileList:[row.fileID]});await db.collection(collection).doc(row._id).remove();}
   }
   await db.collection("bf_accounts").doc(owner).remove();
  }
  report.temporaryAccountsAndAssetsDeleted=true;
 }catch(e){report.cleanupError=String(e.message).slice(0,120);process.exitCode=1;}
 fs.writeFileSync(folder+"/live-verification.json",JSON.stringify(report,null,2));
}})();
