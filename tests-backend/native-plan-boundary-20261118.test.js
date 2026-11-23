'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const code=process.env.NATIVE_PLAN_PACKAGE||path.resolve(__dirname,'../cloudfunctions/bf-api');
const {assertNativePlanCalls}=require(path.join(code,'poster-reference-readiness'));
const {repairImageCompletion,diagnostic}=require(path.join(code,'image-tool-repair'));
const policy={nativeCopy:{enabled:true,accountIds:['qa'],maxOutputs:2}},options={enabled:true,policy,owner:'qa'};
const args=()=>JSON.parse(fs.readFileSync(path.resolve(__dirname,'../outputs/native-copy-rollout-20261117/live-3/long-context-colour-photo/tool-arguments.json')));
const call=a=>({id:'plan1',type:'function',function:{name:'image_generate',arguments:JSON.stringify(a)}});
test('the captured real 464-character plan is rejected before image dispatch with an actionable enum diagnosis',()=>{
 assert.throws(()=>assertNativePlanCalls([call(args())],options),e=>e.code==='TOOL_ARGUMENTS_INVALID'&&e.reason==='PLAN_ENUM_INVALID'&&diagnostic(e).field==='structured.image_plan');
});
test('execution enums do not replace the user colour, composition, long copy or free design direction',()=>{
 const original=args(),a=structuredClone(original);Object.assign(a.structured.image_plan,{intent:'campaign',visual_style:'editorial'});
 const calls=[call(a)];assert.equal(assertNativePlanCalls(calls,options),calls);assert.equal(a.prompt,original.prompt);assert.deepEqual(a.structured.text,original.structured.text);assert.deepEqual(a.structured.design_brief,original.structured.design_brief);
});
test('one bounded argument repair checks the same contract again; a second invalid plan never escapes to the phone',async()=>{
 const a=args(),body={messages:[{role:'user',content:'按刚才的材料做海报，内容完整。'}]},error={code:'TOOL_ARGUMENTS_INVALID',reason:'PLAN_ENUM_INVALID',field:'structured.image_plan'};
 let calls=0;const sanitize=v=>{assertNativePlanCalls(v.choices[0].message.tool_calls,options);return v;};
 const valid=structuredClone(a);Object.assign(valid.structured.image_plan,{intent:'campaign',visual_style:'editorial'});
 const request=async p=>{calls++;assert.match(p.messages.at(-1).content,/不能写poster/);return{choices:[{finish_reason:'tool_calls',message:{tool_calls:[call(valid)]}}]};};
 assert.ok(await repairImageCompletion({body,error,request,sanitize}));assert.equal(calls,1);
 let invalidCalls=0;assert.equal(await repairImageCompletion({body,error,request:async()=>{invalidCalls++;return{choices:[{finish_reason:'tool_calls',message:{tool_calls:[call(a)]}}]};},sanitize}),null);assert.equal(invalidCalls,1);
});
