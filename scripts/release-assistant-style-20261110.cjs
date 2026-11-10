"use strict";
// Narrow release: template/gating fixes only. The experimental style prompt stays OFF.
const fs=require('fs'),path=require('path'),crypto=require('crypto'),cp=require('child_process');
const folder=path.resolve('outputs/assistant-style-20261110');
const c=JSON.parse(fs.readFileSync(path.join(process.env.USERPROFILE,'.config/.cloudbase/auth.json'),'utf8')).credential;
const sdk=require('../outputs/commercial-text-repair-20261104/ops-tools/node_modules/tencentcloud-sdk-nodejs-scf');
const scf=new sdk.scf.v20180416.Client({credential:{secretId:c.tmpSecretId,secretKey:c.tmpSecretKey,token:c.tmpToken},region:'ap-shanghai',profile:{httpProfile:{reqTimeout:180}}});
const db=require('../cloudfunctions/bf-api/node_modules/@cloudbase/node-sdk').init({env:'xmy-test-d5g8c0xcifcefcfd5',region:'ap-shanghai',secretId:c.tmpSecretId,secretKey:c.tmpSecretKey,sessionToken:c.tmpToken}).database();
const one=r=>Array.isArray(r.data)?r.data[0]:r.data,hash=x=>crypto.createHash('sha256').update(JSON.stringify(x)).digest('hex');
const {tuneExpertCatalog}=require('../cloudfunctions/bf-api/assistant-style-policy');
(async()=>{
 const ns='xmy-test-d5g8c0xcifcefcfd5',gate=JSON.parse(fs.readFileSync(path.join(folder,'artifact-gate.json'),'utf8'));
 if(!gate.ok||gate.dependencyChanges.length)throw Error('ARTIFACT_GATE_FAILED');
 const runtime=one(await db.collection('bf_config').doc('runtime').get());let policy={};try{policy=JSON.parse(runtime.data.CHAT_STYLE_POLICY||'{}');}catch{throw Error('INVALID_EXISTING_POLICY');}
 if(policy.enabled===true)throw Error('EXPERIMENT_ALREADY_ENABLED');
 const original=one(await db.collection('bf_config').doc('experts').get()),nextExperts=tuneExpertCatalog(original.experts);
 const backup={at:new Date(),version:original.version,seedHash:original.seedHash,updatedAt:original.updatedAt,
  policyPresent:Object.hasOwn(runtime.data,'CHAT_STYLE_POLICY'),policy:runtime.data.CHAT_STYLE_POLICY||null,
  experts:original.experts.filter(e=>['general','short_video'].includes(e.id)),
  unchangedExpertsHash:hash(original.experts.filter(e=>!['general','short_video'].includes(e.id)))};
 if(!process.argv.includes('--apply')){console.log(JSON.stringify({mode:'preview',experts:backup.experts.map(e=>e.id),candidateStyleEnabled:false}));return;}
 fs.writeFileSync(path.join(folder,'config-before-'+Date.now()+'.json'),JSON.stringify(backup,null,2));
 const current=await scf.GetFunction({FunctionName:'bf-api',Namespace:ns});
 const audited=JSON.parse(fs.readFileSync(path.join(folder,'audit.json'),'utf8')).function;
 if(current.Status!=='Active'||current.ModTime!==audited.modified)throw Error('BASELINE_CHANGED');
 await scf.UpdateFunctionCode({FunctionName:'bf-api',Namespace:ns,ZipFile:fs.readFileSync(path.join(folder,'candidate-api.zip')).toString('base64'),InstallDependency:'FALSE',CodeSource:'ZipFile'});
 let fn;for(let i=0;i<30;i++){await new Promise(r=>setTimeout(r,2000));fn=await scf.GetFunction({FunctionName:'bf-api',Namespace:ns});if(fn.Status==='Active')break;if(fn.Status==='UpdateFailed')throw Error('FUNCTION_UPDATE_FAILED');}
 if(fn.Status!=='Active'||fn.InstallDependency!=='FALSE')throw Error('FUNCTION_NOT_READY');
 const address=await scf.GetFunctionAddress({FunctionName:'bf-api',Namespace:ns});const response=await fetch(address.Url);if(!response.ok)throw Error('CODE_DOWNLOAD_FAILED');
 fs.writeFileSync(path.join(folder,'online-api.zip'),Buffer.from(await response.arrayBuffer()));
 cp.execFileSync('python',['scripts/check-function-artifact.py',path.join(folder,'candidate-api.zip'),path.join(folder,'online-api.zip'),'--output',path.join(folder,'online-artifact-check.json')],{stdio:'pipe'});
 const updated=await db.runTransaction(async tx=>{
  const ref=tx.collection('bf_config').doc('experts'),live=one(await ref.get());
  const rtRef=tx.collection('bf_config').doc('runtime'),rt=one(await rtRef.get());
  if(hash(live.experts)!==hash(original.experts)||live.version!==original.version)throw Error('EXPERTS_CHANGED');
  let p={};try{p=JSON.parse(rt.data.CHAT_STYLE_POLICY||'{}');}catch{throw Error('POLICY_CHANGED');}if(p.enabled===true)throw Error('POLICY_CHANGED');
  const at=new Date(),version=Math.max(4,Number(live.version)||0)+1;
  await ref.update({experts:nextExperts,version,updatedAt:at});
  await rtRef.update({'data.CHAT_STYLE_POLICY':'{"enabled":false}',updatedAt:at,revision:String(at.getTime()),editLog:[{at,changes:[{key:'CHAT_STYLE_POLICY',before:rt.data.CHAT_STYLE_POLICY||'(default)',after:'{"enabled":false}'}]},...(rt.editLog||[])].slice(0,20)});
  return {version,at};
 });
 const final=one(await db.collection('bf_config').doc('experts').get());
 if(hash(final.experts.filter(e=>!['general','short_video'].includes(e.id)))!==backup.unchangedExpertsHash)throw Error('UNRELATED_EXPERT_CHANGED');
 const out={at:new Date(),modified:fn.ModTime,status:fn.Status,installDependency:fn.InstallDependency,expertVersion:updated.version,changedExperts:['general','short_video'],candidateStyleEnabled:false,exactArtifactMatch:true};
 fs.writeFileSync(path.join(folder,'release.json'),JSON.stringify(out,null,2));console.log(JSON.stringify(out));
})().catch(e=>{console.error(e.code||e.name);process.exitCode=1;});
