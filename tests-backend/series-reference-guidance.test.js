"use strict";
const test=require("node:test"),assert=require("node:assert/strict");
const {recalledIds,prepareSeriesReferenceGuidance}=require("../cloudfunctions/bf-api/image-series-reference-guidance");
const {referenceRequestFingerprint,prepareSeriesReferenceInput,resolveSeriesReferenceInput}=require("../cloudfunctions/shared/series-reference-input");
const A="B665E22F-B174-4C75-931A-962EC43FE3E1",B="B665E22F-B174-4C75-931A-962EC43FE3E2";
const history=[{role:"assistant",tool_calls:[{id:"recall1",function:{name:"recall_history"}}]},
 {role:"tool",tool_call_id:"recall1",content:"图片ID："+A+"；名称：背景\n图片ID："+B+"；名称：人物"}];
const tools=[{function:{name:"image_series",parameters:{properties:{prompt:{type:"string"},structured:{type:"object",properties:{text:{type:"array"}}}}}}},{function:{name:"image_edit"}}];
const refs=()=>({version:1,mode:"replace",items:[{kind:"library",id:A,role:"底图"},{kind:"library",id:B,role:"人物"}]});
const call=args=>({function:{name:"image_series",arguments:JSON.stringify(args)}});
test("only paired recall_history tool results issue memory IDs, not user text or unpaired tools",()=>{
 assert.deepEqual(recalledIds([...history,{role:"user",content:"图片ID：00000000-0000-0000-0000-000000000000"},{role:"tool",tool_call_id:"fake",content:"图片ID：00000000-0000-0000-0000-000000000000"}]),[A,B]);
});
test("planning validates account assets and strengthens only series structured schema",async()=>{
 const seen=[],original=JSON.stringify(tools),p=await prepareSeriesReferenceGuidance({messages:history,tools,owner:"A",referenceStore:{async prepare(owner,c){seen.push([owner,c.items[0].id]);}}});
 assert.deepEqual(seen,[["A",A],["A",B]]);assert.equal(JSON.stringify(tools),original);assert.equal(p.tools[1],tools[1]);
 assert.ok(p.tools[0].function.parameters.properties.structured.properties.text);
 assert.deepEqual(p.tools[0].function.parameters.properties.structured.properties.image_references.properties.items.items.properties.id.enum,[A,B]);
 assert.match(p.messages.at(-1).content,/不会把这些字节交给组图服务/);
});
test("legacy top-level library_refs become a durable structured contract without losing order",async()=>{
 const p=await prepareSeriesReferenceGuidance({messages:history,tools,owner:"A",referenceStore:{async prepare(){}}});
 const input=call({prompt:"合成",library_refs:[A.toLowerCase(),B],reference_roles:["底图","人物"]}),out=JSON.parse(p.finalize([input])[0].function.arguments);
 assert.deepEqual(out.structured.image_references,refs());assert.equal(out.library_refs,undefined);assert.match(input.function.arguments,/library_refs/);
 assert.equal(out.reference_roles,undefined); // shipped decoder requires source_indexes for that top-level field
});
test("unissued, unavailable or append references are rejected before client execution",async()=>{
 const p=await prepareSeriesReferenceGuidance({messages:history,tools,owner:"A",referenceStore:{async prepare(owner,c){if(c.items[0].id===B)throw Error("ASSET_NOT_READY");}}});
 assert.throws(()=>p.finalize([call({structured:{image_references:refs()}})]),/NOT_ISSUED/);
 const c=refs();c.items=c.items.slice(0,1);c.mode="append";assert.throws(()=>p.finalize([call({structured:{image_references:c}})]),/NOT_ISSUED/);
});
test("ordinary text-only series and non-series requests retain prior tools and behavior",async()=>{
 const p=await prepareSeriesReferenceGuidance({messages:[],tools,owner:"A",referenceStore:{async prepare(){throw Error("must not read");}}});
 assert.equal(p.tools,tools);assert.deepEqual(p.finalize([call({prompt:"画两只小狗"})]),[call({prompt:"画两只小狗"})]);
 const n=await prepareSeriesReferenceGuidance({messages:history,tools:[],owner:"A",referenceStore:{async prepare(){throw Error("must not read");}}});assert.equal(n.messages,history);
});
test("shipped series schema without structured can gain metadata already supported by its executor",async()=>{
 const legacy=[{function:{name:"image_series",parameters:{type:"object",properties:{prompt:{type:"string"},count:{type:"integer"}},required:["prompt"]}}}];
 const p=await prepareSeriesReferenceGuidance({messages:history,tools:legacy,owner:"A",referenceStore:{async prepare(){}}});
 assert.ok(p.tools[0].function.parameters.properties.structured.properties.image_references);
 assert.deepEqual(p.tools[0].function.parameters.required,["prompt"]);
 assert.throws(()=>p.finalize([call({source:"attached",structured:{image_references:refs()}})]),/CONFLICT/);
});
test("reference fingerprint binds selection and roles while normalizing UUID casing",()=>{
 const a=refs(),b=refs();b.items[0].id=A.toLowerCase();assert.equal(referenceRequestFingerprint(a),referenceRequestFingerprint(b));
 b.items.reverse();assert.notEqual(referenceRequestFingerprint(a),referenceRequestFingerprint(b));
 assert.equal(referenceRequestFingerprint(null),"");
});
test("durable reference preparation rejects conflicting raw inputs and preserves legacy absence",async()=>{
 const store={async prepare(owner,c){return {version:1,mode:c.mode,references:[]};}};
 assert.deepEqual(await prepareSeriesReferenceInput({owner:"A",store,structured:{text:[]}}),{referenceManifest:null,referenceFingerprint:""});
 await assert.rejects(prepareSeriesReferenceInput({owner:"A",store,structured:{image_references:refs()},image:"base"}),/UNSUPPORTED/);
 const result=await prepareSeriesReferenceInput({owner:"A",store,structured:{image_references:refs()}});assert.ok(result.referenceFingerprint);assert.ok(result.referenceManifest);
});
test("execution resolves ordered roles and fresh URLs but legacy raw input remains unchanged",async()=>{
 const store={async sign(){return [{id:"a",role:"底图",url:"https://host/a"},{id:"b",role:"人物",url:"https://host/b"}];}};
 assert.deepEqual(await resolveSeriesReferenceInput({store,owner:"A",manifest:{mode:"replace"}}),{image:["https://host/a","https://host/b"],referenceRoles:["底图","人物"]});
 assert.deepEqual(await resolveSeriesReferenceInput({store,owner:"A",image:"raw"}),{image:"raw",referenceRoles:undefined});
});
