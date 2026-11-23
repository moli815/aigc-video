"use strict";
// Pixel ownership stays separate from generative styling. OpenCV's maintained
// homography/segmentation implementation supplies geometry, not model pixels.
const crypto=require("crypto"),{PNG}=require("pngjs"),jpeg=require("jpeg-js");
const {probeImageSize}=require("./media-guards");
const fail=code=>{throw Object.assign(new Error(code),{code});};
let cvPromise;
async function engine(){
 if(!cvPromise)cvPromise=new Promise((resolve,reject)=>{
  const cv=require("@techstark/opencv-js");
  // This distribution is an Emscripten thenable, not a native Promise.
  // Resolve a wrapper to avoid infinite Promise assimilation of cv.then.
  if(cv.Mat)return resolve({cv});
  const timer=setTimeout(()=>reject(new Error("ASSET_ENGINE_TIMEOUT")),15000);
  cv.onRuntimeInitialized=()=>{clearTimeout(timer);resolve({cv});};
 }).catch(e=>{cvPromise=null;throw e;});
 return cvPromise;
}
function decode(bytes,maxPixels=5e6){
 if(!Buffer.isBuffer(bytes)||bytes.length>24*1024*1024)fail("ASSET_DECODE_LIMIT");
 const size=probeImageSize(bytes);if(!size||size.w*size.h>maxPixels)fail("ASSET_PIXEL_LIMIT");
 let r;if(size.kind==="png")r=PNG.sync.read(bytes,{checkCRC:true});
 else if(size.kind==="jpeg")r=jpeg.decode(bytes,{useTArray:true,maxResolutionInMP:5,maxMemoryUsageInMB:128,tolerantDecoding:false});
 else fail("ASSET_FORMAT_UNSUPPORTED");
 return {width:r.width,height:r.height,data:Buffer.from(r.data)};
}
function cropRaster(r,box){
 if(!box)return {...r,data:Buffer.from(r.data)};
 if(!Array.isArray(box)||box.length!==4||box.some(n=>!Number.isFinite(n))||box[0]<0||box[1]<0||box[2]<=0||box[3]<=0||box[0]+box[2]>1.000001||box[1]+box[3]>1.000001)fail("ASSET_CROP_INVALID");
 const x=Math.floor(box[0]*r.width),y=Math.floor(box[1]*r.height),w=Math.min(r.width-x,Math.max(1,Math.round(box[2]*r.width))),h=Math.min(r.height-y,Math.max(1,Math.round(box[3]*r.height)));
 const data=Buffer.alloc(w*h*4);for(let row=0;row<h;row++)r.data.copy(data,row*w*4,((y+row)*r.width+x)*4,((y+row)*r.width+x+w)*4);
 return {width:w,height:h,data};
}
function trimAlpha(r){
 let l=r.width,t=r.height,rr=-1,b=-1;for(let y=0;y<r.height;y++)for(let x=0;x<r.width;x++)if(r.data[(y*r.width+x)*4+3]>8){l=Math.min(l,x);rr=Math.max(rr,x);t=Math.min(t,y);b=Math.max(b,y);}
 if(rr<l||b<t)fail("ASSET_EMPTY_ALPHA");
 const x=Math.max(0,l-1),y=Math.max(0,t-1);return cropRaster(r,[x/r.width,y/r.height,(Math.min(r.width-1,rr+1)-x+1)/r.width,(Math.min(r.height-1,b+1)-y+1)/r.height]);
}
function uniformCutout(r){
 const n=r.width*r.height,p=r.data,corners=[0,r.width-1,n-r.width,n-1];
 const bg=[0,1,2].map(c=>corners.reduce((a,i)=>a+p[i*4+c],0)/4);
  const distance=i=>Math.max(Math.abs(p[i*4]-bg[0]),Math.abs(p[i*4+1]-bg[1]),Math.abs(p[i*4+2]-bg[2]));
 if(corners.some(i=>distance(i)>20))return false;
 const queue=new Int32Array(n),seen=new Uint8Array(n);let tail=0,head=0;
 const add=i=>{if(!seen[i]&&(p[i*4+3]<16||distance(i)<48)){seen[i]=1;queue[tail++]=i;}};
 for(let x=0;x<r.width;x++){add(x);add(n-r.width+x);}for(let y=0;y<r.height;y++){add(y*r.width);add(y*r.width+r.width-1);}
 while(head<tail){const i=queue[head++],x=i%r.width;if(x)add(i-1);if(x<r.width-1)add(i+1);if(i>=r.width)add(i-r.width);if(i<n-r.width)add(i+r.width);}
 // Do not erase a nearly uniform image or claim a busy background was matted.
 if(tail<n*.12||tail>n*.995)return false;
  // A JPEG edge is I=alpha*F+(1-alpha)*B, not an opaque pale foreground.
  // Refine only the narrow boundary of the already verified connected matte.
  // Use a nearby opaque colour, rejecting mixed/ambiguous colour estimates;
  // do not recolour opaque artwork or enclosed white details.
  const source=Buffer.from(p);
  for(let i=0;i<n;i++){
   if(seen[i]||source[i*4+3]<250||distance(i)<48)continue;
   const x=i%r.width,y=Math.floor(i/r.width);let nearBackground=false,foreground=-1,best=Infinity;
   for(let dy=-2;dy<=2&&!nearBackground;dy++)for(let dx=-2;dx<=2;dx++)if(dx*dx+dy*dy<=4&&x+dx>=0&&x+dx<r.width&&y+dy>=0&&y+dy<r.height&&seen[(y+dy)*r.width+x+dx]){nearBackground=true;break;}
   if(!nearBackground)continue;
   for(let dy=-3;dy<=3;dy++)for(let dx=-3;dx<=3;dx++){
    if(x+dx<0||x+dx>=r.width||y+dy<0||y+dy>=r.height)continue;
    const j=(y+dy)*r.width+x+dx,d=dx*dx+dy*dy;
    if(!seen[j]&&source[j*4+3]===255&&Math.max(Math.abs(source[j*4]-bg[0]),Math.abs(source[j*4+1]-bg[1]),Math.abs(source[j*4+2]-bg[2]))>160&&d<best){best=d;foreground=j;}
   }
   if(!nearBackground||foreground<0)continue;
   const f=[0,1,2].map(k=>source[foreground*4+k]),v=f.map((c,k)=>c-bg[k]),den=v.reduce((s,c)=>s+c*c,0);
   const a=v.reduce((s,c,k)=>s+c*(source[i*4+k]-bg[k]),0)/den;
   if(a<.04||a>.96||f.some((c,k)=>Math.abs(source[i*4+k]-(a*c+(1-a)*bg[k]))>10))continue;
   for(let k=0;k<3;k++)p[i*4+k]=f[k];p[i*4+3]=Math.round(255*a);
  }
 for(let i=0;i<n;i++)if(seen[i])p[i*4+3]=0;
 return true;
}
async function cutout(r,{trim=true}={}){
 const result={...r,data:Buffer.from(r.data)};
 let transparent=0;for(let i=3;i<result.data.length;i+=4)if(result.data[i]<128)transparent++;
 if(transparent>result.width*result.height*.01)return {raster:trim?trimAlpha(result):result,method:"existing-alpha"};
 if(uniformCutout(result))return {raster:trim?trimAlpha(result):result,method:"border-connected-uniform"};
 const {cv}=await engine(),owned=[];const keep=x=>(owned.push(x),x);
 try{
  const src=keep(cv.matFromArray(r.height,r.width,cv.CV_8UC4,r.data)),small=keep(new cv.Mat()),rgb=keep(new cv.Mat());
  const scale=Math.min(1,768/Math.max(r.width,r.height));cv.resize(src,small,new cv.Size(Math.max(3,Math.round(r.width*scale)),Math.max(3,Math.round(r.height*scale))),0,0,cv.INTER_AREA);cv.cvtColor(small,rgb,cv.COLOR_RGBA2RGB);
  const mask=keep(new cv.Mat(rgb.rows,rgb.cols,cv.CV_8UC1,new cv.Scalar(0))),bg=keep(new cv.Mat()),fg=keep(new cv.Mat());
  cv.grabCut(rgb,mask,new cv.Rect(1,1,rgb.cols-2,rgb.rows-2),bg,fg,3,cv.GC_INIT_WITH_RECT);
  let count=0;for(let i=0;i<mask.data.length;i++){const v=mask.data[i]===1||mask.data[i]===3;mask.data[i]=v?255:0;if(v)count++;}
  if(count<mask.data.length*.005||count>mask.data.length*.98)fail("ASSET_MATTING_UNCERTAIN");
  const alpha=keep(new cv.Mat());cv.resize(mask,alpha,new cv.Size(r.width,r.height),0,0,cv.INTER_LINEAR);
  for(let i=0;i<alpha.data.length;i++)result.data[i*4+3]=Math.min(result.data[i*4+3],alpha.data[i]);
  return {raster:trim?trimAlpha(result):result,method:"grabcut-best-effort"};
 }finally{for(const mat of owned.reverse())mat.delete();}
}
function quadOf(raw,width,height){
 if(!Array.isArray(raw)||raw.length!==4||raw.some(p=>!Array.isArray(p)||p.length!==2||p.some(v=>!Number.isFinite(v)||v<0||v>1)))fail("ASSET_QUAD_INVALID");
 let area=0;for(let i=0;i<4;i++){
  const a=raw[i],b=raw[(i+1)%4],c=raw[(i+2)%4];
  if((b[0]-a[0])*(c[1]-b[1])-(b[1]-a[1])*(c[0]-b[0])<=1e-7)fail("ASSET_QUAD_INVALID");
  area+=a[0]*b[1]-b[0]*a[1];
 }
 if(area/2<.0003||area/2>.9)fail("ASSET_QUAD_INVALID");
 return raw.flatMap(p=>[p[0]*(width-1),p[1]*(height-1)]);
}
function boxQuad(b){return [[b[0],b[1]],[b[0]+b[2],b[1]],[b[0]+b[2],b[1]+b[3]],[b[0],b[1]+b[3]]];}
function intersects(a,b){return a[0]<b[0]+b[2]&&b[0]<a[0]+a[2]&&a[1]<b[1]+b[3]&&b[1]<a[1]+a[3];}
function logoBox({canvas,aspect,occupied=[],anchor="auto"}){
 const short=Math.min(canvas.width,canvas.height),w=Math.min(canvas.width*.3,Math.max(short*.16,short*.055*aspect))/canvas.width,h=w*canvas.width/aspect/canvas.height;
 const mx=Math.min(canvas.width,canvas.height)*.055/canvas.width,my=Math.min(canvas.width,canvas.height)*.055/canvas.height;
 if(h>.3)fail("ASSET_LOGO_ASPECT_UNSUPPORTED");
 const candidates=[[mx,my],[1-mx-w,my],[mx,1-my-h],[1-mx-w,1-my-h],[(1-w)/2,my],[(1-w)/2,1-my-h]];
 const order={top_left:0,top_right:1,bottom_left:2,bottom_right:3};if(Object.hasOwn(order,anchor))candidates.unshift(candidates[order[anchor]]);
 for(const [x,y]of candidates){const b=[x,y,w,h];if(x<0||y<0||x+w>1||y+h>1)continue;
  const pad=[x-.008,y-.008,w+.016,h+.016];if(!occupied.some(o=>intersects(pad,o)))return b;
 }
 fail("ASSET_NO_SAFE_LOGO_SLOT");
}
function luminance(data,index){
 const linear=v=>{const x=v/255;return x<=.04045?x/12.92:((x+.055)/1.055)**2.4;};
 return .2126*linear(data[index])+.7152*linear(data[index+1])+.0722*linear(data[index+2]);
}
function contrastRatio(a,b){return (Math.max(a,b)+.05)/(Math.min(a,b)+.05);}
function placeLogoBacking(canvas,source,box){
 let sum=0,count=0;
 const step=Math.max(1,Math.floor(source.width*source.height/4096));
 for(let pixel=0;pixel<source.width*source.height;pixel+=step){
  const i=pixel*4;
  if(source.data[i+3]>=220){sum+=luminance(source.data,i);count++;}
 }
 if(!count)return false;
 const foreground=sum/count;
 const [x,y,w,h]=box;
 let need=0;
 for(let row=0;row<5;row++)for(let col=0;col<9;col++){
  const px=Math.floor((x+w*(col+.5)/9)*canvas.width);
  const py=Math.floor((y+h*(row+.5)/5)*canvas.height);
  if(contrastRatio(foreground,luminance(canvas.data,(py*canvas.width+px)*4))<3)need++;
 }
 if(need<13)return false;
 const fill=contrastRatio(foreground,1)>contrastRatio(foreground,0)?250:15;
 const left=Math.max(0,Math.ceil((x-.006)*canvas.width)),right=Math.min(canvas.width,Math.floor((x+w+.006)*canvas.width));
 const top=Math.max(0,Math.ceil((y-.006)*canvas.height)),bottom=Math.min(canvas.height,Math.floor((y+h+.006)*canvas.height));
 const radius=Math.max(1,Math.floor((bottom-top)*.13));
 for(let py=top;py<bottom;py++)for(let px=left;px<right;px++){
  const dx=Math.max(left+radius-px,px-(right-radius-1),0);
  const dy=Math.max(top+radius-py,py-(bottom-radius-1),0);
  if(dx*dx+dy*dy>radius*radius)continue;
  const i=(py*canvas.width+px)*4;
  canvas.data[i]=fill;canvas.data[i+1]=fill;canvas.data[i+2]=fill;canvas.data[i+3]=255;
 }
 return true;
}
async function compose({canvas:bytes,placements}){
 const start=Date.now(),canvas=decode(bytes),{cv}=await engine(),manifest=[],placedLogos=[];
 if(!Array.isArray(placements)||placements.length<1||placements.length>4)fail("ASSET_PLACEMENT_INVALID");
 for(const item of placements){
  if(!["ui","logo","product"].includes(item.role)||!Buffer.isBuffer(item.bytes))fail("ASSET_PLACEMENT_INVALID");
  const sourceHash=crypto.createHash("sha256").update(item.bytes).digest("hex");
  if(item.sha256!==sourceHash)fail("ASSET_INTEGRITY_FAILED");
  let source=item.preparedRaster||cropRaster(decode(item.bytes),item.crop),method=item.method||"original-pixels";
  if(!Buffer.isBuffer(source.data)||source.width*source.height>5e6||source.data.length!==source.width*source.height*4)fail("ASSET_PIXEL_LIMIT");
  if(item.role==="logo"&&!item.preparedRaster){const c=await cutout(source);source=c.raster;method=c.method;}
  let quad=item.quad,backing=false;
  if(item.role==="logo"&&!quad){
   const box=logoBox({canvas,aspect:source.width/source.height,occupied:[...(item.occupied||[]),...placedLogos],anchor:item.anchor});
   if(item.ensureContrast===true)backing=placeLogoBacking(canvas,source,box);
   quad=boxQuad(box);placedLogos.push(box);
  }
  const points=quadOf(quad,canvas.width,canvas.height),owned=[],keep=x=>(owned.push(x),x);
  try{
   const premult=Buffer.from(source.data);for(let i=0;i<premult.length;i+=4)for(let c=0;c<3;c++)premult[i+c]=Math.round(premult[i+c]*premult[i+3]/255);
   const src=keep(cv.matFromArray(source.height,source.width,cv.CV_8UC4,premult));
   const from=keep(cv.matFromArray(4,1,cv.CV_32FC2,[0,0,source.width-1,0,source.width-1,source.height-1,0,source.height-1]));
   const to=keep(cv.matFromArray(4,1,cv.CV_32FC2,points)),matrix=keep(cv.getPerspectiveTransform(from,to)),warped=keep(new cv.Mat());
   cv.warpPerspective(src,warped,matrix,new cv.Size(canvas.width,canvas.height),cv.INTER_LINEAR,cv.BORDER_CONSTANT,new cv.Scalar(0,0,0,0));
   const xs=quad.map(p=>p[0]),ys=quad.map(p=>p[1]),l=Math.max(0,Math.floor(Math.min(...xs)*canvas.width)-1),r=Math.min(canvas.width,Math.ceil(Math.max(...xs)*canvas.width)+1),t=Math.max(0,Math.floor(Math.min(...ys)*canvas.height)-1),b=Math.min(canvas.height,Math.ceil(Math.max(...ys)*canvas.height)+1);
   for(let y=t;y<b;y++)for(let x=l;x<r;x++){
    const i=(y*canvas.width+x)*4,a=warped.data[i+3]/255;if(!a)continue;const da=canvas.data[i+3]/255,oa=a+da*(1-a);
    for(let c=0;c<3;c++)canvas.data[i+c]=Math.max(0,Math.min(255,Math.round((warped.data[i+c]+canvas.data[i+c]*da*(1-a))/oa)));
    canvas.data[i+3]=Math.round(oa*255);
   }
   manifest.push({role:item.role,sourceSha256:sourceHash,method,quad,sourceWidth:source.width,sourceHeight:source.height,...(backing?{backing:true}:{})});
  }finally{for(const mat of owned.reverse())mat.delete();}
 }
 const png=PNG.sync.write(canvas);
 return {png,manifest:{version:"protected-assets-v1",placements:manifest,width:canvas.width,height:canvas.height,ms:Date.now()-start,rss:process.memoryUsage().rss}};
}
module.exports={engine,decode,cropRaster,cutout,quadOf,boxQuad,logoBox,compose};
