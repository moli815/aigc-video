"use strict";
// Geometry validation is deterministic; the LLM still chooses content and style.
// Valid authored scenes pass through. An invalid complete scene is fitted to an
// editorial reading order so old clients do not silently fall back or omit text.
function validScene(items, blocks) {
  if (!Array.isArray(blocks) || blocks.length !== items.length) return false;
  if (new Set(items.map(t=>t.key)).size!==items.length || new Set(blocks.map(t=>t.key)).size!==items.length) return false;
  if (!blocks.every(b=>items.some(t=>t.key===b.key)&&[b.x,b.y,b.width,b.height].every(Number.isFinite)&&
    b.x>=.02&&b.y>=.02&&b.width>=.04&&b.height>=.025&&b.x+b.width<=.98&&b.y+b.height<=.98)) return false;
  return !blocks.some((a,i)=>blocks.slice(i+1).some(b=>Math.min(a.x+a.width,b.x+b.width)>Math.max(a.x,b.x)&&Math.min(a.y+a.height,b.y+b.height)>Math.max(a.y,b.y)));
}
function fitTextScene(structured) {
  const items=structured?.text, layout=structured?.layout;
  if (!Array.isArray(items)||!items.length||!layout||!Array.isArray(layout.blocks)||validScene(items,layout.blocks)) return structured;
  if (items.some(t=>!t||typeof t.text!=="string"||typeof t.key!=="string")||new Set(items.map(t=>t.key)).size!==items.length) return structured;
  const gap=.006,top=.04,space=.92-gap*(items.length-1),minimum=.026;
  if (space<minimum*items.length) return structured; // do not pretend arbitrary copy fits
  const weights=items.map(t=>Math.max(1,t.text.split("\n").reduce((n,line)=>n+Math.max(1,Math.ceil([...line].length/38)),0)));
  const total=weights.reduce((a,b)=>a+b,0),extra=space-minimum*items.length;
  let y=top;
  const blocks=items.map((item,i)=>{
    const prior=layout.blocks.find(b=>b.key===item.key)||{};
    const height=minimum+extra*weights[i]/total;
    const block={...prior,key:item.key,x:.04,y:Math.round(y*1e7)/1e7,width:.92,height:Math.floor(height*1e7)/1e7};
    y+=height+gap;return block;
  });
  if(!validScene(items,blocks))return structured;
  return {...structured,layout:{...layout,preset:"editorial",blocks}};
}
module.exports={validScene,fitTextScene};
