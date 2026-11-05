"use strict";
const fs=require('fs'),path=require('path'),crypto=require('crypto');
const c=JSON.parse(fs.readFileSync(path.join(process.env.USERPROFILE,'.config/.cloudbase/auth.json'),'utf8')).credential;
const sdk=require(path.resolve('outputs/commercial-text-repair-20261104/ops-tools/node_modules/tencentcloud-sdk-nodejs-scf'));
const client=new sdk.scf.v20180416.Client({credential:{secretId:c.tmpSecretId,secretKey:c.tmpSecretKey,token:c.tmpToken},region:'ap-shanghai'});
const app=require('../cloudfunctions/bf-api/node_modules/@cloudbase/node-sdk').init({env:'xmy-test-d5g8c0xcifcefcfd5',region:'ap-shanghai',secretId:c.tmpSecretId,secretKey:c.tmpSecretKey,sessionToken:c.tmpToken}),db=app.database();
const root=path.resolve('outputs/deepseek-platform-migration-20261105');fs.mkdirSync(root,{recursive:true});
const report={at:new Date().toISOString(),keyMatches:[],deepseekCredentialSlots:[],calls:{},targetCalls:[],functions:[]},fingerprints=new Set(['d13b4c4d77d5a188']);
const fp=v=>crypto.createHash('sha256').update('Bearer '+v).digest('hex').slice(0,16);
function inspect(value,location,depth=0){if(depth>12||value==null)return;if(typeof value==='string'){
 if(/^sk-340ea[\w-]*9e2a$/.test(value.trim())){fingerprints.add(fp(value.trim()));report.keyMatches.push({location,masked:'sk-340ea…9e2a',credentialFingerprint:fp(value.trim())});}
 if(value.trim().startsWith('{')||value.trim().startsWith('['))try{inspect(JSON.parse(value),location+'.json',depth+1);}catch{}
 }else if(typeof value==='object')for(const [k,v]of Object.entries(value)){if(/DEEPSEEK.*KEY/i.test(k)&&typeof v==='string'&&v.length>12)report.deepseekCredentialSlots.push({location:location+'.'+k,credentialFingerprint:fp(v)});inspect(v,location+'.'+k,depth+1);}}
(async()=>{
 const listed=await client.ListFunctions({Namespace:'xmy-test-d5g8c0xcifcefcfd5',Limit:100});
 for(const fn of listed.Functions||[]){const d=await client.GetFunction({FunctionName:fn.FunctionName,Namespace:'xmy-test-d5g8c0xcifcefcfd5'});report.functions.push({name:fn.FunctionName,modified:d.ModTime,status:d.Status});inspect(Object.fromEntries((d.Environment?.Variables||[]).map(x=>[x.Key,x.Value])),'env.'+fn.FunctionName);}
 const docs=(await db.collection('bf_config').limit(100).get()).data||[];for(const d of docs)inspect(d,'bf_config.'+d._id);
 let scanned=0;for(let offset=0;offset<5000;offset+=100){const rows=(await db.collection('bf_model_calls').orderBy('startedAt','desc').skip(offset).limit(100).get()).data||[];for(const r of rows){scanned++;const k=[r.provider,r.kind,r.model,r.status].join('|');report.calls[k]=(report.calls[k]||0)+1;if(fingerprints.has(r.credentialFingerprint))report.targetCalls.push({callId:r._id,orderId:r.orderId,source:r.source,endpoint:r.endpoint,provider:r.provider,model:r.model,kind:r.kind,status:r.status,startedAt:r.startedAt,inputTokens:r.inputTokens,outputTokens:r.outputTokens,supplierEstimateCny:r.supplierCostEstimateCny});}if(rows.length<100)break;}
 report.scannedCalls=scanned;fs.writeFileSync(path.join(root,'key-origin-audit.json'),JSON.stringify(report,null,2));console.log(JSON.stringify({keyMatches:report.keyMatches,deepseekCredentialSlots:report.deepseekCredentialSlots,scannedCalls:scanned,targetCallCount:report.targetCalls.length,targetCallKinds:[...new Set(report.targetCalls.map(x=>x.provider+'/'+x.kind+'/'+x.model))],allCallGroups:report.calls,functions:report.functions}));
})().catch(e=>{console.error(e.code||e.name);process.exitCode=1;});
