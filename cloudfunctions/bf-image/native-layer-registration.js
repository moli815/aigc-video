"use strict";
// Official OpenCV ORB/ratio-test/RANSAC registration. An `auto` layer response
// may differ by a few pixels; never resize the approved artwork to conceal it.
// Only a distributed, near-identity fit can map provider layers back onto it.
const {PNG}=require('pngjs'),geo=require('./protected-asset-compositor');
const fail=(code,metrics)=>{throw Object.assign(Error(code),{code,metrics});};
function project(h,x,y){const z=h[6]*x+h[7]*y+h[8];if(!Number.isFinite(z)||Math.abs(z)<1e-9)fail('NATIVE_TEXT_REGISTRATION_UNCERTAIN');return[(h[0]*x+h[1]*y+h[2])/z,(h[3]*x+h[4]*y+h[5])/z];}
async function estimate(source,target){
 const {cv}=await geo.engine(),owned=[],keep=v=>(owned.push(v),v);
 try{
  const read=r=>{const m=keep(cv.matFromArray(r.height,r.width,cv.CV_8UC4,r.data)),g=keep(new cv.Mat()),small=keep(new cv.Mat()),scale=Math.min(1,1600/Math.max(r.width,r.height));cv.cvtColor(m,g,cv.COLOR_RGBA2GRAY);cv.resize(g,small,new cv.Size(Math.round(r.width*scale),Math.round(r.height*scale)),0,0,cv.INTER_AREA);return{m:small,sx:small.cols/r.width,sy:small.rows/r.height};};
  const a=read(source),b=read(target),detector=keep(new cv.ORB(4000)),ak=keep(new cv.KeyPointVector()),bk=keep(new cv.KeyPointVector()),ad=keep(new cv.Mat()),bd=keep(new cv.Mat()),empty=keep(new cv.Mat());
  detector.detectAndCompute(a.m,empty,ak,ad);detector.detectAndCompute(b.m,empty,bk,bd);
  if(ad.rows<40||bd.rows<40)fail('NATIVE_TEXT_REGISTRATION_UNCERTAIN',{reason:'insufficient_features'});
  const matcher=keep(new cv.BFMatcher(cv.NORM_HAMMING,false)),pairs=keep(new cv.DMatchVectorVector());matcher.knnMatch(ad,bd,pairs,2);
  const from=[],to=[];
  for(let i=0;i<pairs.size();i++){const pair=pairs.get(i);try{if(pair.size()<2)continue;const m=pair.get(0),n=pair.get(1);if(m.distance<.7*n.distance&&m.distance<=64){const p=ak.get(m.queryIdx).pt,q=bk.get(m.trainIdx).pt;from.push(p.x/a.sx,p.y/a.sy);to.push(q.x/b.sx,q.y/b.sy);}}finally{pair.delete();}}
  if(from.length<80)fail('NATIVE_TEXT_REGISTRATION_UNCERTAIN',{reason:'insufficient_matches',matches:from.length/2});
  const src=keep(cv.matFromArray(from.length/2,1,cv.CV_32FC2,from)),dst=keep(cv.matFromArray(to.length/2,1,cv.CV_32FC2,to)),mask=keep(new cv.Mat());
  if(typeof cv.setRNGSeed==='function')cv.setRNGSeed(314159);
  const transform=keep(cv.findHomography(src,dst,cv.RANSAC,3,mask));if(transform.empty())fail('NATIVE_TEXT_REGISTRATION_UNCERTAIN');
  const h=Array.from(transform.data64F);if(h.length!==9||h.some(n=>!Number.isFinite(n)))fail('NATIVE_TEXT_REGISTRATION_UNCERTAIN');
  const points=[],errors=[],frameErrors=[],cells=new Set();for(let i=0;i<mask.rows;i++)if(mask.data[i]){const x=from[i*2],y=from[i*2+1],p=project(h,x,y);points.push([x,y]);errors.push(Math.hypot(p[0]-to[i*2],p[1]-to[i*2+1]));frameErrors.push(Math.hypot(x*target.width/source.width-to[i*2],y*target.height/source.height-to[i*2+1]));cells.add(Math.min(2,Math.floor(x/source.width*3))+':'+Math.min(2,Math.floor(y/source.height*3)));}
  const span=axis=>(Math.max(...points.map(p=>p[axis]))-Math.min(...points.map(p=>p[axis])))/(axis?source.height:source.width);
  const corners=[[0,0],[source.width,0],[source.width,source.height],[0,source.height]].map(p=>project(h,...p)),expected=[[0,0],[target.width,0],[target.width,target.height],[0,target.height]],cornerDelta=Math.max(...corners.map((p,i)=>Math.hypot(p[0]-expected[i][0],p[1]-expected[i][1])));
  frameErrors.sort((a,b)=>a-b);
  const metrics={matches:from.length/2,inliers:points.length,inlierRatio:points.length/(from.length/2),spanX:points.length?span(0):0,spanY:points.length?span(1):0,occupiedCells:cells.size,meanError:errors.reduce((n,v)=>n+v,0)/Math.max(1,errors.length),cornerDelta,fixedCanvasP95:frameErrors[Math.floor(frameErrors.length*.95)]??Infinity,analysisPixelSize:Math.max(1/b.sx,1/b.sy)};
  // A text-cleared page can have blank top/bottom bands, so feature span alone
  // is not proof of a changed layout. For <=8px rounding ONLY, require much
  // stronger all-nine-cell evidence AND agreement with the independently known
  // canvas scale; a freely fitted homography cannot invent that agreement.
  const roundedFrame=Math.abs(source.width-target.width)<=8&&Math.abs(source.height-target.height)<=8&&metrics.inliers>=300&&metrics.inlierRatio>=.85&&metrics.occupiedCells===9&&metrics.meanError<=.5&&metrics.cornerDelta<=1&&metrics.fixedCanvasP95<=metrics.analysisPixelSize;
  if(metrics.inliers<30||metrics.inlierRatio<.6||((metrics.spanX<.65||metrics.spanY<.65)&&!roundedFrame)||metrics.occupiedCells<5||metrics.meanError>2||cornerDelta>Math.max(3,Math.min(target.width,target.height)*.006))fail('NATIVE_TEXT_REGISTRATION_UNCERTAIN',metrics);
  metrics.coverageMode=roundedFrame?'quantised_canvas_with_independent_scale_proof':'distributed_features';
  return{matrix:h,metrics};
 }finally{for(const v of owned.reverse())v.delete();}
}
async function warp(bytes,matrix,width,height){
 const r=geo.decode(bytes),{cv}=await geo.engine();let src,dst,h;
 try{src=cv.matFromArray(r.height,r.width,cv.CV_8UC4,r.data);dst=new cv.Mat();h=cv.matFromArray(3,3,cv.CV_64FC1,matrix);cv.warpPerspective(src,dst,h,new cv.Size(width,height),cv.INTER_LINEAR,cv.BORDER_REPLICATE);return PNG.sync.write({width,height,data:Buffer.from(dst.data)});}
 finally{src?.delete();dst?.delete();h?.delete();}
}
function mappedBox(box,h,width,height){
 const points=[[box[0],box[1]],[box[2],box[1]],[box[2],box[3]],[box[0],box[3]]].map(p=>project(h,...p)),b=[Math.max(0,Math.floor(Math.min(...points.map(p=>p[0])))),Math.max(0,Math.floor(Math.min(...points.map(p=>p[1])))),Math.min(width,Math.ceil(Math.max(...points.map(p=>p[0])))),Math.min(height,Math.ceil(Math.max(...points.map(p=>p[1]))))];
 if(b[2]<=b[0]||b[3]<=b[1])fail('NATIVE_TEXT_REGISTRATION_UNCERTAIN');return b;
}
async function align({original,cleanBase,layers}){
 const a=geo.decode(original),b=geo.decode(cleanBase);
 if(a.width===b.width&&a.height===b.height)return{cleanBase,layers,registration:{mode:'same_canvas'}};
 // `auto` can return a uniformly quantised canvas, not only a 1% rounding
 // difference. Check this in normalised canvas space, then PROVE the actual
 // correspondence with the unchanged distributed ORB/RANSAC gates. Never
 // resize the original or treat matching aspect ratios alone as evidence.
 const sx=a.width/b.width,sy=a.height/b.height;
 const smallRounding=Math.abs(sx-1)<=.01&&Math.abs(sy-1)<=.01;
 const uniformTier=sx>=.5&&sx<=2&&sy>=.5&&sy<=2&&Math.abs(sx/sy-1)<=.002;
 if(!smallRounding&&!uniformTier)fail('NATIVE_TEXT_CANVAS_CHANGED');
 const found=await estimate(b,a),mapped=[];
 for(const l of layers){if(l.row.bounding_box.absolute.some((n,i)=>n!==[0,0,b.width,b.height][i]))fail('NATIVE_TEXT_REGISTRATION_UNCERTAIN');
  mapped.push({bytes:await warp(l.bytes,found.matrix,a.width,a.height),row:{...l.row,bounding_box:{absolute:[0,0,a.width,a.height]},text_recognition:{...l.row.text_recognition,lines:(l.row.text_recognition?.lines||[]).map(line=>({...line,bounding_box:{absolute:mappedBox(line.bounding_box.absolute,found.matrix,a.width,a.height)}}))}}});
 }
 return{cleanBase:await warp(cleanBase,found.matrix,a.width,a.height),layers:mapped,registration:{mode:'verified_near_identity_homography',...found}};
}
module.exports={estimate,align,project,mappedBox};
