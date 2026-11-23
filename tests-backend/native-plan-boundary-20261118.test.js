'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const code=process.env.NATIVE_PLAN_PACKAGE||path.resolve(__dirname,'../cloudfunctions/bf-api');
const {assertNativePlanCalls}=require(path.join(code,'poster-reference-readiness'));
const {repairImageCompletion,diagnostic}=require(path.join(code,'image-tool-repair'));
const policy={nativeCopy:{enabled:true,accountIds:['qa'],maxOutputs:2}},options={enabled:true,policy,owner:'qa'};
const args=()=>({
 prompt:'园区设备协作宣传海报。珊瑚橙配湖蓝，纪实摄影，现场光线，文字清晰可读。',
 aspect_ratio:'3:4',render_intent:'flat_artwork',source:'none',
 structured:{
  text:[{key:'headline',role:'title',text:'让设备运维有据可查'},
   ...['设备建档','巡检任务','异常处理','能耗观察','资料管理','协作权限'].flatMap((title,i)=>[
    {key:'head'+i,role:'label',text:title},
    {key:'detail'+i,role:'body',text:`按项目整理${title}资料，保留原始记录并明确参与范围。交接时逐项核对现场点位、设备参考图和经手人，再检查后续操作记录。看板只展示经确认的数据。`}
   ])],
  design_brief:{visual_approach:'纪实光影、非对称构图、暖色点缀'},
  image_plan:{version:2,intent:'poster',typography:'native',visual_style:'documentary with coral accents',reference_count:0,protected_references:[]}
 }
});
const call=a=>({id:'plan1',type:'function',function:{name:'image_generate',arguments:JSON.stringify(a)}});
test('a dense poster plan is rejected before image dispatch with an actionable enum diagnosis',()=>{
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
