"use strict";

const {PNG}=require("pngjs");
const {boxOf}=require("./shared/image-layout-protocol");
const {decode,engine,cutout}=require("./protected-asset-compositor");

function overlaps(a,b){
  return a[0]<b[0]+b[2]&&b[0]<a[0]+a[2]&&a[1]<b[1]+b[3]&&b[1]<a[1]+a[3];
}

async function clearGeneratedMarks(bytes,marks,occupied){
  const invalid=()=>Object.assign(new Error("POSTER_BRAND_MASK_UNSAFE"),{code:"POSTER_BRAND_MASK_UNSAFE"});
  if(!Array.isArray(marks)||!Array.isArray(occupied)||marks.length<1||marks.length>2||occupied.some(box=>!boxOf(box)))throw invalid();
  for(const [i,box] of marks.entries()){
    if(!boxOf(box)||box[2]>.34||box[3]>.12||box[2]*box[3]>.025
        ||occupied.some(other=>overlaps(box,other))||marks.slice(i+1).some(other=>boxOf(other)&&overlaps(box,other)))throw invalid();
  }

  const image=decode(bytes),{cv}=await engine();
  for(const [x,y,w,h] of marks){
    const x0=Math.floor(x*image.width),y0=Math.floor(y*image.height);
    const x1=Math.min(image.width,Math.ceil((x+w)*image.width)),y1=Math.min(image.height,Math.ceil((y+h)*image.height));
    const left=Math.max(0,x0-12),top=Math.max(0,y0-12);
    const width=Math.min(image.width,x1+12)-left,height=Math.min(image.height,y1+12)-top;
    const crop=Buffer.alloc(width*height*4),mask=Buffer.alloc(width*height);
    for(let row=0;row<height;row++){
      const start=((top+row)*image.width+left)*4;
      image.data.copy(crop,row*width*4,start,start+width*4);
    }
    const {raster:segmented}=await cutout({width,height,data:crop},{trim:false});
    let selected=0;
    for(let py=y0-top;py<y1-top;py++)for(let px=x0-left;px<x1-left;px++){
      const i=py*width+px;
      if(segmented.data[i*4+3]<96)continue;
      selected++;
      for(let dy=-1;dy<=1;dy++)for(let dx=-1;dx<=1;dx++){
        if(py+dy>=y0-top&&py+dy<y1-top&&px+dx>=x0-left&&px+dx<x1-left)mask[i+dy*width+dx]=255;
      }
    }
    if(selected<4||selected>.7*(x1-x0)*(y1-y0))throw invalid();
    let rgba,bgr,maskMat,clean,result;
    try{
      rgba=cv.matFromArray(height,width,cv.CV_8UC4,crop);
      bgr=new cv.Mat();
      cv.cvtColor(rgba,bgr,cv.COLOR_RGBA2BGR);
      maskMat=cv.matFromArray(height,width,cv.CV_8UC1,mask);
      clean=new cv.Mat();
      cv.inpaint(bgr,maskMat,clean,3,cv.INPAINT_TELEA);
      result=new cv.Mat();
      cv.cvtColor(clean,result,cv.COLOR_BGR2RGBA);
      const repaired=Buffer.from(result.data);
      for(let py=y0;py<y1;py++)for(let px=x0;px<x1;px++){
        const pixel=(py-top)*width+px-left;
        if(!mask[pixel])continue;
        const src=pixel*4,dst=(py*image.width+px)*4;
        repaired.copy(image.data,dst,src,src+3);
      }
    }finally{for(const mat of [rgba,bgr,maskMat,clean,result])mat?.delete();}
  }
  return PNG.sync.write(image);
}

module.exports={clearGeneratedMarks};

