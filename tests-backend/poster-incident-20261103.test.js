"use strict";
const test=require("node:test"),assert=require("node:assert/strict");
const {ToolCallStreamGuard}=require("../cloudfunctions/shared/image-delivery");
const {sanitizeToolCall}=require("../cloudfunctions/shared/image-delivery");
const {withImageToolSchema}=require("../cloudfunctions/bf-api/image-tool-schema");
const {fitTextScene,validScene}=require("../cloudfunctions/shared/text-scene");
const {COMMERCIAL_BRIEF,injectCommercialImageGuidance}=require("../cloudfunctions/bf-api/commercial-image-guidance");
const frame=(delta,finish_reason=null)=>"data: "+JSON.stringify({choices:[{index:0,delta,finish_reason}]});
test("EOF after text is incomplete; genuine stop/DONE is accepted",()=>{
 const guard=new ToolCallStreamGuard("海报");guard.pushLine(frame({content:"好的，正在设计"}));
 assert.throws(()=>guard.end(),{code:"UPSTREAM_STREAM_INCOMPLETE"});
 for(const terminal of [frame({},"stop"),"data: [DONE]"]){const g=new ToolCallStreamGuard("海报");g.pushLine(frame({content:"完成"}));g.pushLine(terminal);g.end();}
});
test("final error frame without newline is rejected by same guard",()=>{
 const guard=new ToolCallStreamGuard("海报");
 assert.throws(()=>guard.pushLine('data: {"error":{"code":"quota","message":"secret"}}'),{code:"UPSTREAM_STREAM_ERROR"});
});
test("length/filter endings never release pending tool calls",()=>{
 for(const [reason,code] of [["length","OUTPUT_LIMIT"],["content_filter","CONTENT_FILTER"]]){
  const g=new ToolCallStreamGuard("海报");g.pushLine(frame({tool_calls:[{index:0,function:{name:"image_generate",arguments:'{"prompt":"valid"}'}}]}));
  assert.throws(()=>g.pushLine(frame({},reason)),{code});assert.equal(g.pending.size,1);
 }
});
test("malformed tool arguments have a stable reason without leaking their content",()=>{
 const g=new ToolCallStreamGuard("海报");g.pushLine(frame({tool_calls:[{index:0,function:{name:"image_generate",arguments:'{"prompt":"PRIVATE_DATA"'}}]}));
 assert.throws(()=>g.pushLine(frame({},"tool_calls")),e=>e.code==="TOOL_ARGUMENTS_INVALID"&&!e.message.includes("PRIVATE_DATA"));
});
test("commercial design guidance covers information design and copy consistency",()=>{
 assert.match(COMMERCIAL_BRIEF,/行动指南/);assert.match(COMMERCIAL_BRIEF,/具体行动/);
 assert.match(COMMERCIAL_BRIEF,/同一份定稿文案/);assert.match(COMMERCIAL_BRIEF,/不能编造/);
 const tools=[{function:{name:"image_generate"}}], messages=[{role:"user",content:"做参展路线海报"}];
 const out=injectCommercialImageGuidance(messages,tools,"做参展路线海报");
 assert.equal(out.length,3);assert.equal(injectCommercialImageGuidance(out,tools,"做参展路线海报"),out);
});
test("dictionary copy becomes the exact typed array understood by shipped phones",()=>{
 const original={main_title:"参展指南",actions:"第一步\n第二步",hotline:"400-7758-119"};
 const call={function:{name:"image_generate",arguments:JSON.stringify({prompt:"信息图",structured:{text:original,layout:{blocks:[{key:"hotline"}]}}})}};
 const args=JSON.parse(sanitizeToolCall(call,"做海报").function.arguments);
 assert.deepEqual(args.structured.text.map(t=>t.text),Object.values(original));
 assert.equal(args.structured.text.find(t=>t.key==="hotline").role,"contact");
 assert.equal(args.structured.text.find(t=>t.key==="main_title").role,"title");
 assert.ok(args.structured.layout.blocks.some(b=>b.key==="hotline"));
 assert.ok(validScene(args.structured.text,args.structured.layout.blocks));
});
test("server schema enforces typed copy without adding tools or losing asset contracts",()=>{
 const tools=[{function:{name:"image_generate",parameters:{properties:{source:{enum:["none","attached"]},structured:{properties:{preserve_assets:{type:"array"}}}}}}},{function:{name:"web_search"}}];
 const out=withImageToolSchema(tools);
 assert.equal(out[1],tools[1]);assert.equal(out[0].function.parameters.properties.source,tools[0].function.parameters.properties.source);
 const s=out[0].function.parameters.properties.structured;assert.equal(s.properties.text.type,"array");assert.ok(s.required.includes("text"));assert.ok(s.properties.preserve_assets);
 assert.equal(tools[0].function.parameters.properties.structured.required,undefined);
});
test("invalid AI scene is fitted without losing text or creating overlapping boxes",()=>{
 const text=Array.from({length:19},(_,i)=>({key:"item"+i,role:i?"body":"title",text:"这是一段不能丢失的商业文案。".repeat(i+1)}));
 const structured={text,layout:{blocks:text.map(t=>({key:t.key,x:.06,y:.955,width:.88,height:.03,color:"#FFFFFF"}))}};
 const out=fitTextScene(structured);assert.equal(out.text,text);assert.ok(validScene(text,out.layout.blocks));assert.equal(out.layout.blocks.length,19);
 assert.equal(fitTextScene(out),out);
});
