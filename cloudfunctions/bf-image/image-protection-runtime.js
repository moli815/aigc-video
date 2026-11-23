"use strict";
const crypto=require("crypto");
const compositor=require("./protected-asset-compositor");
const {currentItems}=require("./shared/image-reference-merge"),{boundedBytes,validateBytes}=require("./shared/asset-store");
const {requestOf,responseOf}=require("./shared/image-layout-protocol");
const fail=code=>{throw Object.assign(new Error(code),{code});};
const sha=b=>crypto.createHash("sha256").update(b).digest("hex");
function copyOcclusions(layout){
 // Separating-axis test for a rectangle and the validated convex quad.
 // Corner/centre containment misses a thin edge crossing through a text line.
 const overlaps=(a,b)=>[a,b].every(polygon=>polygon.every((p,i)=>{
  const next=polygon[(i+1)%polygon.length],axis=[p[1]-next[1],next[0]-p[0]],project=q=>q.map(v=>v[0]*axis[0]+v[1]*axis[1]);
  const aa=project(a),bb=project(b);return Math.max(...aa)>Math.min(...bb)+1e-10&&Math.max(...bb)>Math.min(...aa)+1e-10;
 }));
 const issues=[];for(const text of layout.recognized_text||[]){const [x,y,w,h]=text.box,points=[[x,y],[x+w,y],[x+w,y+h],[x,y+h]];
  for(const region of layout.regions){if(overlaps(points,region.quad)){
   issues.push({textHash:sha(text.text),index:region.index});break;
  }}
 }return issues;
}
function numericIssues(layout,expected){
 const allowed=new Set(expected.join(" ").match(/\d+(?:\.\d+)?/g)||[]);
 const regions=layout.regions.map(r=>r.quad);
 const inside=(p,q)=>q.every((a,i)=>{const b=q[(i+1)%4];return (b[0]-a[0])*(p[1]-a[1])-(b[1]-a[1])*(p[0]-a[0])>=-1e-6;});
 const issues=[];for(const t of layout.recognized_text||[]){const b=t.box,c=[b[0]+b[2]/2,b[1]+b[3]/2];if(regions.some(q=>inside(c,q)))continue;
  const unexpected=(t.text.match(/\d+(?:\.\d+)?/g)||[]).filter(n=>!allowed.has(n));if(unexpected.length)issues.push({textHash:sha(t.text),numbers:[...new Set(unexpected)]});}
 return issues;
}
function blockingIssues(layout,deferGarbledText=false){
 return layout.issues.filter(issue=>!(deferGarbledText===true&&issue.code==='GARBLED_TEXT'));
}
async function preview(bytes){
 const r=compositor.decode(bytes),limit=2500000;
 // A 3136px tall poster previously became 1280px high here: a 15px glyph
 // reached the checker at ~6px, followed by another lossy JPEG conversion.
 // Preserve the bounded source raster. Passing OCR is still NOT glyph proof.
 // The limit fits the existing 4M-character layout contract, without adding a
 // provider-specific parameter or assuming that the provider won't resize it.
 if(bytes.length<=limit)return 'data:image/'+(bytes[0]===137?'png':'jpeg')+';base64,'+bytes.toString('base64');
 for(const quality of [92,85,78]){
  const jpeg=require('jpeg-js').encode({width:r.width,height:r.height,data:r.data},quality).data;
  if(jpeg.length<=limit)return 'data:image/jpeg;base64,'+jpeg.toString('base64');
 }
 // Compatibility floor: high-entropy 2K scenes can exceed the layout service's
 // byte budget even at JPEG78. Preserve the previous bounded preview path in
 // that exceptional case rather than introducing a new generation failure.
 // Typical dense PNGs and fitting JPEGs above still keep every source pixel.
 // Use the already deployed resvg runtime. Some legacy artifacts contain the
 // OpenCV adapter but not its optional package; preview must not depend on it.
 const scale=Math.min(1,1280/Math.max(r.width,r.height)),width=Math.round(r.width*scale),height=Math.round(r.height*scale),{resvg}=await require('./commercial-composition-runtime').loadEngines();let engine,frame;
 try{
  const mime=bytes[0]===137?'image/png':'image/jpeg',svg=`<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}"><image width="${width}" height="${height}" preserveAspectRatio="none" href="data:${mime};base64,${bytes.toString('base64')}"/></svg>`;
  engine=new resvg.Resvg(svg,{font:{loadSystemFonts:false}});frame=engine.render();const data=require('pngjs').PNG.sync.read(Buffer.from(frame.asPng())).data;
  for(const quality of [78,68,58]){
   const jpeg=require('jpeg-js').encode({width,height,data},quality).data;
   if(jpeg.length<=1.5e6)return 'data:image/jpeg;base64,'+jpeg.toString('base64');
  }
  fail('IMAGE_PREVIEW_LIMIT');
 }finally{frame?.free?.();engine?.free?.();}
}
function createProtectionRuntime({assetStore,readAsset,locate,fetcher=fetch,log=()=>{}}){
 return {
  async prepare({plan,image,owner,structured,authorization,deferGarbledText=false}){
   const protectedRefs=plan?.protected_references.filter(r=>["ui","logo"].includes(r.role))||[];
   if(!(plan?.native||plan?.protectUI)||!protectedRefs.length)return null;
   if(!authorization)fail("ASSET_LAYOUT_AUTH_REQUIRED");
   const current=await currentItems({owner,image,readAsset});
   // Verify ownership/integrity of every source before the paid generation.
   await assetStore.verifyReferences(owner,current);
   const selected=[];
   for(const p of protectedRefs){const descriptor=current[p.index-1];if(!descriptor)fail("ASSET_REFERENCE_MISSING");
    const row=await readAsset(owner,descriptor.id);if(!row||row.accountId!==owner||row.state!=="ready"||row.privateACL!==true)fail("ASSET_NOT_FOUND");
    const signed=await assetStore.sign(owner,[descriptor.id]),url=signed.find(s=>s.id===descriptor.id)?.url;if(!url)fail("ASSET_URL_FAILED");
    const bytes=await boundedBytes(url,Math.min(24*1024*1024,row.byteCount),fetcher);validateBytes(row,bytes);
    let raster=compositor.cropRaster(compositor.decode(bytes),p.crop),method;
    if(p.role==="logo"){const matte=await compositor.cutout(raster);raster=matte.raster;method=matte.method;}
    selected.push({...p,bytes,sha256:row.sha256,aspect:raster.width/raster.height,method,preparedRaster:raster});
   }
   await compositor.engine();
   return {owner,authorization,selected,expected:(structured?.text||[]).map(t=>t.text).filter(t=>typeof t==="string"),plan,deferGarbledText:deferGarbledText===true};
  },
  async finish(prepared,url){
   const bytes=await boundedBytes(url,24*1024*1024,fetcher);
   const draft=await assetStore.archive(prepared.owner,bytes,bytes[0]===137?"image/png":"image/jpeg");
   try{
    const raw=requestOf({image:await preview(bytes),references:prepared.selected.map(p=>({index:p.index,role:p.role,aspect:p.aspect,anchor:p.anchor||"auto"})),expected_text:prepared.expected,...(prepared.plan.posterBrand?{placement_only:true}:{})});
    const layout=responseOf(await locate(raw,prepared.authorization),raw);
    const occlusions=copyOcclusions(layout);if(occlusions.length){log({event:"source_copy_occlusion_rejected",count:occlusions.length});fail("IMAGE_ASSET_TEXT_OCCLUSION");}
    const numeric=numericIssues(layout,prepared.expected);
    if(numeric.length){log({event:"numeric_copy_rejected",count:numeric.length});fail("IMAGE_COPY_UNVERIFIED_NUMBERS");}
    // Only a host that has reserved and committed to the canonical typography
    // stage may defer this ONE defect class. Missing/unsupported content and
    // occlusions are never waived, and the unrefined draft is not a deliverable.
    if(blockingIssues(layout,prepared.deferGarbledText).length)fail("IMAGE_VISUAL_REVIEW_REQUIRED");
    const protectedBoxes=layout.regions.map(r=>{const xs=r.quad.map(p=>p[0]),ys=r.quad.map(p=>p[1]);return [Math.min(...xs),Math.min(...ys),Math.max(...xs)-Math.min(...xs),Math.max(...ys)-Math.min(...ys)];});
    // Paste original screens first. Logos must avoid these screens as well as
    // text/faces, even when the locator omitted a screen from occupied.
    const placements=[...prepared.selected].sort((a,b)=>(a.role==="logo")-(b.role==="logo")).map(p=>({role:p.role,bytes:p.bytes,sha256:p.sha256,crop:p.crop,anchor:p.anchor||"auto",preparedRaster:p.preparedRaster,method:p.method,
     ...(p.role==="ui"?{quad:layout.regions.find(r=>r.index===p.index)?.quad}:{occupied:[...layout.occupied,...protectedBoxes],ensureContrast:prepared.plan.posterBrand===true})}));
    const rendered=await compositor.compose({canvas:bytes,placements});
    const asset=await assetStore.archive(prepared.owner,rendered.png,"image/png"),signed=await assetStore.sign(prepared.owner,[asset.id]);
    const finalUrl=signed.find(s=>s.id===asset.id)?.url;if(!finalUrl)fail("ASSET_URL_FAILED");
    log({event:"protected_assets_composed",count:placements.length,ms:rendered.manifest.ms,rss:rendered.manifest.rss});
    return {url:finalUrl,asset:{...asset,variants:{background:draft}},protection:rendered.manifest};
   }catch(e){e.draftAsset=draft;throw e;}
  }
 };
}
module.exports={createProtectionRuntime,numericIssues,copyOcclusions,preview,blockingIssues};
