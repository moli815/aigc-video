"use strict";
// Offline typography regression. Requires the recorded synthetic plans and the
// OFL Noto font files in outputs; never calls a model or changes cloud settings.
const fs=require("node:fs"),path=require("node:path"),cp=require("node:child_process");
const {compose}=require("../cloudfunctions/bf-image/commercial-composer");
const {loadEngines,EMPTY}=require("../cloudfunctions/bf-image/commercial-composition-runtime");
const root=path.resolve("outputs/commercial-text-repair-20261104");
const cases=[
  ["A-expo-guide",1584,2816,"run-20261104111102"],
  ["B-procurement-matrix",2816,1584,"run-20261104111102"],
  ["C-implementation-map",1776,2368,"run-20261104111102"],
  ["D-memory-wide-board",3544,1184,"run-20261104112705"],
  ["E-revision-injection",1584,2816,"run-20261104111102"],
  ["F-reference-redesign",1584,2816,"run-20261104111102"],
];
(async()=>{
 const engines=await loadEngines();const fonts=[400,700].map(weight=>({name:"Noto CJK",weight,style:"normal",data:fs.readFileSync(path.join(root,"fonts/NotoSansCJKsc-"+(weight===400?"Regular":"Bold")+".otf"))}));
 const report=[];
 for(const [id,width,height,run]of cases){
  const plan=JSON.parse(fs.readFileSync(path.resolve("outputs/complex-image-eval-20261104",run,id+"-plan.json"),"utf8"));const started=Date.now();
  try{
   const withArt=await compose({structured:plan.structured,prompt:plan.prompt,width,height,fonts,background:EMPTY,...engines});
   const out=await compose({structured:plan.structured,prompt:plan.prompt,width,height,fonts,...engines});
   const file=path.join(root,id+"-composed.png");fs.writeFileSync(file,out.png);fs.writeFileSync(path.join(root,id+"-manifest.json"),JSON.stringify(out.manifest,null,2));
   const result={id,ok:true,fontSize:out.manifest.fontSize,artworkFontSize:withArt.manifest.fontSize,items:out.manifest.itemCount,ms:Date.now()-started,rssMB:Math.round(process.memoryUsage().rss/1048576),
    note:"Only typography is tested. Existing planning mistakes are intentionally not rewritten or hidden."};
   if(process.platform==="win32"){
    const ocr=path.join(root,id+"-composed-ocr.json");cp.execFileSync("powershell.exe",["-NoProfile","-ExecutionPolicy","Bypass","-File","scripts/local-image-ocr.ps1","-ImagePath",file,"-OutputPath",ocr],{timeout:60000,stdio:"pipe"});
    const text=JSON.parse(fs.readFileSync(ocr,"utf8")).text.replace(/\s/g,"");
    result.ocrContactChecks=(plan.structured.text.map(t=>t.text).join("\n").match(/400-\d{3}-\d{4}/g)||[]).map(expected=>({expected,found:text.includes(expected)}));
   }
   report.push(result);
  }catch(e){report.push({id,ok:false,code:e.code||"COMPOSITION_FAILED"});process.exitCode=1;}
 }
 fs.writeFileSync(path.join(root,"offline-composition-results.json"),JSON.stringify(report,null,2));console.log(JSON.stringify(report));
})().catch(e=>{console.error(e.code||e.name);process.exitCode=1;});
