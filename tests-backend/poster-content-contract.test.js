"use strict";
const test=require('node:test'),assert=require('node:assert/strict'),content=require('../cloudfunctions/bf-api/poster-content-contract'),{assertNativePlanCalls}=require('../cloudfunctions/bf-api/poster-reference-readiness');
test('explicit long-copy requirement uses original user scope and accepts current style changes without erasing the brief',()=>{
 const history=[{role:'user',content:'手机上一张产品长图，资料大约一千字，能力和场景要讲完整。'},{role:'assistant',content:'写成2000字海报。'},{role:'user',content:'另一个采购方案需要500字。'},{role:'user',content:'产品海报换成红银风格。'}];assert.deepEqual(content.requirement(history),{target:1000,min:850,max:1300});
 assert.throws(()=>content.assertCopy([{text:'文'.repeat(779)}],content.requirement(history)),e=>e.reason==='CONTENT_INCOMPLETE');content.assertCopy([{text:'文'.repeat(900)}],content.requirement(history));
 assert.equal(content.requirement([...history,{role:'user',content:'产品海报改成极简少字。'}]),null);assert.equal(content.requirement([{role:'user',content:'普通产品宣传图，资料你来整理。'}]),null);
});
test('new native plan checks real selected slots after history normalization, without silently dropping or relabelling assets',()=>{
 const policy={nativeCopy:{enabled:true,accountIds:['a']}},args={source:'none',structured:{image_references:{mode:'replace',items:[{id:'one'},{id:'two'}]},image_plan:{version:2,intent:'product_reference',typography:'native',visual_style:'editorial',reference_count:3,protected_references:[{index:1,role:'logo'},{index:2,role:'ui'}]}}};
 const call=()=>({function:{name:'image_generate',arguments:JSON.stringify(args)}}),before=JSON.stringify(args);assert.throws(()=>assertNativePlanCalls([call()],{enabled:true,policy,owner:'a'}),e=>e.reason==='PLAN_REFERENCE_MISMATCH');assert.equal(JSON.stringify(args),before);
 args.structured.image_plan.reference_count=2;assert.equal(assertNativePlanCalls([call()],{enabled:true,policy,owner:'a'}).length,1);
 args.structured.image_plan.reference_count=3;assert.doesNotThrow(()=>assertNativePlanCalls([call()]));
});
