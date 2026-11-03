"use strict";
const test=require("node:test"),assert=require("node:assert/strict"),fs=require("node:fs"),vm=require("node:vm"),crypto=require("node:crypto");
const {designContext,designPolicy,injectImageDesignPolicy,PROFILES}=require("../cloudfunctions/bf-api/image-design-policy");
const {withImageToolSchema}=require("../cloudfunctions/bf-api/image-tool-schema");
const {compileDesignBrief,compileNativeCopy}=require("../cloudfunctions/shared/image-design-brief");
const {isCommercialTask}=require("../cloudfunctions/bf-api/commercial-image-guidance");
test("short follow-up carries supplied user context and labels assistant drafts as unverified",()=>{
 const history=[{role:"user",content:"我是安防报警运营商，要参展行动指南，不要预约广告"},{role:"assistant",content:"建议先看A馆，未经核实"},{role:"user",content:"按刚才的要求做9比16海报"}];
 const c=designContext(history,history.at(-1).content);
 assert.match(c.recent_context[0].excerpt,/安防报警/);assert.equal(c.recent_context[1].origin,"assistant_draft_not_verified");
 assert.match(c.current_request,/9比16/);
});
test("current explicit change remains current, never overwritten by prior task",()=>{
 const h=[{role:"user",content:"画参展攻略"},{role:"assistant",content:"好的"},{role:"user",content:"这次改成展位预约广告，走极简风"}];
 const c=designContext(h,h.at(-1).content);
 assert.match(c.current_request,/改成展位预约广告/);assert.match(designPolicy(h,c.current_request),/最新明确改口覆盖早先目标/);
});
test("no system secrets or image pixels are copied into the task index",()=>{
 const h=[{role:"system",content:"PRIVATE_SYSTEM_DATA"},{role:"user",content:[{type:"image_url",image_url:{url:"data:image/png;base64,SECRET_IMAGE"}},{type:"text",text:"做产品海报"}]},{role:"user",content:"继续"}];
 const c=JSON.stringify(designContext(h,"继续"));assert.doesNotMatch(c,/PRIVATE_SYSTEM_DATA|SECRET_IMAGE/);assert.match(c,/做产品海报/);
});
test("context index is bounded and policy is idempotent",()=>{
 const h=Array.from({length:200},(_,i)=>({role:i%2?"assistant":"user",content:"字".repeat(4000)}));
 assert.ok(JSON.stringify(designContext(h,"继续")).length<10000);
 const first=injectImageDesignPolicy(h,"继续"),second=injectImageDesignPolicy(first,"继续");
 assert.equal(second.length,first.length);assert.equal(h.length,200);
});
test("default visual policy separates information density from minimal style",()=>{
 const p=designPolicy([],"企业展会海报");
 assert.match(p,/不默认极简/);assert.match(p,/不受聊天精简协议限制/);assert.match(p,/必须给出定义/);
 assert.match(p,/图片模型不会自动读取聊天历史/);assert.ok(PROFILES.some(p=>p.id==="photographic"));assert.ok(PROFILES.some(p=>p.id==="action-guide"));
});
test("commercial brief requirement preserves old schema and does not alter local editing contract",()=>{
 const tools=["image_generate","image_edit","web_search"].map(name=>({function:{name,parameters:{properties:{source:{enum:["none","attached"]},structured:{properties:{preserve_assets:{type:"array"}}}}}}}));
 const before=JSON.stringify(tools),out=withImageToolSchema(tools,{commercial:true});
 const generate=out[0].function.parameters.properties.structured,edit=out[1].function.parameters.properties.structured;
 assert.ok(generate.required.includes("design_brief"));assert.equal(edit.properties.design_brief,undefined);
 assert.equal(out[2],tools[2]);assert.equal(JSON.stringify(tools),before);assert.ok(generate.properties.preserve_assets);
 assert.equal(withImageToolSchema(tools)[0].function.parameters.properties.structured.properties.design_brief,undefined);
});
test("same short question under changed memory or style cannot reuse stale cached prose",()=>{
 const src=fs.readFileSync(require.resolve("../cloudfunctions/bf-api/index.js"),"utf8"),a=src.indexOf("function semanticCacheKey("),b=src.indexOf("\n}",a)+2;
 const fn=vm.runInNewContext(src.slice(a,b)+"\nsemanticCacheKey",{crypto});
 const messages=style=>[{role:"system",content:style},{role:"user",content:"企业运营效率怎样提升"}];
 assert.notEqual(fn(messages("用户是报警运营商"),"standard"),fn(messages("用户是餐饮老板"),"standard"));
 assert.equal(fn(messages("同一上下文"),"standard"),fn(messages("同一上下文"),"standard"));
 assert.match(src,/Array\.isArray\(body.tools\) && body.tools.length \? null : semanticCacheKey\(messages, tier.name\)/);
});
test("conversational follow-ups retain active design context but topic changes stop it",()=>{
 const h=[{role:"user",content:"做一个企业展会海报"}];
 for(const text of ["就照你刚才那个方案来","那就生成吧","沿用之前的风格"])assert.equal(isCommercialTask(h,text),true);
 assert.equal(isCommercialTask(h,"把合同分析一下"),false);
});
test("provider sees the self-contained goal but local editing and overlay constraints survive",()=>{
 const brief={purpose:"action_guide",audience:"报警运营商",goal:"找渠道和联动合作",reader_questions:["先找谁","怎么筛选"],visual_approach:"明亮编辑式信息图",information_density:"dense"};
 const p=compileDesignBrief(brief,{taskKind:"generate"});
 assert.match(p,/报警运营商/);assert.match(p,/找渠道和联动合作/);assert.match(p,/不是可见文案/);
 assert.match(compileDesignBrief(brief,{taskKind:"reference",textMode:"overlay"}),/无字底图/);
 assert.equal(compileDesignBrief(brief,{taskKind:"edit"}),"");
 assert.equal(compileDesignBrief({purpose:"unknown",goal:"wrong"},{}),"");
 assert.equal(compileDesignBrief(undefined,{}),"");
});

test("native provider copy retains product title versus brand label and every body line",()=>{
 const items=[{role:"label",text:"晨光咖啡"},{role:"title",text:"榛香拿铁"},{role:"body",text:"第一句\n第二句\n第三句"}];
 const p=compileNativeCopy(items,{taskKind:"generate"}),copy=JSON.parse(p.slice(p.indexOf("\n")+1));
 assert.deepEqual(copy,items);assert.match(p,/品牌label不能替代或挤掉主标题/);
 assert.equal(compileNativeCopy(items,{textMode:"overlay"}),"");
 assert.equal(compileNativeCopy(items,{taskKind:"edit"}),"");
 assert.equal(compileNativeCopy({title:"legacy"}),"");
});
