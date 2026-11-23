"use strict";
const test=require('node:test'),assert=require('node:assert/strict'),policy=require('../cloudfunctions/shared/native-copy-policy'),workflow=require('../cloudfunctions/shared/image-workflow'),native=require('../cloudfunctions/shared/commercial-generation-mode');
const p={nativeCopy:{enabled:true,accountIds:['member'],maxOutputs:2}};
test('density threshold is server-configurable and short posters do not start paid repair',()=>{
 const raw={nativeCopy:{...p.nativeCopy,minChars:420}},request={task_kind:'generate',structured:{text:[{key:'body',role:'body',text:'完整正文'}]}};
 assert.equal(policy.eligible(raw,'member',request),false);
 assert.equal(policy.eligible(raw,'member',{...request,structured:{text:[{key:'body',role:'body',text:'字'.repeat(420)}]}}),true);
 for(const minChars of [-1,4001,1.5,'420'])assert.equal(policy.policyOf({nativeCopy:{...p.nativeCopy,minChars}}),null);
});
test('one bounded server-only layer budget allows finer decomposition without raising the default',()=>{
 assert.equal(policy.policyOf({nativeCopy:{enabled:true,accountIds:['member']}}).maxOutputs,2);
 for(const maxOutputs of [2,3,4,8])assert.equal(policy.policyOf({nativeCopy:{...p.nativeCopy,maxOutputs}}).maxOutputs,maxOutputs);
 for(const maxOutputs of [1,9,30,2.5,'8'])assert.equal(policy.policyOf({nativeCopy:{...p.nativeCopy,maxOutputs}}),null);
});
test('one server-owned canary selects both original composition and native design without changing other members',()=>{
 assert.equal(policy.enabled(p,'member'),true);assert.equal(workflow.enabled(p,'member'),true);assert.equal(native.nativeCommercialEnabled(p,'member'),true);
 for(const raw of [{},'{bad',{nativeCopy:{enabled:true}},{nativeCopy:{enabled:true,accountIds:'all'}},p])assert.equal(policy.enabled(raw,'other'),false);
 const request={task_kind:'generate',structured:{text:[{key:'body',role:'body',text:'完整正文'}]}};
 assert.equal(policy.eligible(p,'member',request),true);
 for(const extra of [{task_kind:'edit'},{requested_count:2},{text_mode:'overlay'},{structured:{text:request.structured.text,preserve_assets:[{}]}}])assert.equal(policy.eligible(p,'member',{...request,...extra}),false);
});
