"use strict";
const fs=require('node:fs'),path=require('node:path');
const {buildImport,applyImport}=require('./lib/import-deepseek-export.cjs');
const dir=path.resolve('outputs/deepseek-platform-migration-20261105');
const credentials=JSON.parse(fs.readFileSync(path.join(process.env.USERPROFILE,'.config/.cloudbase/auth.json'),'utf8')).credential;
const app=require('../cloudfunctions/bf-api/node_modules/@cloudbase/node-sdk').init({
 env:'xmy-test-d5g8c0xcifcefcfd5',region:'ap-shanghai',secretId:credentials.tmpSecretId,
 secretKey:credentials.tmpSecretKey,sessionToken:credentials.tmpToken});
const fingerprint='d13b4c4d77d5a188';
(async()=>{
 const db=app.database();
 const accounts=(await db.collection('bf_accounts').where({username:'zhongfangbaoqu071'}).limit(2).get()).data;
 if(accounts.length!==1)throw Object.assign(new Error('Target account ambiguous'),{code:'ACCOUNT_AMBIGUOUS'});
 const a=accounts[0],account={_id:a._id,username:a.username,displayName:a.displayName};
 const data=JSON.parse(fs.readFileSync(path.join(dir,'normalized-export.json'),'utf8'));
 const plan=buildImport(data,account,fingerprint);
 const tracked=(await db.collection('bf_model_calls').where({credentialFingerprint:fingerprint}).limit(100).get()).data||[];
 const start=Math.min(...data.rows.map(r=>Date.parse(r.start))),end=Math.max(...data.rows.map(r=>Date.parse(r.end)));
 if(tracked.some(r=>new Date(r.startedAt).getTime()>=start&&new Date(r.startedAt).getTime()<end))throw Object.assign(new Error('Tracked calls overlap export'),{code:'TRACKED_COST_OVERLAP'});
 const previous={at:new Date(),sourceDigest:plan.sourceDigest,bills:[],usage:[],accountCounters:{chatUsedCny:a.chatUsedCny,imageUsedCny:a.imageUsedCny}};
 for(const r of plan.bills)previous.bills.push({id:r.id,rows:(await db.collection('bf_vendor_bills').doc(r.id).get()).data});
 for(const r of plan.usage)previous.usage.push({id:r.id,rows:(await db.collection('bf_usage_logs').doc(r.id).get()).data});
 const backup=path.join(dir,'bill-import-backup-'+Date.now()+'.json');
 fs.writeFileSync(backup,JSON.stringify(previous,null,2));
 const summary={mode:process.argv.includes('--apply')?'apply':'dry-run',accountLabel:a.displayName,
   bills:plan.bills.length,usageRows:plan.usage.length,costCny:plan.totalCny,requests:data.rows.reduce((s,r)=>s+r.requestCount,0),quotaChanged:false};
 if(!process.argv.includes('--apply')){console.log(JSON.stringify(summary));return;}
 const applied=await applyImport(db,plan);
 const afterBills=[];for(const r of plan.bills)afterBills.push(...(await db.collection('bf_vendor_bills').doc(r.id).get()).data);
 const afterUsage=[];for(const r of plan.usage)afterUsage.push(...(await db.collection('bf_usage_logs').doc(r.id).get()).data);
 const cost=rows=>rows.reduce((s,r)=>s+Math.round(r.costCny*1e8),0)/1e8;
 const official=afterBills.flatMap(b=>b.rows).reduce((s,r)=>s+Math.round(r.payableAmount*1e8),0)/1e8;
 if(official!==plan.totalCny||cost(afterUsage)!==plan.totalCny||afterUsage.some(r=>r.accountId!==a._id||r.priceCny!=null))throw Object.assign(new Error('Readback mismatch'),{code:'IMPORT_VERIFY_FAILED'});
 fs.writeFileSync(path.join(dir,'bill-import-result.json'),JSON.stringify({...summary,...applied,verified:true,officialCostCny:official,sourceDigest:plan.sourceDigest,backup:path.basename(backup),at:new Date()},null,2));
 console.log(JSON.stringify({...summary,...applied,verified:true,officialCostCny:official}));
})().catch(e=>{console.error(e.code||e.name);process.exitCode=1;});
