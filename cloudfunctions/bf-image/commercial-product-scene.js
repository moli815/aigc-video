"use strict";
// Art-directed product compositions reuse the project's Satori/resvg engine.
// Copy and owned raster assets are data layers, never generative approximations.
const node=(type,style,children,props={})=>({type,props:{...props,style:{boxSizing:"border-box",...style},children}});
const STYLES={commercial_launch:{paper:"#081522",ink:"#F2F5F5",accent:"#F2BB70",panel:"#102637"},editorial:{paper:"#F3EFE6",ink:"#182C36",accent:"#B04C2B",panel:"#E5DED0"},photographic:{paper:"#162A2A",ink:"#F9F5EC",accent:"#C5E4CA",panel:"#183F3B"},illustrated:{paper:"#F4EDDD",ink:"#243C35",accent:"#B85D3B",panel:"#E3D8BE"},minimal:{paper:"#F2F4F3",ink:"#223C42",accent:"#207D82",panel:"#DFE7E5"}};
function scene({items,width,height,fontSize,assets,style="commercial_launch",layout="product_launch",background,partition}){
 const palette=STYLES[style]||STYLES.commercial_launch,p=palette,short=Math.min(width,height),margin=short*.05,gap=fontSize*.75;
 const title=items.find(t=>t.role==="title")||items[0],subtitle=items.find(t=>t.role==="subtitle"&&t!==title),footer=items.filter(t=>["contact","footer"].includes(t.role)&&t!==title&&t!==subtitle),body=items.filter(t=>t!==title&&t!==subtitle&&!footer.includes(t));
 const editorial=layout==="product_spread",photo=layout==="product_stage",light=["editorial","illustrated","minimal"].includes(style);
 const portrait=height>width;
 const header=editorial?(portrait?[.05,.12,.32,.28]:[.05,.12,.31,.42]):[.05,.12,.9,.19],art=editorial?(portrait?[.43,.13,.52,.24]:[.4,.19,.55,.37]):photo?[.05,.37,.5,.44]:[.52,.35,.43,.43],bodyZone=editorial?(portrait?[.05,.45,.9,.4]:[.05,.62,.9,.23]):photo?[.6,.35,.35,.45]:[.05,.36,.42,.44],footerZone=[.05,.89,.9,.07];
 const box=b=>({left:b[0]*width,top:b[1]*height,width:b[2]*width,height:b[3]*height}),used=[],zones={},assetZones=[];
 const text=(item,scale=1,extra={},zone)=>{used.push(item.key);zones[item.key]=zone;return node("div",{display:"flex",flexDirection:"column",fontSize:fontSize*scale,lineHeight:1.4,whiteSpace:"pre-wrap",wordBreak:"break-word",flexShrink:0,...extra},item.text,{"data-copy-key":item.key});};
 const tree=[];
 if(background)tree.push(node("img",{position:"absolute",left:0,top:0,width,height,objectFit:"cover",opacity:light?.16:.62},undefined,{src:background}));
 tree.push(node("div",{position:"absolute",left:0,top:0,width,height,backgroundImage:light?"linear-gradient(90deg,"+p.paper+"F5,"+p.paper+"A6)":"linear-gradient(90deg,"+p.paper+"FA 0%,"+p.paper+"D9 42%,"+p.paper+"33 100%)"}));
 tree.push(node("div",{position:"absolute",left:margin,top:height*.06,width:width*.12,height:6,backgroundColor:p.accent}));
 tree.push(node("div",{position:"absolute",...box(header),display:"flex",flexDirection:"column",gap:fontSize*.5},[
  text(title,3.2,{fontWeight:700,lineHeight:1.12,color:p.ink},header),...(subtitle?[text(subtitle,1.3,{fontWeight:700,color:p.accent,lineHeight:1.35},header)]:[])
 ]));
 const groups=editorial&&body.length>3?partition(body.map(t=>({items:[t]})),2).map(g=>g.map(x=>x.items[0])):[body];
 const bw=bodyZone[2]*width,groupWidth=(bw-gap*(groups.length-1))/groups.length;
 const bodyGroups=groups.map(group=>node("div",{display:"flex",width:groupWidth,flexDirection:"column",gap:gap*.8,flexShrink:0},group.map(item=>{
  const colon=item.text.search(/[：:]/),hasLead=colon>=1&&colon<16;
  if(!hasLead)return text(item,1,{paddingLeft:gap*.65,borderLeft:"3px solid "+p.accent,color:p.ink},bodyZone);
  used.push(item.key);zones[item.key]=bodyZone;
  return node("div",{display:"flex",flexDirection:"column",gap:fontSize*.16,fontSize,lineHeight:1.38,color:p.ink,whiteSpace:"pre-wrap",wordBreak:"break-word",flexShrink:0,paddingLeft:gap*.65,borderLeft:"3px solid "+p.accent},[
   node("div",{display:"flex",fontWeight:700,color:p.accent},item.text.slice(0,colon+1)),
   node("div",{display:"flex"},item.text.slice(colon+1))
  ],{"data-copy-key":item.key});
 })));
 tree.push(node("div",{position:"absolute",...box(bodyZone),display:"flex",gap},bodyGroups));
 const uis=assets.filter(a=>a.role==="ui");if(uis.length!==1)throw Object.assign(Error("PRODUCT_UI_REQUIRED"),{code:"PRODUCT_UI_REQUIRED"});
 const source=uis[0],outer=box(art),screenWidth=Math.min(outer.width,outer.height*source.aspect),screenHeight=screenWidth/source.aspect,x=outer.left+(outer.width-screenWidth)/2,y=outer.top+(outer.height-screenHeight)/2;
 const bezel=short*.009;
 tree.push(node("div",{position:"absolute",left:x-bezel,top:y-bezel,width:screenWidth+bezel*2,height:screenHeight+bezel*2,borderRadius:short*.014,border:bezel+"px solid #23333E",backgroundColor:"#071523",boxShadow:"0 18px 46px #00000055",display:"flex"},[
  node("img",{width:screenWidth,height:screenHeight,objectFit:"contain"},undefined,{src:source.src})
 ]));
 assetZones.push({role:"ui",index:source.index,sourceSha256:source.sha256,box:[x/width,y/height,screenWidth/width,screenHeight/height]});
 tree.push(node("div",{position:"absolute",left:x+screenWidth*.42,top:y+screenHeight+bezel,width:screenWidth*.16,height:Math.min(short*.028,height*.85-y-screenHeight),backgroundImage:"linear-gradient(90deg,#162C3D,#638089,#162C3D)"}));
 const logos=assets.filter(a=>a.role==="logo");if(logos.length>3)throw Error("PRODUCT_LOGO_LIMIT");
 // Original dark brand ink remains unchanged. A continuous light wash behind
 // the brand area keeps it legible without pasting a white image rectangle.
 if(logos.length&&!light)tree.push(node("div",{position:"absolute",left:width*.59,top:0,width:width*.41,height:height*.115,backgroundImage:"linear-gradient(90deg,#EEF2F400,#EEF2F4DD 38%,#EEF2F4F5 100%)"}));
 const logoZones=[];for(const [i,logo]of logos.entries()){
  const available=[.65+i*.1,.03,.27/Math.max(1,logos.length),.065],b=box(available),w=Math.min(b.width,b.height*logo.aspect),h=w/logo.aspect;
  tree.push(node("img",{position:"absolute",left:b.left+b.width-w,top:b.top,width:w,height:h,objectFit:"contain"},undefined,{src:logo.src}));
  logoZones.push({role:"logo",index:logo.index,sourceSha256:logo.sha256,box:[(b.left+b.width-w)/width,b.top/height,w/width,h/height]});
 }
 assetZones.push(...logoZones);
 if(footer.length)tree.push(node("div",{position:"absolute",...box(footerZone),paddingTop:gap*.45,borderTop:"3px solid "+p.accent,display:"flex",flexDirection:"column",gap:fontSize*.2},footer.map(t=>text(t,1.06,{fontWeight:700,color:p.ink},footerZone))));
 return {tree:node("div",{position:"relative",width,height,display:"flex",fontFamily:"Noto CJK",color:p.ink,backgroundColor:p.paper},tree),consumed:used,margin,zones,assetZones,design:{styleId:style,layoutId:layout}};
}
module.exports={STYLES,scene};
