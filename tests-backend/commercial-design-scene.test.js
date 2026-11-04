"use strict";
const test=require("node:test"),assert=require("node:assert/strict"),fs=require("node:fs"),path=require("node:path");
const {planOf,designEnabled}=require("../cloudfunctions/bf-image/commercial-design-plan");
const {contentOf,contrast,partition,policyOf}=require("../cloudfunctions/bf-image/commercial-composer");
const {scene}=require("../cloudfunctions/bf-image/commercial-poster-scene");
const {artworkPrompt}=require("../cloudfunctions/bf-image/commercial-artwork");
const owner="owner",items=[{key:"title",role:"title",text:"商业服务"},{key:"h",role:"label",text:"三天行动"},{key:"b",role:"body",text:"第1天确认需求\n第2天接入验证\n第3天总结方案"},{key:"c",role:"contact",text:"400-810-2026"}];
const base={structured:{text:items},prompt:"",width:1584,height:2816,content:contentOf(items)};
test("new visual engine is opt-in and canary owner restriction cannot enable other accounts",()=>{
 assert.equal(designEnabled(policyOf({enabled:true}),owner),false);assert.equal(designEnabled(policyOf({designEngine:"poster",designAccountIds:[owner]}),owner),true);assert.equal(designEnabled(policyOf({designEngine:"poster",designAccountIds:[owner]}),"other"),false);assert.equal(designEnabled(policyOf({designEngine:"poster"}),owner),true);
});
test("semantic selection creates a sequence, while optional design metadata separates style from layout",()=>{
 const normal=planOf(base);assert.equal(normal.layoutId,"timeline-sequence");
 const selected=planOf({...base,structured:{...base.structured,design_plan:{version:1,style_id:"hyperreal-product",layout_id:"split-vertical",blocks:[{text_keys:["h","b"],kind:"timeline"}]}}});
 assert.equal(selected.layoutId,"split-vertical");assert.equal(selected.styleId,"hyperreal-product");assert.equal(selected.sections[0].kind,"timeline");assert.deepEqual(selected.sections[0].items,items.slice(1,3));assert.equal(selected.artwork.aspectRatio,"4:3");
});
test("unknown IDs, inherited properties and forged section bindings cannot corrupt or drop copy",()=>{
 const invalid=planOf({...base,structured:{...base.structured,design_plan:{version:1,style_id:"__proto__",layout_id:"constructor",blocks:[{text_keys:["someone-elses-text"],kind:"metrics"}]}}});assert.equal(invalid.layoutId,"timeline-sequence");assert.equal(invalid.sections.length,1);assert.equal(invalid.sections[0].kind,"timeline");assert.ok(invalid.header.some(t=>t.key==="title"));assert.ok(invalid.footer.some(t=>t.key==="c"));
});
function actualStrings(node){if(typeof node==="string")return node;if(!node||typeof node!=="object")return "";return [].concat(node.props?.children||[]).map(actualStrings).join("");}
test("all literal copy survives scene construction and service headings precede their corresponding body",()=>{
 const plan=planOf(base),rendered=scene({plan,width:1584,height:2816,fontSize:30,background:null,palette:{},contrast,partition});const keyed=[];
 function walk(n){if(!n||typeof n!=="object")return;if(n.props?.["data-copy-key"])keyed.push([n.props["data-copy-key"],actualStrings(n)]);[].concat(n.props?.children||[]).forEach(walk);}walk(rendered.tree);
 assert.equal(keyed.length,items.length);for(const item of items)assert.equal(keyed.find(k=>k[0]===item.key)[1].replace(/\s/g,""),item.text.replace(/\s/g,""));
});
test("provider artwork brief consumes planned aspect and retains legacy 3:1 without a design plan",()=>{
 assert.match(artworkPrompt({artwork_prompt:"真实企业工作现场"},{aspectRatio:"4:3"}),/4:3构图/);assert.match(artworkPrompt({}),/3:1构图/);assert.match(artworkPrompt({},{aspectRatio:"url:invalid"}),/3:1构图/);
});
test("design metadata is optional for shipped clients, and legacy source selection is untouched",()=>{
 const {withImageToolSchema}=require("../cloudfunctions/bf-api/image-tool-schema");const input={type:"function",function:{name:"image_generate",parameters:{properties:{source_indexes:{type:"array"},structured:{type:"object"}}}}};
 const fn=withImageToolSchema([input],{commercial:true})[0].function;assert.ok(fn.parameters.properties.structured.properties.design_plan);assert.ok(!fn.parameters.properties.structured.required.includes("design_plan"));assert.deepEqual(fn.parameters.properties.source_indexes,{type:"array"});
});
test("brand-only leading section moves into the hero exactly once",()=>{
 const text=[items[0],{key:'brand',role:'label',text:'星桥安防科技'},...items.slice(1)];
 const plan=planOf({...base,structured:{text},content:contentOf(text)});
 assert.ok(plan.header.some(t=>t.key==='brand'));assert.ok(!plan.sections.flatMap(s=>s.items).some(t=>t.key==='brand'));
});
test("route and timeline emphasis retains literal source digits and cannot inject SVG attributes",()=>{
 const text=[items[0],{key:'h',role:'label',text:'路线优先级及理由'},{key:'b',role:'body',text:'A1 先看设备\nB2 再谈场景\nC3 最后对接'},items[3]];
 const plan=planOf({...base,structured:{text},content:contentOf(text)});const r=scene({plan,width:1584,height:2816,fontSize:30,background:null,palette:{},contrast,partition});
 for(const item of text){let found='';function walk(n){if(!n||typeof n!=='object')return;if(n.props?.['data-copy-key']===item.key)found=actualStrings(n);[].concat(n.props?.children||[]).forEach(walk);}walk(r.tree);assert.equal(found.replace(/\s/g,''),item.text.replace(/\s/g,''));}
 const {iconSource}=require('../cloudfunctions/bf-image/commercial-design-icons');const source=Buffer.from(iconSource('__proto__','red" onload="evil').split(',')[1],'base64').toString();assert.ok(source.includes('#173D34'));assert.ok(!source.includes('onload'));
});
test('highlight numerals retain contrast on the dark metric panel even for a white accent request',()=>{
 const text=[items[0],{key:'h',role:'label',text:'建议目标'},{key:'b',role:'body',text:'识别20位联系人\n深谈6家合作方'},items[3]];
 const plan=planOf({...base,structured:{text},content:contentOf(text)}),palette={paper:'#FFFFFF',ink:'#101820',accent:'#FFFFFF',explicit:true};
 const rendered=scene({plan,width:1584,height:2816,fontSize:30,palette,contrast,partition});let color;
 function walk(n){if(!n||typeof n!=='object')return;if(n.props?.children==='20')color=n.props.style.color;[].concat(n.props?.children||[]).forEach(walk);}walk(rendered.tree);
 assert.ok(color);assert.ok(contrast(color,palette.ink)>=3);
});
test('brand highlight preserves its orange hue rather than flattening both surfaces to the ink color',()=>{
 const {accessibleAccent}=require('../cloudfunctions/bf-image/commercial-poster-scene');
 const requested='#FFB34D',ink='#162D4C';const light=accessibleAccent(requested,'#F1F5FA',ink,contrast);
 assert.ok(contrast(light,'#F1F5FA')>=3);assert.notEqual(light,ink);assert.ok(parseInt(light.slice(1,3),16)>parseInt(light.slice(5,7),16));
 assert.equal(accessibleAccent(requested,ink,'#FFFFFF',contrast),requested);
});
