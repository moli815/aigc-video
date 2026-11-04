"use strict";
// Read existing server credentials in memory. Never serialize or print secrets.
const fs=require('node:fs'),path=require('node:path');
const sdk=require(path.resolve('outputs/commercial-text-repair-20261104/ops-tools/node_modules/tencentcloud-sdk-nodejs-scf'));
const root=path.resolve('outputs/qwen-image-migration-20261105');fs.mkdirSync(root,{recursive:true});
const credential=JSON.parse(fs.readFileSync(path.join(process.env.USERPROFILE,'.config/.cloudbase/auth.json'),'utf8')).credential;
const client=new sdk.scf.v20180416.Client({credential:{secretId:credential.tmpSecretId,secretKey:credential.tmpSecretKey,token:credential.tmpToken},region:'ap-shanghai',profile:{httpProfile:{endpoint:'scf.tencentcloudapi.com',reqTimeout:180}}});
(async()=>{
 const api=await client.GetFunction({FunctionName:'bf-api',Namespace:'xmy-test-d5g8c0xcifcefcfd5'});
 const image=await client.GetFunction({FunctionName:'bf-image',Namespace:'xmy-test-d5g8c0xcifcefcfd5'});
 const env=Object.fromEntries((api.Environment?.Variables||[]).map(x=>[x.Key,x.Value]));
 const key=env.DASHSCOPE_API_KEY||env.CHAT_API_KEY;
 const report={time:new Date().toISOString(),functions:[api,image].map(x=>({name:x.FunctionName,status:x.Status,modified:x.ModTime,install:x.InstallDependency})),hasExistingDashscopeKey:!!key,probes:[]};
 if(!key)throw Error('NO_EXISTING_DASHSCOPE_KEY');
 // Invalid image count is an intentional no-generation authentication/model probe.
 for(const model of ['qwen-image-3.0-pro','qwen-image-3.0']){
  const r=await fetch('https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation',{method:'POST',headers:{Authorization:'Bearer '+key,'Content-Type':'application/json'},body:JSON.stringify({model,input:{messages:[{role:'user',content:[{text:'接口可用性检查，不生成图片'}]}]},parameters:{n:0,size:'1024*1024'}}),signal:AbortSignal.timeout(30000)});
  const j=await r.json();report.probes.push({model,http:r.status,code:j.code||j.error?.code||'',message:String(j.message||j.error?.message||'').replace(/https?:\/\/\S+/g,'[url]').slice(0,180),requestId:j.request_id||r.headers.get('x-request-id')||'',generated:!!j.output});
 }
 fs.writeFileSync(path.join(root,'availability.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report));
})().catch(e=>{console.error(e.code||e.name,String(e.message||'').replace(/https?:\/\/\S+/g,'[url]').slice(0,180));process.exitCode=1;});
