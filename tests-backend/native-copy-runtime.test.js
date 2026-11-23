"use strict";
const test=require('node:test'),assert=require('node:assert/strict');
const {createRuntime}=require('../cloudfunctions/bf-image/native-copy-runtime');
function runtime(){return createRuntime({composition:{nativeResources:async()=>({fontRevision:'fixture'})},getVision:async()=>({model:'fixture-vision',snapshot:{rates:{input:1,output:2}}})});}
const policy={nativeCopy:{enabled:true,accountIds:['alice'],maxOutputs:2},fonts:[]};
const roles=['title','subtitle','body','label','contact','footer'];
const make=()=>({owner:'alice',model:'doubao-seedream-5-5-261028',rawPolicy:policy,body:{task_kind:'generate',structured:{text:roles.map((role,i)=>({key:'field'+i,role,text:'确认原文'+i}))}}});
test('native runtime freezes every visible text role, including footer and contact',async()=>{
 const input=make(),prepared=await runtime().prepare(input);assert.equal(prepared.items.length,6);
 assert.deepEqual(prepared.items.map(t=>t.role),roles);assert.deepEqual(prepared.items,input.body.structured.text);
 assert.equal(await runtime().prepare({...input,owner:'bob'}),null);
});
test('invalid peripheral text and more than 64 fields reject before any provider call',async()=>{
 for(const modify of [a=>a.body.structured.text[3].role='hidden',a=>a.body.structured.text[5].text='',a=>a.body.structured.text[4].key='field0',a=>a.body.structured.text=Array.from({length:65},(_,i)=>({key:'k'+i,role:'body',text:'确认原文'}))]){
  const input=make();modify(input);await assert.rejects(runtime().prepare(input),/NATIVE_TEXT_CONTRACT/);
 }
});
test('official decomposition uses auto, bounded outputs and no fixed colour, layout or width-height request',()=>{
 const {decompositionRequest}=require('../cloudfunctions/bf-image/native-copy-runtime'),input={model:'doubao-seedream-5-5-261028',image:'https://fixture.invalid/owned.png',maxOutputs:2};
 const actual=decompositionRequest(input);assert.equal(actual.size,'auto');assert.equal(actual.layer_decomposition,true);assert.equal(actual.layer_decomposition_options.max_images,2);assert.equal(actual.layer_decomposition_options.text_recognition,true);
 assert.equal(actual.image,input.image);assert.doesNotMatch(actual.prompt,/蓝金|杂志|固定|双列|米白|墨绿/);
 for(const patch of [{maxOutputs:30},{maxOutputs:undefined},{image:[]},{model:'unverified-model'}])assert.throws(()=>decompositionRequest({...input,...patch}),/COPY_LAYER_REQUEST_INVALID/);
});
