"use strict";
// Offline, fixed copy and stored synthetic artwork; no customer records,
// provider calls, new keys, or changes to production settings.
const fs=require("fs"),path=require("path"),assert=require("assert/strict");
const {compose}=require("../cloudfunctions/bf-image/commercial-composer");
const {loadEngines}=require("../cloudfunctions/bf-image/commercial-composition-runtime");
const root=path.resolve("outputs/poster-design-20261104");fs.mkdirSync(root,{recursive:true});
const old="outputs/commercial-text-repair-20261104/live/run-20261104135813";
const recent="outputs/commercial-text-repair-20261104/live/run-20261104165552";
const cases=[
 ["A-expo-guide",1584,2816,old,old],
 ["D-memory-wide-board",1776,2368,old,old,"product-portrait"],
 ["E-revision-injection",1584,2816,old,old],
 ["B-procurement-matrix",2816,1584,old,old],
 ["C-implementation-map",1776,2368,"outputs/commercial-text-repair-20261104/live/run-20261104170930",recent],
 ["D-memory-wide-board",3544,1184,old,old],
 ["F-reference-redesign",1584,2816,old,old]
];
(async()=>{const engines=await loadEngines();const fonts=[400,700].map(weight=>({name:"Noto CJK",weight,style:"normal",data:fs.readFileSync("outputs/commercial-text-repair-20261104/fonts/NotoSansCJKsc-"+(weight===400?"Regular":"Bold")+".otf")}));const report=[];
for(const [id,width,height,plans,artRoot,alias]of cases){const label=alias||id;const plan=JSON.parse(fs.readFileSync(path.join(plans,id+"-plan.json"),"utf8"));const bytes=fs.readFileSync(path.join(artRoot,id+"-artwork.jpg"));const base={structured:plan.structured,prompt:plan.prompt,width,height,fonts,background:"data:image/jpeg;base64,"+bytes.toString("base64"),...engines};const started=Date.now();
try{const before=await compose({...base,designEngine:"legacy"});const after=await compose({...base,designEngine:"poster"});assert.equal(before.manifest.copyHash,after.manifest.copyHash);assert.equal(after.manifest.itemCount,plan.structured.text.length);
fs.writeFileSync(path.join(root,label+"-before.png"),before.png);fs.writeFileSync(path.join(root,label+"-after.png"),after.png);fs.writeFileSync(path.join(root,label+"-manifest.json"),JSON.stringify(after.manifest,null,2));report.push({id:label,ok:true,width,height,copyChars:plan.structured.text.reduce((n,t)=>n+t.text.length,0),copyHash:after.manifest.copyHash,fontSize:after.manifest.fontSize,baselineFontSize:before.manifest.fontSize,design:after.manifest.design,artwork:after.manifest.artwork,ms:Date.now()-started,rssMB:Math.round(process.memoryUsage().rss/1048576)});
}catch(e){report.push({id:label,ok:false,code:e.code||e.name,ms:Date.now()-started});process.exitCode=1;}}
fs.writeFileSync(path.join(root,"offline-results.json"),JSON.stringify(report,null,2));console.log(JSON.stringify(report));})().catch(e=>{console.error(e.code||e.name);process.exitCode=1;});
