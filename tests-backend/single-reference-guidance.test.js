"use strict";
const test=require('node:test'),assert=require('node:assert/strict');
const {prepareSingleReferenceGuidance}=require('../cloudfunctions/bf-api/image-single-reference-guidance');
const A='B665E22F-B174-4C75-931A-962EC43FE3E1',B='B665E22F-B174-4C75-931A-962EC43FE3E2';
const messages=[{role:'assistant',tool_calls:[{id:'recall',function:{name:'recall_history'}}]},{role:'tool',tool_call_id:'recall',content:'图片ID：'+A+'\n图片ID：'+B}];
const tools=['image_edit','image_generate'].map(name=>({function:{name,parameters:{properties:{source:{type:'string'},structured:{type:'object',properties:{text:{type:'array'}}}}}}}));
const call=(args,name='image_edit')=>({function:{name,arguments:JSON.stringify(args)}});
const contract=(id=A)=>({version:1,mode:'append',items:[{kind:'library',id,role:'人物素材'}]});
async function fixture(extra={}){return prepareSingleReferenceGuidance({messages,tools,owner:'A',policy:{enabled:true,audience:'all'},referenceStore:{async prepare(){}},...extra});}
test('feature-disabled and ordinary non-memory tools retain the previous request without database access',async()=>{
 const p=await fixture({policy:{enabled:true,accountIds:['B']},referenceStore:{async prepare(){throw Error('must not read');}}});assert.equal(p.messages,messages);assert.equal(p.tools,tools);
 const q=await fixture();const c=call({source:'last',prompt:'调亮一点'});assert.equal(q.finalize([c])[0],c);
});
test('existing structured schema is extended optionally; current source remains intact and legacy library override is removed',async()=>{
 const p=await fixture();assert.ok(p.tools[0].function.parameters.properties.structured.properties.text);assert.ok(p.tools[0].function.parameters.properties.structured.properties.image_references);assert.match(p.messages.at(-1).content,/未知角色/);
 const c=call({source:'last',library_refs:[A],reference_roles:['旧历史角色'],prompt:'把历史人物放进刚生成的海报'}),out=JSON.parse(p.finalize([c])[0].function.arguments);
 assert.equal(out.source,'last');assert.equal(out.library_refs,undefined);assert.equal(out.reference_roles,undefined);assert.equal(out.structured.image_references.items[0].id,A);assert.equal(out.structured.image_references.items[0].role,'历史原图1');assert.match(c.function.arguments,/library_refs/);
});
test('explicit mixed metadata preserves ordered issued IDs and current attachment roles',async()=>{
 const p=await fixture(),c=call({source:'attached',source_indexes:[2,1],reference_roles:['海报','产品'],structured:{image_references:contract()}}),out=JSON.parse(p.finalize([c])[0].function.arguments);
 assert.deepEqual(out.reference_roles,['海报','产品']);assert.deepEqual(out.source_indexes,[2,1]);assert.equal(out.structured.image_references.items[0].id,A);assert.equal(out.structured.image_references.items[0].role,'历史原图1');
});
test('unissued or unavailable originals and conflicting legacy IDs are rejected before the phone executes',async()=>{
 const p=await fixture({referenceStore:{async prepare(owner,c){if(c.items[0].id===B)throw Error('deleted');}}});
 for(const args of [{source:'last',structured:{image_references:contract(B)}},{source:'none',structured:{image_references:contract()}},{source:'last',library_refs:[B],structured:{image_references:contract()}}])assert.throws(()=>p.finalize([call(args)]));
});
test('local exact-Logo workflow is left intact, while contradictory new metadata is rejected',async()=>{
 const p=await fixture(),args={source:'both',library_refs:[A,B],structured:{preserve_assets:[{reference_index:2,kind:'logo'}]}};const c=call(args);assert.equal(p.finalize([c])[0],c);
 assert.throws(()=>p.finalize([call({...args,structured:{...args.structured,image_references:contract()}})]),/CONFLICT/);
});
test('history-only library selection and series tools do not get converted to mixed current inputs',async()=>{
 const p=await fixture(),c=call({library_refs:[A],prompt:'用历史原图重设计'}),series=call({structured:{image_references:{...contract(),mode:'replace'}}},'image_series');assert.equal(p.finalize([c])[0],c);assert.equal(p.finalize([series])[0],series);
});
test('history aliases are rebound to neutral positions rather than claiming an unverified visual class',async()=>{
 const p=await fixture(),c=call({source:'last',prompt:'把人物素材中的机柜放在当前底图前景',structured:{image_references:{version:1,mode:'append',items:[{kind:'library',id:A,role:'人物素材'}]}}}),args=JSON.parse(p.finalize([c])[0].function.arguments);
 assert.equal(args.structured.image_references.items[0].role,'历史原图1');assert.equal(args.prompt,'把历史原图1中的机柜放在当前底图前景');
});
test('two-phase rollout can enable execution while withholding new plans without reading image memory',async()=>{
 const p=await fixture({policy:{enabled:true,audience:'all',planningEnabled:false},referenceStore:{async prepare(){throw Error('must not read');}}});assert.equal(p.messages,messages);assert.equal(p.tools,tools);
});
