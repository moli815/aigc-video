"use strict";
// Provider-owned layer coordinates + semantic key assignment, never VLM pixel
// coordinates or generated text. One role stack per native layer, not a global
// poster template. Rendering and overflow validation remain separate.
const error=code=>Object.assign(new Error(code),{code});
function geometry(rows,width,height){
 const seen=new Set();return rows.filter(r=>r.background==="transparent").map(r=>{const b=r.bounding_box?.absolute;if(!Number.isInteger(r.index)||seen.has(r.index)||!Array.isArray(b)||b.length!==4||b.some(n=>!Number.isFinite(n))||b[0]<0||b[1]<0||b[2]<=b[0]||b[3]<=b[1]||b[2]>width||b[3]>height)throw error("NATIVE_LAYER_GEOMETRY_INVALID");seen.add(r.index);return{index:r.index,x:b[0],y:b[1],width:b[2]-b[0],height:b[3]-b[1]};});
}
function ruleRows(background,x,y,width,height){
 if(!background)return [];
 const hits=[];for(let row=Math.max(0,Math.floor(y));row<Math.min(background.height,Math.ceil(y+height));row++){
  let dark=0,total=0;for(let col=Math.max(0,Math.floor(x));col<Math.min(background.width,Math.ceil(x+width));col+=3){const i=(row*background.width+col)*4;total++;if(Math.min(background.data[i],background.data[i+1],background.data[i+2])<205)dark++;}
  if(total&&dark/total>.48)hits.push(row);
 }
 const spans=[];for(const row of hits){const last=spans.at(-1);if(last&&last[1]===row-1)last[1]=row;else spans.push([row,row]);}return spans.filter(([a,b])=>b-a<8);
}
async function planOf({rows,width,height,items,assignments,measure,background}){
 if(!Array.isArray(assignments)||!Array.isArray(items)||!items.length)throw error("NATIVE_LAYER_ASSIGNMENT_INVALID");
 const layers=geometry(rows,width,height),byLayer=new Map(layers.map(l=>[l.index,l])),copy=new Map(items.map(t=>[t.key,t])),used=new Set(),assigned=new Set(),blocks=[],surfaces=[];
 if(copy.size!==items.length)throw error("NATIVE_LAYER_ASSIGNMENT_INVALID");
 for(const a of assignments){
  if(!byLayer.has(a.layer)||assigned.has(a.layer)||!Array.isArray(a.keys)||!a.keys.length||a.keys.some(k=>!copy.has(k)||used.has(k))||new Set(a.keys).size!==a.keys.length)throw error("NATIVE_LAYER_ASSIGNMENT_INVALID");
  assigned.add(a.layer);a.keys.forEach(k=>used.add(k));
 }
 if(used.size!==items.length)throw error("NATIVE_LAYER_ASSIGNMENT_INVALID");
 const fontSize=t=>t.role==="title"?Math.round(width*.053):t.role==="contact"?Math.round(width*.025):Math.round(Math.max(25,width*(["label","footer"].includes(t.role)?.016:.014)));
 for(const a of assignments){
  const origin={...byLayer.get(a.layer)},line=a.keys.map(k=>copy.get(k)),margin=width*.04,identity=origin.y/height<.08,footer=line.every(t=>["contact","footer"].includes(t.role));
  if(footer&&origin.x<margin){origin.width-=2*(margin-origin.x);origin.x=margin;}
  const neighbours=layers.filter(l=>l.index!==origin.index&&l.x>=origin.x+origin.width*.8&&l.y<origin.y+origin.height&&origin.y<l.y+l.height);
  const right=neighbours.length?Math.min(...neighbours.map(n=>(n.x+origin.x+origin.width)/2)):Math.max(origin.x+origin.width,width-margin);
  const containerWidth=Math.floor(right-origin.x),gap=identity?0:width*.006,color=origin.y/height>.93?"#FFFFFF":"#171717",rules=color==="#FFFFFF"?[]:ruleRows(background,origin.x,origin.y,containerWidth,origin.height);
  let y=origin.y,maxRight=origin.x,maxBottom=origin.y;
  if(footer){
   const cellWidth=(containerWidth-gap*(line.length-1))/line.length;
   const measured=await Promise.all(line.map(t=>measure(t.text,cellWidth,fontSize(t),700))),rowHeight=Math.max(...measured)+2;y+=Math.max(0,(origin.height-rowHeight)/2);
   for(const [i,t]of line.entries()){const size=fontSize(t),h=measured[i];blocks.push({key:t.key,box:[(origin.x+i*(cellWidth+gap))/width,y/height,Math.floor(cellWidth)/width,Math.ceil(h+2)/height],fontSize:size,weight:700,color,align:i?"right":"left"});maxBottom=Math.max(maxBottom,y+h+2);}maxRight=right;
  }else{
   for(const t of line){const size=identity?Math.max(25,Math.round(width*.014)):fontSize(t),weight=["title","label"].includes(t.role)?700:400,h=await measure(t.text,containerWidth,size,weight);for(const [top,bottom]of rules)if(y<bottom+4&&y+h+2>top-4)y=bottom+5;blocks.push({key:t.key,box:[origin.x/width,y/height,containerWidth/width,Math.ceil(h+2)/height],fontSize:size,weight,color,align:"left"});y+=Math.ceil(h+2)+gap;maxBottom=y-gap;maxRight=right;}
  }
  const next=layers.filter(l=>l.index!==origin.index&&l.y>=origin.y+origin.height*.6&&l.x<maxRight&&origin.x<l.x+l.width).sort((a,b)=>a.y-b.y)[0];
  const limit=next?next.y-gap:height;
  // Only the top identity band may grow vertically into its blank header gap.
  if(maxBottom>height||maxBottom>limit||maxBottom>origin.y+origin.height+(origin.y/height<.08?height*.035:3))throw Object.assign(error("NATIVE_LAYER_CAPACITY"),{layer:a.layer});
  surfaces.push({box:[origin.x/width,origin.y/height,containerWidth/width,(maxBottom-origin.y)/height],color:color==="#FFFFFF"?"#BD091E":"#FFFFFF"});
 }
 // Reserve the largest native non-text horizontal band in its entirety. This
 // strategy deliberately declines dense full-bleed designs without such a band;
 // it must not invent a harmless dummy "protected" corner to pass validation.
 const spans=layers.map(l=>[l.y,l.y+l.height]).sort((a,b)=>a[0]-b[0]),gaps=[];let end=0;
 for(const [top,bottom]of spans){if(top>end)gaps.push([end,top]);end=Math.max(end,bottom);}
 const band=gaps.filter(g=>g[0]>0&&g[1]-g[0]>height*.1).sort((a,b)=>(b[1]-b[0])-(a[1]-a[0]))[0];
 if(!band)throw error("NATIVE_LAYER_GRAPHIC_BAND_UNCERTAIN");
 return {protected:[[0,band[0]/height,1,(band[1]-band[0])/height]],surfaces,blocks};
}
module.exports={geometry,planOf,ruleRows};
