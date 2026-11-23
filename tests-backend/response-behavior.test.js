"use strict";
const test=require("node:test"),assert=require("node:assert/strict");
const {injectAssistantGuidance}=require("../cloudfunctions/bf-api/assistant-guidance");
const {VERSION,activeStyle,normalizeExpertWrappers}=require("../cloudfunctions/bf-api/response-behavior");
const {validateValue}=require("../cloudfunctions/bf-api/settings-schema");
const on={enabled:true,profile:"task_v2",audience:"accounts",accountIds:["u1"]};
const knownRole=require("../cloudfunctions/bf-api/experts.json").experts[0].role;
test("v2 only normalizes known expert formatting; all user images, tools, facts and boundaries survive",()=>{
 const system={role:"system",content:"品牌：甲公司。禁止伪造。\n【必须遵循的工作流】\n步骤一。\n【可执行技能契约 v1：专家】\n必要输入：目标。缺失项列为待补充；先提供分析框架，不编造输入。\n执行步骤：1. 判断\n交付章节：结论；风险。\n先调用 expert_skill(operation: plan) 获取本专家当前契约。\n边界：不得承诺收益。"};
 const user={role:"user",content:[{type:"text",text:"【必须遵循的工作流】这段是我的原稿"},{type:"image_url",image_url:{url:"PRIVATE"}}]};
 const tool={role:"tool",tool_call_id:"t1",content:'{"workflow":["输出三角度"],"fact":"品牌甲公司"}'};
 system.content=knownRole+"\n"+system.content;
 const source=[system,user,tool],before=JSON.stringify(source),output=injectAssistantGuidance(source,on,"u1");
 assert.equal(JSON.stringify(source),before);assert.strictEqual(output[1],user);assert.strictEqual(output[2],tool);
 for(const text of ["品牌：甲公司","禁止伪造","步骤一","必要输入：目标","先调用 expert_skill(operation: plan)","边界：不得承诺收益"] )assert.ok(output[0].content.includes(text));
 assert.ok(!output[0].content.includes("【必须遵循的工作流】"));assert.ok(!output[0].content.includes("交付章节："));
 assert.ok(output.at(-1).content.includes(VERSION));
 assert.deepEqual(injectAssistantGuidance(output,on,"u1"),output);
});
test("v2 does not rewrite arbitrary administrator prompts or non-system examples",()=>{
 const source=[{role:"system",content:"自定义说明：执行步骤：必须审批。交付章节：合同。"},{role:"user",content:"【可执行技能契约 v1：自定义】交付章节：保留"}];
 const output=normalizeExpertWrappers(source,on,"u1");
 assert.strictEqual(output[0],source[0]);assert.strictEqual(output[1],source[1]);
});
test("disabled or out-of-scope v2 cannot fall back into the failed legacy style",()=>{
 const source=[{role:"system",content:"【必须遵循的工作流】原文"},{role:"user",content:"一句话"}];
 for(const policy of [{...on,enabled:false},on,{...on,audience:"account"},{...on,profile:"unknown"}]){
  const output=injectAssistantGuidance(source,policy,"u2");
  assert.strictEqual(output[0],source[0]);assert.ok(!output.at(-1).content.includes("ASSISTANT_RESPONSE_STYLE"));assert.ok(!output.at(-1).content.includes(VERSION));
 }
});
test("style configuration shares save-time and consumer validation including canary scopes",()=>{
 const spec={type:"json",label:"style"};
 for(const policy of [on,{enabled:true,profile:"task_v2",audience:"all"},{enabled:false},{}])assert.equal(validateValue("CHAT_STYLE_POLICY",JSON.stringify(policy),spec).ok,true);
 for(const policy of [{enabled:true,profile:"unknown"},{enabled:true,audience:"account"},{enabled:true,accountIds:[1]},{enabled:true,instructions:null},{enabled:null}]){
  assert.equal(validateValue("CHAT_STYLE_POLICY",JSON.stringify(policy),spec).ok,false);assert.equal(activeStyle(policy,"u1"),null);
 }
 assert.equal(activeStyle({...on,audience:undefined},"u1"),null);
 assert.equal(activeStyle({enabled:true,profile:"task_v2",accountIds:["u1"]},"u2"),null);
});
test("system-stored identity and user material after the capability section remain byte-for-byte intact",()=>{
 const material="【用户资料】\n执行步骤：客户原文。\n交付章节：客户原文。\n【必须遵循的工作流】这是客户引用。\n【可执行技能契约 v1：客户引用】\n执行步骤：仍是客户原文。";
 const source=[{role:"system",content:knownRole+"\n【必须遵循的工作流】\n内部步骤\n【可执行技能契约 v1：专家】\n执行步骤：内部方法\n交付章节：内部章节\n"+material}];
 const once=normalizeExpertWrappers(source,on,"u1"),twice=normalizeExpertWrappers(once,on,"u1");
 assert.ok(once[0].content.endsWith(material));assert.deepEqual(twice,once);assert.ok(source[0].content.includes("交付章节：内部章节"));
});
test("an unrelated system memory containing legacy headings is not treated as an expert prompt",()=>{
 const source=[{role:"system",content:"【前情摘要】客户引用了下列文档：\n【必须遵循的工作流】\n【可执行技能契约 v1：客户文档】\n执行步骤：客户原文。"}];
 assert.strictEqual(normalizeExpertWrappers(source,on,"u1"),source);
});
