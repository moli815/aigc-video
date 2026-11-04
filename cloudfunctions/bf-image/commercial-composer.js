"use strict";
// A deterministic typography adapter, independent of providers and accounts.
// Satori performs shaping/line breaking; resvg rasterizes embedded glyph paths.
// Fonts are fetched by the runtime adapter, never from user-authored SVG/URLs.
const crypto = require("node:crypto");
const VERSION = "commercial-composer-v1";
function fail(code) { return Object.assign(new Error(code), { code }); }
function policyOf(raw) {
  let p; try { p = typeof raw === "string" ? JSON.parse(raw) : raw; } catch { p = {}; }
  return { enabled: p?.enabled === true, minChars: Math.max(250, Math.min(1200, Number(p?.minChars) || 420)),
    accountIds:Array.isArray(p?.accountIds)?p.accountIds.filter(a=>typeof a==="string").slice(0,20):null,
    designEngine:p?.designEngine==="poster"?"poster":"legacy",designAccountIds:Array.isArray(p?.designAccountIds)?p.designAccountIds.filter(a=>typeof a==="string").slice(0,20):null,
    fonts: Array.isArray(p?.fonts) ? p.fonts.filter(f => f && /^cloud:\/\//.test(f.fileId || "") && /^[a-f0-9]{64}$/.test(f.sha256 || "") && [400,700].includes(f.weight)).slice(0,2) : [] };
}
function eligible(input, policy) {
  if (!policy.enabled || (policy.accountIds&&!policy.accountIds.includes(input.accountId)) || input.textMode === "overlay" || input.layerDecomposition || input.renderIntent === "mockup") return false;
  if(Array.isArray(input.structured?.preserve_assets)&&input.structured.preserve_assets.length)return false;
  if (!["generate", "reference", ""].includes(input.taskKind || "")) return false;
  const text = input.structured?.text;
  return Array.isArray(text) && text.length >= 4 && text.every(t => t && typeof t.key === "string" &&
    ["title","subtitle","label","body","contact","footer"].includes(t.role) && typeof t.text === "string" && t.text.trim()) &&
    text.reduce((n,t) => n+t.text.length,0) >= policy.minChars;
}
function paletteOf(structured, prompt) {
  const p = structured?.print_style?.palette;
  if (p && ["background","ink","accent"].every(k => /^#[0-9a-f]{6}$/i.test(p[k] || ""))) {
    // Contrast is verified below; invalid light-on-light palettes do not pass.
    return { paper:p.background, ink:p.ink, accent:p.accent };
  }
  const intent = [structured?.design_brief?.visual_approach, prompt].filter(Boolean).join(" ").split(/[。；;\n]/).filter(s=>!/(不要|避免|禁止|不使用|不用)/.test(s)).join(" ");
  if(/深蓝底|暗色|深色背景|深蓝背景/.test(intent))return {paper:"#102039",ink:"#EAF2FA",accent:"#64C6E8"};
  if (/森林绿|深绿|墨绿|forest/i.test(intent)) return {paper:"#F7F3E9",ink:"#183C34",accent:"#B65A2D"};
  if (/朱红|赭红|暖|橙|warm|orange/i.test(intent)) return {paper:"#FBF5E9",ink:"#253A3E",accent:"#C54E26"};
  if (/深蓝|墨蓝|科技|blue/i.test(intent)) return {paper:"#F1F5FA",ink:"#162D4C",accent:"#216CBA"};
  return {paper:"#F5F6F4",ink:"#202E34",accent:"#15776E"};
}
function luminance(hex) {
  const s = hex.slice(1).match(/../g).map(n => parseInt(n,16)/255).map(n => n<=.04045?n/12.92:((n+.055)/1.055)**2.4);
  return s[0]*.2126+s[1]*.7152+s[2]*.0722;
}
function contrast(a,b) { const x=luminance(a),y=luminance(b); return (Math.max(x,y)+.05)/(Math.min(x,y)+.05); }
function orderSectionLabels(items){
 const ordered=[...items],base=key=>String(key).replace(/[_-](?:label|head|heading|title|body|text|content)$/i,"");
 for(const heading of items.filter(t=>["label","subtitle"].includes(t.role))){
   const bodies=items.filter(t=>t.role==="body"&&base(t.key)===base(heading.key));if(bodies.length!==1)continue;
   const hi=ordered.indexOf(heading),bi=ordered.indexOf(bodies[0]);if(hi>bi){ordered.splice(hi,1);ordered.splice(bi,0,heading);}
 }
 return ordered;
}
function sectionsOf(items) {
  const header=[],footer=[],sections=[];
  let started=false;
  const firstTitle=items.findIndex(t=>t.role==="title");
  for (const [index,item] of items.entries()) {
    if (index===firstTitle || (index<firstTitle&&item.role==="label"&&item.text.length<60) || (item.role === "subtitle"&&!started&&!header.some(t=>t.role==="subtitle"))) header.push(item);
    else if (item.role === "contact" || item.role === "footer") footer.push(item);
    else {
      started=true;
      if (["label","subtitle","title"].includes(item.role)&&item.text.length<70)sections.push({items:[item]});
      else if (sections.length && ["label","subtitle","title"].includes(sections.at(-1).items[0].role))sections.at(-1).items.push(item);
      else sections.push({items:[item]});
    }
  }
  return {header,footer,sections};
}
function partition(sections, columns) {
  const n=sections.length,k=Math.min(columns,n);if(!n)return [];
  const sums=[0];for(const s of sections)sums.push(sums.at(-1)+s.items.reduce((m,t)=>m+t.text.length,0)+65);
  // Exact contiguous linear partition: minimize the longest column while
  // retaining editorial reading order. A short specification card must not
  // strand a whole column and force two long sections into the last one.
  const dp=Array.from({length:k+1},()=>Array(n+1).fill(Infinity));
  const cut=Array.from({length:k+1},()=>Array(n+1).fill(0));dp[0][0]=0;
  for(let c=1;c<=k;c++)for(let end=c;end<=n;end++)for(let start=c-1;start<end;start++){
    const score=Math.max(dp[c-1][start],sums[end]-sums[start]);if(score<dp[c][end]){dp[c][end]=score;cut[c][end]=start;}
  }
  const groups=[];let end=n;for(let c=k;c>0;c--){const start=cut[c][end];groups.unshift(sections.slice(start,end));end=start;}return groups;
}
function node(type, style, children, props={}) { return {type,props:{...props,style:{boxSizing:"border-box",...style},children}}; }
function tableRows(items) {
  // Preserve rows as authored. No LLM reformulation, numeric coercion or sorting.
  const rows=[];
  for(const item of items){
    const lines=item.text.split("\n");
    if(lines.length!==1 || !/[｜|]/.test(item.text))return null;
    const parts=item.text.split(/[｜|]/).map(s=>s.trim());
    if(parts.length===4){if(parts.some(v=>!v))return null;rows.push({item,label:parts[0],cells:parts.slice(1)});continue;}
    if(parts.length!==3)return null;
    const match=parts[0].match(/^([^：:]{1,18})[：:](.*)$/);
    if(!match)return null;
    rows.push({item,label:match[1],cells:[match[2].trim(),...parts.slice(1)]});
  }
  return rows.length>=5?rows:null;
}
function packedMatrix(items) {
  for(let i=0;i<items.length-1;i++){
    const label=items[i],body=items[i+1];
    if(label.role!=="label"||body.role!=="body")continue;
    const header=label.text.split(/[｜|]/).map(s=>s.trim());
    const labels=header.length===4?header:header.length===2?[header[0],...header[1].split(/[·•]/).map(s=>s.trim())]:[];
    if(labels.length!==4||labels.some(s=>!s||s.length>40))continue;
    if(body.text.includes("\n")){
      const rows=tableRows(body.text.split("\n").map((text,n)=>({key:body.key+":"+n,text})));
      if(rows)return {labels,caption:label,packed:body,rows,start:i,end:i+2};
    }else{
      let end=i+1;while(end<items.length&&items[end].role==="body"&&!items[end].text.includes("\n")&&[3,4].includes(items[end].text.split(/[｜|]/).length))end++;
      const rows=tableRows(items.slice(i+1,end));if(rows)return {labels,caption:label,rows,start:i,end};
    }
  }
  return null;
}
function contentOf(items) {
  // A matrix is recognized by an unambiguous four-label header followed by at
  // least five exactly three-cell rows. Generic prose is never guessed as data.
  let matrix=packedMatrix(items);
  for(let i=4;!matrix&&i<items.length;i++){
    const labels=items.slice(i-4,i);let end=i;
    // tableRows needs five rows, so find the contiguous raw row range first.
    end=i;while(end<items.length&&items[end].role==="body"&&items[end].text.split(/[｜|]/).length===3&&!items[end].text.includes("\n"))end++;
    const rows=tableRows(items.slice(i,end));
    if(rows&&labels.every(t=>t.role==="label"&&t.text.length<40)){matrix={labels,rows,start:i-4,end};break;}
  }
  const remaining=matrix?items.filter((_,i)=>i<matrix.start||i>=matrix.end):items;
  return {...sectionsOf(orderSectionLabels(remaining)),matrix};
}
function layoutTree({items,width,height,palette,fontSize,background}) {
  const {header,footer,sections,matrix}=contentOf(items);
  const margin=Math.round(Math.min(width,height)*.035),gap=Math.round(fontSize*.8);
  const innerWidth=width-margin*2;
  const ratio=width/height,columns=ratio>=1.2?3:2;
  const consumed=[];
  const text=(item,scale=1,extra={})=>{consumed.push(item.key);const style={
    display:"flex",whiteSpace:"pre-wrap",wordBreak:"break-word",fontSize:fontSize*scale,
    lineHeight:1.45,fontWeight:item.role==="title"?700:400,flexShrink:0,...extra};
    const split=item.role==="body"?item.text.indexOf("\n"):-1;
    if(split>0&&split<45){const heading=item.text.slice(0,split),body=item.text.slice(split+1);return node("div",{...style,flexDirection:"column",gap:fontSize*.3},[
      node("div",{display:"flex",fontWeight:700,fontSize:fontSize*1.16},heading),node("div",{display:"flex",whiteSpace:"pre-wrap",wordBreak:"break-word"},body)],{"data-copy-key":item.key});}
    return node("div",style,item.text,{"data-copy-key":item.key});};
  const rootChildren=[];
  // Artwork never sits below text: a native stray mark cannot bleed through
  // pale cards. Portraits get a full-width visual band, wide boards a header
  // visual; every information surface is opaque and independently typeset.
  const showArtwork=!!background&&!matrix;
  const inlineArtwork=showArtwork&&ratio>=1.2;
  const artWidth=inlineArtwork?Math.round(ratio>=2?Math.min(width*.26,height*.39):width*.26):innerWidth;
  const headerWidth=innerWidth-(inlineArtwork?artWidth+gap*2:0);
  const headChildren=header.map(t=>text(t,t.role==="title"?2.15:1.05,{color:t.role==="title"&&contrast(palette.paper,palette.accent)>=4.5?palette.accent:palette.ink,width:headerWidth}));
  // A dedicated artwork window keeps the business visual visible without text
  // competing with the legibility of the information cards.
  const artwork=inlineArtwork?node("img",{width:artWidth,height:Math.round(artWidth/3),objectFit:"cover",borderRadius:12,marginLeft:gap*2,flexShrink:0},undefined,{src:background}):null;
  rootChildren.push(node("div",{display:"flex",width:innerWidth,flexDirection:"row",justifyContent:"space-between",paddingBottom:gap*1.3,borderBottom:`4px solid ${palette.accent}`,flexShrink:0},[
    node("div",{display:"flex",width:headerWidth,flexDirection:"column",gap:fontSize*.4,flexShrink:0},headChildren),...(artwork?[artwork]:[])]));
  if(showArtwork&&!inlineArtwork)rootChildren.push(node("img",{width:innerWidth,height:Math.round(innerWidth/3),objectFit:"cover",borderRadius:12,marginTop:gap,flexShrink:0},undefined,{src:background}));
  if(matrix){
    const widths=[.18,.2733,.2733,.2734];
    const labelNode=(value,i)=>node("div",{display:"flex",width:(innerWidth-gap*2)*widths[i],fontSize:fontSize*1.15,fontWeight:700,paddingLeft:i?gap*.4:0},value);
    if(matrix.caption)consumed.push(matrix.caption.key);if(matrix.packed)consumed.push(matrix.packed.key);
    const head=node("div",{display:"flex",width:innerWidth,padding:gap,backgroundColor:palette.ink,color:palette.paper,flexShrink:0},
      matrix.caption?matrix.labels.map(labelNode):matrix.labels.map((t,i)=>text(t,1.15,{width:(innerWidth-gap*2)*widths[i],fontWeight:700,paddingLeft:i?gap*.4:0})),matrix.caption?{"data-copy-key":matrix.caption.key}:{});
    const body=matrix.rows.map((row,index)=>{if(!matrix.packed)consumed.push(row.item.key);return node("div",{display:"flex",width:innerWidth,padding:gap*.6,borderBottom:`1px solid ${palette.accent}66`,backgroundColor:index%2?palette.paper:palette.accent+"0D",flexShrink:0},[row.label,...row.cells].map((v,i)=>node("div",{display:"flex",width:(innerWidth-gap*1.2)*widths[i],fontSize,paddingLeft:i?gap*.4:0,fontWeight:i?400:700,whiteSpace:"pre-wrap",wordBreak:"break-word"},v)),matrix.packed?{}:{"data-copy-key":row.item.key});});
    const bodyContainer=node("div",{display:"flex",flexDirection:"column",width:innerWidth,flexShrink:0},body,matrix.packed?{"data-copy-key":matrix.packed.key}:{});
    rootChildren.push(node("div",{display:"flex",flexDirection:"column",width:innerWidth,marginTop:gap,flexShrink:0},[head,bodyContainer]));
  }
  const cards=partition(sections,columns).map((group,col)=>node("div",{display:"flex",flexDirection:"column",gap,width:(width-margin*2-gap*(columns-1))/columns,flexShrink:0},group.map((s,i)=>{
    const rows=tableRows(s.items);
    if(rows){
      const children=rows.map(r=>{consumed.push(r.item.key);return node("div",{display:"flex",fontSize:fontSize*.94,borderBottom:`1px solid ${palette.accent}55`,paddingTop:fontSize*.25,paddingBottom:fontSize*.25,flexShrink:0},[
        node("div",{display:"flex",width:"23%",fontWeight:700},r.label),...r.cells.map(v=>node("div",{display:"flex",width:"25.66%",paddingLeft:fontSize*.3},v))],{"data-copy-key":r.item.key});});
      return node("div",{display:"flex",flexDirection:"column",backgroundColor:palette.paper,padding:gap,border:`1px solid ${palette.accent}66`,borderRadius:8,flexShrink:0},children);
    }
    return node("div",{display:"flex",flexDirection:"column",backgroundColor:palette.paper,padding:gap,borderTop:`3px solid ${palette.accent}`,borderBottom:`1px solid ${palette.accent}55`,borderRadius:8,gap:fontSize*.3,flexShrink:0},s.items.map(t=>text(t,["label","subtitle","title"].includes(t.role)?1.18:1,{fontWeight:["label","subtitle","title"].includes(t.role)?700:400})));
  })));
  rootChildren.push(node("div",{display:"flex",width:innerWidth,flexDirection:"row",gap,marginTop:gap,flexShrink:0},cards));
  const footerRow=ratio>=1.2&&footer.length<=3;
  if(footer.length)rootChildren.push(node("div",{display:"flex",width:innerWidth,flexDirection:footerRow?"row":"column",justifyContent:"space-between",gap:fontSize*.3,marginTop:gap,padding:gap,backgroundColor:palette.ink,color:palette.paper,borderRadius:8,flexShrink:0},footer.map(t=>text(t,t.role==="contact"?1.15:.88,{width:footerRow?(innerWidth-gap*2-fontSize*.3*(footer.length-1))/footer.length:innerWidth-gap*2}))));
  return {tree:node("div",{display:"flex",flexDirection:"column",position:"relative",width,height,padding:margin,fontFamily:"Noto CJK",color:palette.ink,backgroundColor:palette.paper},rootChildren),consumed,margin};
}
async function compose({structured,prompt,width,height,fonts,background,satori,resvg,designEngine="legacy"}) {
  const items=structured?.text;
  if(!Array.isArray(items)||!items.length||new Set(items.map(t=>t.key)).size!==items.length)throw fail("COMPOSITION_COPY_INVALID");
  if(items.length>80||items.some(t=>typeof t.text!=="string"||t.text.length>8000)||items.reduce((n,t)=>n+t.text.length,0)>12000)throw fail("COMPOSITION_COPY_LIMIT");
  if(![width,height].every(n=>Number.isInteger(n)&&n>=64&&n<=8192)||width*height>4622220)throw fail("COMPOSITION_CANVAS_INVALID");
  const palette={...paletteOf(structured,prompt),explicit:!!structured?.print_style?.palette};
  const plan=designEngine==="poster"?require("./commercial-design-plan").planOf({structured,prompt,width,height,content:contentOf(items)}):null;
  if(contrast(palette.paper,palette.ink)<4.5)throw fail("COMPOSITION_CONTRAST_INVALID");
  const short=Math.min(width,height),minimum=Math.max(18,short*.0125,width*.0075);
  const candidates=[];for(let f=short*.023;f>minimum;f*=.93)candidates.push(f);candidates.push(minimum);
  for(const fontSize of candidates){
    const {tree,consumed,margin}=plan?require("./commercial-poster-scene").scene({plan,width,height,palette,fontSize,background,contrast,partition}):layoutTree({items,width,height,palette,fontSize,background});
    if(consumed.length!==items.length||new Set(consumed).size!==items.length||items.some(t=>!consumed.includes(t.key)))throw fail("COMPOSITION_COPY_NOT_CONSUMED");
    const boxes=[];let styleError=false;
    const svg=await satori(tree,{width,height,fonts,embedFont:true,
      loadAdditionalAsset:async()=>{throw fail("COMPOSITION_GLYPH_UNAVAILABLE");},
      onStyleError:()=>{styleError=true;},onNodeDetected:n=>{
      if(n.props?.["data-copy-key"] || typeof n.props?.children==="string") boxes.push({x:n.left,y:n.top,width:n.width,height:n.height,key:n.props?.["data-copy-key"]});
    }});
    if(styleError)throw fail("COMPOSITION_STYLE_UNSUPPORTED");
    const keyed=boxes.filter(b=>b.key);
    if(keyed.length!==items.length||new Set(keyed.map(b=>b.key)).size!==items.length)throw fail("COMPOSITION_COPY_NOT_MEASURED");
    if(boxes.some(b=>![b.x,b.y,b.width,b.height].every(Number.isFinite)))throw fail("COMPOSITION_MEASURE_INVALID");
    // Containers grow rather than crop/ellipsis. Overflow forces a measured fit.
    // The outer root intentionally spans the canvas and is excluded by data key.
    const contentOverflow=boxes.some(b=>b.x<margin-1||b.y<margin-1||b.x+b.width>width-margin+1||b.y+b.height>height-margin+1);
    if(contentOverflow)continue;
    const engine=new resvg.Resvg(svg,{font:{loadSystemFonts:false}});
    let png,rendered;try{rendered=engine.render();png=Buffer.from(rendered.asPng());}finally{rendered?.free?.();engine.free?.();}
    return {png,svg,manifest:{version:plan?plan.version:VERSION,...(plan?{design:{styleId:plan.styleId,layoutId:plan.layoutId,reason:plan.reason},artwork:plan.artwork}:{}),width,height,fontSize:Number(fontSize.toFixed(2)),itemCount:items.length,
      copyHash:crypto.createHash("sha256").update(JSON.stringify(items.map(t=>[t.key,t.text]))).digest("hex"),boxes:boxes.filter(b=>b.key)}};
  }
  throw fail("COMPOSITION_CONTENT_OVERFLOW");
}
module.exports={VERSION,policyOf,eligible,paletteOf,contrast,sectionsOf,partition,layoutTree,compose,packedMatrix,orderSectionLabels,contentOf};
