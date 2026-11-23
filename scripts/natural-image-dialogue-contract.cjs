"use strict";
// Test adapter only: no production prompts or tools are changed here.
const fs=require("fs"),path=require("path"),crypto=require("crypto");
const hash=s=>crypto.createHash("sha256").update(s).digest("hex");
function readContracts(root){
 const source=fs.readFileSync(path.join(root,"BossAI/Services/ToolManifest+Schema.swift"),"utf8"),cache={};
 function definition(name){
  if(cache[name])return cache[name];
  const start=source.indexOf("= [",source.indexOf("let "+name+":"));
  if(start<0)throw Error("SCHEMA_NOT_FOUND:"+name);
  let pos=start+2;
  function ws(){while(pos<source.length){if(/\s/.test(source[pos]))pos++;else if(source.slice(pos,pos+2)==="//"){pos=source.indexOf("\n",pos);}else break;}}
  function value(){ws();if(source[pos]==='"'){const from=pos++;while(pos<source.length){if(source[pos]==="\\"){pos+=2;continue;}if(source[pos++]==='"')break;}return JSON.parse(source.slice(from,pos));}
   if(source[pos]==="["){pos++;ws();if(source[pos]==="]"){pos++;return [];}
    const first=value();ws();const object=source[pos]===":";const out=object?{}:[];let item=first;
    while(true){if(object){if(source[pos++]!==":")throw Error("SCHEMA_COLON");out[item]=value();}else out.push(item);ws();if(source[pos]===","){pos++;ws();if(source[pos]==="]"){pos++;break;}item=value();ws();continue;}if(source[pos++]!=="]")throw Error("SCHEMA_CLOSE");break;}return out;}
   const m=source.slice(pos).match(/^-?\d+(?:\.\d+)?|^[A-Za-z_][A-Za-z_0-9]*/);if(!m)throw Error("SCHEMA_TOKEN");pos+=m[0].length;
   if(m[0]==="true"||m[0]==="false")return m[0]==="true";if(/^-?\d/.test(m[0]))return Number(m[0]);return definition(m[0]);
  }
  return cache[name]=value();
 }
 const tools=["recallHistoryFunction","imageGenerateFunction","imageEditFunction"].map(n=>({type:"function",function:definition(n)}));
 const design=fs.readFileSync(path.join(root,"BossAI/Services/ImageDesignGuidance.swift"),"utf8"),m=design.match(/private static let baseInstructions = """([\s\S]*?)"""/);
 if(!m)throw Error("DESIGN_PROMPT_NOT_FOUND");
 return {tools,design:m[1].split("\n").map(s=>s.replace(/^    /,"")).join("\n"),sourceHash:hash(source),designHash:hash(design)};
}
function terms(text){const out=new Set;for(const run of text.toLowerCase().normalize("NFD").replace(/\p{M}/gu,"").match(/[\p{L}\p{N}]+/gu)||[]){const a=Array.from(run);if(/[\u3400-\u9fff]/.test(run)){for(let i=0;i<a.length-1;i++)out.add(a[i]+a[i+1]);}else if(a.length>=2)out.add(run);}for(const s of ["之前","以前","记得","我们","我的","那个","这个","一下","帮我","什么","还是","please","the","and"])out.delete(s);return out;}
// Port of ContextRecall.select lexical scoring. Storage and SwiftData are NOT simulated.
function select(records,query,limit=6){const wanted=terms(Array.from(query).slice(0,2000).join("")),bags=records.map(r=>terms(r.text)),frequency={};for(const bag of bags)for(const t of wanted)if(bag.has(t))frequency[t]=(frequency[t]||0)+1;const seen=new Set;return records.map((r,i)=>({r,score:[...wanted].filter(t=>bags[i].has(t)).reduce((s,t)=>s+Math.log(1+(records.length+1)/((frequency[t]||0)+1)),0)})).filter(x=>x.score>0).sort((a,b)=>b.score-a.score||b.r.date-a.r.date||a.r.id.localeCompare(b.r.id)).filter(x=>{if(seen.has(x.r.text))return false;seen.add(x.r.text);return true;}).slice(0,limit).map(x=>x.r);}
function resolve(args,attached,last,files,issued){
 if(args.library_refs){if(!Array.isArray(args.library_refs)||!args.library_refs.length||args.library_refs.length>4||new Set(args.library_refs).size!==args.library_refs.length)throw Error("LIBRARY_REFS_INVALID");return args.library_refs.map(id=>{if(!issued.has(id))throw Error("UNISSUED_LIBRARY_REF");const f=files.find(f=>f.id===id);if(!f)throw Error("UNKNOWN_LIBRARY_REF");return f;});}
 const indices=args.source_indexes||[args.source_index||1],pick=()=>[...new Set(indices)].map(i=>{if(!Number.isInteger(i)||i<1||i>attached.length)throw Error("MISSING_CURRENT_ATTACHMENT");return attached[i-1];});
 switch(args.source||"none"){case "none":return [];case "attached":return pick();case "last":if(!last)throw Error("MISSING_GENERATED_BASE");return [last];case "both":if(!last)throw Error("MISSING_GENERATED_BASE");return [last,pick()[0]];default:throw Error("INVALID_SOURCE");}
}
module.exports={readContracts,terms,select,resolve,hash};
