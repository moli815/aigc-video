"use strict";
// Executes a bounded design plan. Styles are separate from semantic layouts.
// Source text is never summarized or sent through a native text painter here.
const {library}=require("./commercial-design-plan");
const {iconSource}=require("./commercial-design-icons");
const el=(type,style,children,props={})=>({type,props:{...props,style:{boxSizing:"border-box",...style},children}});
function mix(a,b,amount){const bytes=[1,3,5].map(i=>Math.round(parseInt(a.slice(i,i+2),16)*(1-amount)+parseInt(b.slice(i,i+2),16)*amount));return "#"+bytes.map(n=>n.toString(16).padStart(2,"0")).join("");}
function accessibleAccent(color,background,fallback,contrast){
 if(contrast(color,background)>=3)return color;
 for(const amount of [.15,.3,.45,.6,.75,.9]){const adjusted=mix(color,fallback,amount);if(contrast(adjusted,background)>=3)return adjusted;}
 return fallback;
}
function scene({plan,width,height,fontSize,background,palette,contrast,partition}){
 const preset=library.styles[plan.styleId];
 const explicit=palette.explicit;
 const selected=explicit?palette:{paper:preset.paper,ink:preset.ink,accent:preset.accent};
 const p={...selected,accent:accessibleAccent(selected.accent,selected.paper,selected.ink,contrast)};
 const hero=explicit?(contrast(p.paper,"#FFFFFF")>4.5?p.paper:p.ink):preset.hero;
 const heroInk=contrast(hero,"#FFFFFF")>=4.5?"#FFFFFF":"#101820";
 const accentOnDark=accessibleAccent(selected.accent,hero,heroInk,contrast);
 const margin=Math.round(Math.min(width,height)*.034),gap=Math.round(fontSize*.68),inner=width-margin*2;
 const consumed=[];
 const mark=(item,children,style={})=>{consumed.push(item.key);return el("div",{display:"flex",flexDirection:"column",flexShrink:0,...style},children,{"data-copy-key":item.key});};
 const copy=(item,scale=1,style={})=>mark(item,item.text,{fontSize:fontSize*scale,lineHeight:1.43,whiteSpace:"pre-wrap",wordBreak:"break-word",fontWeight:item.role==="title"?700:400,...style});
 const goodInk=color=>contrast(color,p.ink)>=4.5?p.ink:contrast(color,"#FFFFFF")>=4.5?"#FFFFFF":"#101820";
 const edge=mix(p.accent,p.paper,.7),tint=mix(p.accent,p.paper,.94);
 const icon=(kind,size=fontSize*1.6,color=p.accent)=>el('img',{width:size,height:size,flexShrink:0},undefined,{src:iconSource(kind,color)});
 function splitLines(item,kind){
  const lines=item.text.split("\n");
  const meaningful=lines.filter(s=>s.trim());
  if(kind==="route"&&meaningful.length>4)kind="timeline";
  if(kind==="metrics"&&meaningful.length>=2&&meaningful.length<=5){
   const full=inner-gap*2,cell=(full-gap*(meaningful.length-1))/meaningful.length;
   const children=lines.map((line,i)=>{
    const match=line.match(/^(.*?)(\d+(?:\.\d+)?(?:%|％)?)([\s\S]*)$/);
    return el("div",{display:"flex",flexDirection:"column",width:cell,flexShrink:0,padding:gap*.6,gap:fontSize*.15},match?[
      el("div",{display:"flex",fontSize:fontSize*.9,fontWeight:700},match[1]),
      el("div",{display:"flex",fontSize:fontSize*2.6,lineHeight:1.05,fontWeight:700,color:accentOnDark},match[2]),
      el("div",{display:"flex",fontSize:fontSize*.96,lineHeight:1.4,whiteSpace:"pre-wrap",wordBreak:"break-word"},match[3])
    ]:line);
   });
   // Empty lines are retained as textual separators, not additional metric cells.
   if(lines.length===meaningful.length)return mark(item,children,{display:"flex",flexDirection:"row",gap,width:full});
  }
  if(kind==="route"&&meaningful.length>=2&&meaningful.length<=4&&lines.length===meaningful.length){
   return mark(item,meaningful.map((line,i)=>el("div",{display:"flex",flexDirection:"column",width:(inner-gap*2-gap*(meaningful.length-1))/meaningful.length,flexShrink:0,borderTop:"5px solid "+p.accent,paddingTop:gap*.5},[
    ...(line.match(/^[A-Z]\d{1,2}/)?[
      el('div',{display:'flex',fontSize:fontSize*2.2,fontWeight:700,lineHeight:1.15,color:p.accent,paddingBottom:gap*.4},line.match(/^[A-Z]\d{1,2}/)[0]),
      el('div',{display:'flex',fontSize,lineHeight:1.43,whiteSpace:'pre-wrap',wordBreak:'break-word'},line.replace(/^[A-Z]\d{1,2}/,''))
    ]:[icon('route'),el("div",{display:"flex",fontSize,lineHeight:1.43,whiteSpace:"pre-wrap",wordBreak:"break-word"},line)])
   ])),{flexDirection:"row",gap});
  }
  if(kind==="timeline"&&meaningful.length>=3&&meaningful.length<=8&&lines.length===meaningful.length&&Math.max(...meaningful.map(s=>s.length))<140){
   const columns=meaningful.length===3||Math.max(...meaningful.map(s=>s.length))<65?3:2;
   const cell=(inner-gap*2-gap*(columns-1))/columns;
   return mark(item,meaningful.map(line=>{
    const lead=line.match(/^(第[一二三四五六七八九十\d]+[天周]|[①-⑳])([\s\S]*)$/);
    return el("div",{display:"flex",flexDirection:'column',width:cell,flexShrink:0,padding:gap*.6,borderTop:"5px solid "+p.accent,backgroundColor:tint,fontSize,lineHeight:1.4,whiteSpace:"pre-wrap",wordBreak:"break-word"},lead?[
      el('div',{display:'flex',fontSize:fontSize*1.6,lineHeight:1.2,color:p.accent,fontWeight:700,marginBottom:gap*.5},lead[1]),
      el('div',{display:'flex',fontSize,lineHeight:1.43,whiteSpace:'pre-wrap',wordBreak:'break-word'},lead[2])]:line);
   }),{flexDirection:"row",flexWrap:"wrap",gap,width:inner-gap*2});
  }
  if(kind==="timeline"&&meaningful.length>=3&&meaningful.length<=8&&lines.length===meaningful.length){
   return mark(item,meaningful.map((line,i)=>el("div",{display:"flex",flexDirection:"row",paddingBottom:gap*.6,flexShrink:0},[
     el("div",{display:"flex",width:fontSize*1.8,flexShrink:0,borderLeft:"4px solid "+p.accent,marginLeft:fontSize*.6}),
     el("div",{display:"flex",fontSize,lineHeight:1.43,whiteSpace:"pre-wrap",wordBreak:"break-word",flexGrow:1,padding:gap*.45,backgroundColor:i%2?tint:p.paper},line)
   ])),{width:inner-gap*2});
  }
  return copy(item);
 }
 function block(section,w,full=false){
  const headings=section.items.filter(t=>t.role!=="body"),bodies=section.items.filter(t=>t.role==="body");
  const featured=full&&["metrics","route","timeline"].includes(section.kind);
  const backgroundColor=featured&&section.kind==="metrics"?hero:section.kind==="checklist"?tint:p.paper;
  const headingNodes=headings.map(item=>{
   const number=section.kind==="services"?item.text.match(/^(\d{1,2})([\s\S]+)$/):null;
   if(number)return mark(item,[el("div",{display:"flex",fontSize:fontSize*2.5,lineHeight:1,color:p.accent,fontWeight:700,marginRight:gap*.65},number[1]),el("div",{display:"flex",fontSize:fontSize*1.35,lineHeight:1.3,fontWeight:700,alignSelf:"center"},number[2])],{flexDirection:"row",paddingBottom:gap*.65});
   const size=fontSize*1.55;
   return el('div',{display:'flex',gap:gap*.5,alignItems:'center',paddingBottom:gap*.6,marginBottom:gap*.4},[icon(section.kind,size),copy(item,1.24,{fontWeight:700,color:goodInk(backgroundColor),lineHeight:1.3,flexShrink:1})]);
  });
  return el("div",{display:"flex",width:w,flexDirection:"column",flexShrink:0,color:goodInk(backgroundColor),backgroundColor,padding:gap,border:featured?"1px solid "+edge:"0px",borderRadius:preset.radius},[
    ...headingNodes,
    el("div",{display:"flex",flexDirection:"column",gap:gap*.45,flexShrink:0},bodies.map(t=>full?splitLines(t,section.kind):copy(t)))
  ]);
 }
 const children=[];
 const heroH=Math.round(Math.min(height*(plan.layoutId==="split-vertical"?.28:plan.layoutId==="modular-grid"?.17:.18),width*.52));
 const split=plan.artwork.placement==="split";
 const hasArt=background&&plan.artwork.placement!=="none";
 const headerW=split?inner*.51:inner*.66;
 const photo=hasArt?el("img",{position:"absolute",top:0,right:0,width:split?width*.48:width,height:heroH,objectFit:split?"contain":"cover",opacity:split?1:.9},undefined,{src:background}):null;
 children.push(el("div",{display:"flex",position:"relative",minHeight:heroH,flexDirection:"column",backgroundColor:hero,padding:margin,color:heroInk,flexShrink:0,borderBottom:"7px solid "+p.accent},[
   ...(photo?[photo]:[]),
   ...(hasArt&&!split?[el("div",{position:"absolute",top:0,left:0,width,height:heroH,backgroundImage:"linear-gradient(90deg,"+hero+"F5 0%,"+hero+"D9 35%,"+hero+"40 75%,"+hero+"00 100%)"})]:[]),
   el("div",{display:"flex",position:"relative",flexDirection:"column",width:headerW,gap:gap*.6,paddingTop:gap,flexShrink:0},plan.header.map(t=>copy(t,t.role==="title"?2.8:.98,{fontWeight:t.role==="title"?700:400,lineHeight:t.role==="title"?1.15:1.45,color:t.role==="label"?accentOnDark:heroInk})))
 ]));
 const body=[];
 const sections=[...plan.sections];
 if(plan.matrix){
  const m=plan.matrix,widths=[.18,.2733,.2733,.2734],cells=(texts,header)=>texts.map((value,i)=>el("div",{display:"flex",width:(inner-gap*2)*widths[i],padding:gap*.45,fontSize:fontSize*(header?1.1:1),fontWeight:header||i===0?700:400,whiteSpace:"pre-wrap",wordBreak:"break-word"},value));
  let header;
  if(m.caption){consumed.push(m.caption.key);header=el("div",{display:"flex",backgroundColor:hero,color:heroInk},cells(m.labels,true),{"data-copy-key":m.caption.key});}
  else header=el("div",{display:"flex",backgroundColor:hero,color:heroInk},m.labels.map((t,i)=>copy(t,1.1,{width:(inner-gap*2)*widths[i],padding:gap*.45,fontWeight:700})));
  if(m.packed)consumed.push(m.packed.key);
  const rows=m.rows.map((row,i)=>{if(!m.packed)consumed.push(row.item.key);return el("div",{display:"flex",backgroundColor:i%2?p.paper:tint,borderBottom:"1px solid "+edge},cells([row.label,...row.cells],false),m.packed?{}:{"data-copy-key":row.item.key});});
  body.push(el("div",{display:"flex",width:inner,flexDirection:"column",border:"1px solid "+edge,borderRadius:preset.radius,overflow:"hidden",flexShrink:0},[header,el("div",{display:"flex",flexDirection:"column"},rows,m.packed?{"data-copy-key":m.packed.key}:{})]));
 }
 // Preserve section reading order. Full-width semantic systems interrupt the
 // ordinary grid; the grid is one component, never the entire design.
 let pending=[];
 function flush(){if(!pending.length)return;const columns=width/height>=2.4?3:2;
  if(plan.layoutId==="modular-grid"){
   const colW=(inner-gap*(columns-1))/columns;
   for(let i=0;i<pending.length;i+=columns)body.push(el("div",{display:"flex",width:inner,flexDirection:"row",gap,alignItems:"stretch",flexShrink:0},pending.slice(i,i+columns).map(s=>block(s,colW))));
  }else{
   const groups=partition(pending,columns),colW=(inner-gap*(groups.length-1))/groups.length;
   body.push(el("div",{display:"flex",width:inner,flexDirection:"row",gap,flexShrink:0},groups.map(group=>el("div",{display:"flex",width:colW,flexDirection:"column",gap,flexShrink:0},group.map(s=>block(s,colW))))));
  }
  pending=[];
 }
 for(const section of sections){
  const bodyText=section.items.filter(t=>t.role==="body").map(t=>t.text).join("\n");
  const lines=bodyText.split("\n").filter(Boolean).length;
  const full=width/height<2.4&&["metrics","route","timeline"].includes(section.kind)&&lines>=2&&lines<=8&&bodyText.length<750;
  if(full){flush();body.push(block(section,inner,true));}else pending.push(section);
 }
 flush();
 const footerBg=hero;
 if(plan.footer.length)body.push(el("div",{display:"flex",width:inner,flexDirection:"column",gap:gap*.3,backgroundColor:footerBg,color:heroInk,padding:gap,borderRadius:preset.radius,flexShrink:0},plan.footer.map(t=>copy(t,t.role==="contact"?1.15:.9))));
 children.push(el("div",{display:"flex",flexDirection:"column",width,gap,padding:margin,flexShrink:0},body));
 return {tree:el("div",{display:"flex",flexDirection:"column",position:"relative",width,height,color:p.ink,backgroundColor:p.paper,fontFamily:"Noto CJK"},children),consumed,margin:0};
}
module.exports={scene,mix,accessibleAccent};
