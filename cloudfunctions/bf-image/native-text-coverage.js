"use strict";
// The provider's transparent layer is pixel evidence, its OCR is only a
// transcription. Detect unrecognised ink before any glyph layer is replaced.
// OpenCV connectedComponentsWithStats supplies measured regions, not semantics.
const {engine,decode}=require('./protected-asset-compositor');
const fail=code=>{throw Object.assign(Error(code),{code});};
async function audit({bytes,rows,width,height}){
 const r=decode(bytes);if(!Array.isArray(rows)||rows.length!==1||!Number.isInteger(width)||!Number.isInteger(height))fail('NATIVE_TEXT_ALPHA_CANVAS');
 const valid=b=>Array.isArray(b)&&b.length===4&&b.every(Number.isInteger)&&b[0]>=0&&b[1]>=0&&b[2]<=width&&b[3]<=height&&b[2]>b[0]&&b[3]>b[1];
 const parent=rows[0]?.bounding_box?.absolute;if(!valid(parent))fail('NATIVE_TEXT_GEOMETRY');
 const sx=r.width/(parent[2]-parent[0]),sy=r.height/(parent[3]-parent[1]);
 // Official layers have independent resolutions. Their bounding box maps the
 // layer back to the base; OCR line boxes are already in base coordinates.
 const raw=rows.flatMap(row=>row.text_recognition?.lines||[]).map(l=>l.bounding_box?.absolute);
 if(raw.length>500||raw.some(b=>!valid(b)||b[0]<parent[0]||b[1]<parent[1]||b[2]>parent[2]||b[3]>parent[3]))fail('NATIVE_TEXT_GEOMETRY');
 const boxes=raw.map(b=>[Math.floor((b[0]-parent[0])*sx),Math.floor((b[1]-parent[1])*sy),Math.ceil((b[2]-parent[0])*sx),Math.ceil((b[3]-parent[1])*sy)]);
 width=r.width;height=r.height;
 const mask=new Uint8Array(width*height),known=new Uint8Array(width*height);
 const px=Math.ceil(4*sx),py=Math.ceil(4*sy);
 for(const b of boxes)for(let y=Math.max(0,b[1]-py);y<Math.min(height,b[3]+py);y++)known.fill(1,y*width+Math.max(0,b[0]-px),y*width+Math.min(width,b[2]+px));
 let ink=0,uncovered=0,transparent=0;
 for(let i=0;i<mask.length;i++){const alpha=r.data[i*4+3];if(alpha===0)transparent++;if(alpha>24){ink++;if(!known[i]){uncovered++;mask[i]=255;}}}
 if(transparent/mask.length<.5||ink<12||ink/mask.length>.3)fail('NATIVE_TEXT_ALPHA_NOT_TEXT_LAYER');
 const components=[];
 if(uncovered){const {cv}=await engine();let input,closed,labels,stats,centroids,kernel;
  try{input=cv.matFromArray(height,width,cv.CV_8UC1,mask);closed=new cv.Mat();labels=new cv.Mat();stats=new cv.Mat();centroids=new cv.Mat();kernel=cv.getStructuringElement(cv.MORPH_RECT,new cv.Size(9,3));
   cv.morphologyEx(input,closed,cv.MORPH_CLOSE,kernel);
   const n=cv.connectedComponentsWithStats(closed,labels,stats,centroids,8,cv.CV_32S);
   for(let i=1;i<n;i++){const x=stats.intAt(i,0),y=stats.intAt(i,1),w=stats.intAt(i,2),h=stats.intAt(i,3),area=stats.intAt(i,4);if(area>=12&&h>=4)components.push({box:[x,y,x+w,y+h],inkArea:area});}
  }finally{for(const m of[input,closed,labels,stats,centroids,kernel])m?.delete();}
 }
 const significant=components.filter(c=>c.inkArea>=50),ratio=uncovered/ink;
 return{version:'native-alpha-coverage-v1',inkPixels:ink,uncoveredInkPixels:uncovered,uncoveredRatio:ratio,complete:ratio<=.015&&significant.length===0,missingRegions:significant.slice(0,128).map(c=>({box:[Math.floor(parent[0]+c.box[0]/sx),Math.floor(parent[1]+c.box[1]/sy),Math.ceil(parent[0]+c.box[2]/sx),Math.ceil(parent[1]+c.box[3]/sy)],inkArea:c.inkArea})),regionsTruncated:significant.length>128};
}
module.exports={audit};
