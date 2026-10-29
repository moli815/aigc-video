// Change non-secret billing fields only. Keep the original values for rollback.
const fs=require('fs'),path=require('path'),assert=require('assert/strict');
const sdk=require('../cloudfunctions/bf-api/node_modules/@cloudbase/node-sdk');
const c=JSON.parse(fs.readFileSync(path.join(process.env.USERPROFILE,'.config/.cloudbase/auth.json'),'utf8')).credential;
const db=sdk.init({env:'xmy-test-d5g8c0xcifcefcfd5',region:'ap-shanghai',secretId:c.tmpSecretId,secretKey:c.tmpSecretKey,sessionToken:c.tmpToken}).database();
const keys={USAGE_BILLING_MODE:'supplier_cost',USAGE_COST_MULTIPLIER:2,IMAGE_PRICE_MULTIPLIER:2};
const file=path.resolve(__dirname,'../outputs/supplier-cost-billing-rollout.json'),one=r=>Array.isArray(r.data)?r.data[0]:r.data;
(async()=>{
 const cat=one(await db.collection('bf_config').doc('supplier_cost_catalog').get());
 assert.ok(cat?.models?.['aliyun-bailian:deepseek-v4.1-flash-1017']?.offpeak?.cachedInput!=null,'verified complete catalog required');
 const before=one(await db.collection('bf_config').doc('runtime').get());
 const plan={at:new Date().toISOString(),before:Object.fromEntries(Object.keys(keys).map(k=>[k,before.data[k]??null])),after:keys,catalogRevision:cat.revision};
 if(process.argv[2]!=='--apply'){fs.writeFileSync(file,JSON.stringify(plan,null,2));console.log(JSON.stringify(plan));return;}
 const previous=JSON.parse(fs.readFileSync(file,'utf8'));assert.deepEqual(previous.after,keys);
 await db.runTransaction(async tx=>{const ref=tx.collection('bf_config').doc('runtime'),current=one(await ref.get());
   for(const k of Object.keys(keys))assert.equal(current.data[k]??null,previous.before[k],'another operator changed '+k);
   const patch=Object.fromEntries(Object.entries(keys).map(([k,v])=>['data.'+k,v]));
   await ref.update({...patch,updatedAt:new Date(),revision:String(Date.now()),editLog:[{at:new Date(),changes:['Enable supplier cost x2; preserve historical balances']},...(current.editLog||[])].slice(0,20)});
 });
 const check=one(await db.collection('bf_config').doc('runtime').get());for(const k of Object.keys(keys))assert.equal(check.data[k],keys[k]);
 const result={...previous,appliedAt:new Date().toISOString(),readbackVerified:true};fs.writeFileSync(file,JSON.stringify(result,null,2));console.log(JSON.stringify(result));
})().catch(e=>{console.error(e.message);process.exitCode=1;});
