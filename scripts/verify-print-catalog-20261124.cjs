// Replay the real image HTTP handler against an isolated asset store and a recorded supplier image.
// Usage: node scripts/verify-print-catalog-20261124.cjs dense|catalog [background.png]
// The font files are the two verified release OTFs used by native-copy-http-fixture-hook.
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const {spawn} = require('node:child_process');
const {PNG} = require('../cloudfunctions/bf-image/node_modules/pngjs');
const {mark} = require('../cloudfunctions/shared/poster-delivery');
const root = path.resolve(__dirname, '..');
const tag = process.argv[2];
assert.ok(['dense','catalog','raw'].includes(tag));
const out = path.join(root,'outputs/print-and-catalog-20261124');
fs.mkdirSync(out,{recursive:true});
const file = name => path.join(out,name);
const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const owner = 'native_http_member';
const subject = Buffer.from(JSON.stringify({t:'member',sub:owner,exp:Date.now()+3600000})).toString('base64url');
const token = subject+'.'+crypto.createHmac('sha256','ephemeral-in-memory-native-http-fixture').update(subject).digest('base64url');
const palette = ['245385','e68c38','8b396a','378a62','d25642','6c54a6','287ba0','98aa29','bf6996','298c8f','606e9d','91a865','a25f33'];
const fill = (png,x,y,w,h,hex) => {
  const rgb = Buffer.from(hex,'hex');
  for(let j=y;j<y+h;j++) for(let i=x;i<x+w;i++) {
    const k=(j*png.width+i)*4;
    rgb.copy(png.data,k);png.data[k+3]=255;
  }
};
function bitmap(name,w,h,draw){
  const png=new PNG({width:w,height:h});
  fill(png,0,0,w,h,'ffffff');draw(png);
  const dest=file(name+'.png');fs.writeFileSync(dest,PNG.sync.write(png));return dest;
}
// Distinct colour and position markers make swapped, duplicated and missing items measurable.
function sheet(start,count){
  return bitmap('test-sheet-'+start,448,128*Math.ceil(count/2),png=>{
    for(let i=0;i<count;i++){
      const x=(i%2)*224,y=Math.floor(i/2)*128;
      fill(png,x+16,y+12,192,86,palette[start+i]);
      for(let bit=0;bit<4;bit++) if(((start+i+1)>>bit)&1) fill(png,x+24+bit*23,y+101,13,14,'19384e');
    }
  });
}
const copy=require('../tests-fixtures/poster-design-copy-20261104.json').cases.find(c=>c.id==='product-photo');
const originals=tag!=='dense'?[sheet(0,8),sheet(8,5),bitmap('test-logo',180,96,img=>{
  fill(img,22,14,28,68,'143782');fill(img,50,55,104,27,'143782');
})]:[];
function uri(name){return 'https://fixture.myqcloud.com/user/'+hash(owner).slice(0,24)+'/assets/'+hash(fs.readFileSync(name))+'.png';}
const text=tag==='dense'?copy.text:[
 {key:'t',role:'title',text:'北线设备联展'},
 {key:'s',role:'subtitle',text:'十三件原件，按编号核对'},
 {key:'b',role:'body',text:'验收顺序：先核对设备外观，再按项目清单交接。'},
 {key:'c',role:'footer',text:'现场咨询请联系园区设备组'}];
const prompt=tag==='dense'?copy.instruction:'给园区同事做张设备联展海报，型号和原件全部对上，Logo 用原件。';
const user=tag==='dense'?prompt+' 做一张3:4海报，下面每段请原样上图，版式你定。\n'+text.map(t=>t.text).join('\n'):prompt;
const spec=tag==='dense'?mark({text},user):{text,print_catalog:{version:1,sheets:2,logo:true}};
const body={requestId:'fidelity-local-'+tag,prompt,structured:spec,task_kind:originals.length?'reference':'generate',
 render_intent:'flat_artwork',aspect_ratio:originals.length?'16:9':'3:4',size:'2K',...(originals.length?{image:originals.map(uri)}:{})};
const authored='图1保留轮廓，图2作为配色参考，图3保留 Logo。\n用红白黑杂志风格，标题只写「设备录」。';
if(tag==='raw'){
 const {resolve,apply}=require('../cloudfunctions/bf-api/intent-contract');
 const parts=[{type:'text',text:'把下面提示词原样传给绘图模型：'+authored+'\n\n【图片文字OCR（辅助，可能有误差）：a.png】\n错误标题'},...originals.map(name=>({type:'image_url',image_url:{url:uri(name)}}))];
 const tool={function:{name:'image_generate',arguments:JSON.stringify({source:'attached',source_indexes:[1,2,3],prompt:'旧的固定风格',structured:{image_plan:{protected_references:[{role:'logo',index:1}]}}})}};
 const args=JSON.parse(apply([tool],resolve({messages:[{role:'user',content:parts}]}))[0].function.arguments);
 body.structured=args.structured;body.prompt=args.prompt;
}
const art=process.argv[3]?path.resolve(process.argv[3]):bitmap('placeholder',768,512,img=>fill(img,0,0,768,512,'315267'));
const port=tag==='dense'?19264:19265;
const env={...process.env,NATIVE_FIXTURE_PORT:String(port),FIXTURE_PRODUCTION_IMAGE_MODE:'1',FIXTURE_PRIMARY_IMAGE:art,
 FIXTURE_CAPTURE_SOURCE_ORDER:'1',FIXTURE_OWNED_INPUTS:JSON.stringify(originals),FIXTURE_CAPTURE_PROVIDER:file(tag+'-request.json'),
 FIXTURE_CAPTURE_MANIFEST:file(tag+'-manifest.json'),FIXTURE_ARTIFACT_DIR:file('assets-'+tag)};
const child=spawn(process.execPath,['--require',path.join(__dirname,'native-copy-http-fixture-hook.cjs'),path.join(root,'cloudfunctions/bf-image/index.js')],{env,stdio:['ignore','pipe','pipe'],windowsHide:true});
let logs='';
for(const stream of [child.stdout,child.stderr])stream.on('data',data=>{logs+=data;});
async function req(url,payload){
 const res=await fetch('http://127.0.0.1:'+port+url,{method:payload?'POST':'GET',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},...(payload?{body:JSON.stringify(payload)}:{}),signal:AbortSignal.timeout(145000)});
 return {status:res.status,data:await res.json()};
}
async function main(){
 for(let n=0;n<80;n++){
   try{if((await req('/ping')).status===200) break;}catch{}
   if(child.exitCode!==null)throw Error('fixture exited');
   await new Promise(resolve=>setTimeout(resolve,250));
 }
 await req('/__fixture/account/expired');assert.equal((await req('/image',body)).status,403);
 await req('/__fixture/account/empty');assert.equal((await req('/image',body)).status,429);
 await req('/__fixture/account/active');
 if(tag==='catalog'){
   const foreign=body.image.map(u=>u.replace(hash(owner).slice(0,24),'0'.repeat(24)));
   assert.equal((await req('/image',{...body,image:foreign})).status,422);
 }
 assert.equal((await req('/__fixture/state')).data.calls.primary,0);
 const response=await req('/image',body);
 assert.equal(response.status,200,JSON.stringify(response.data).slice(0,350));
 if(tag==='raw'){
   const request=JSON.parse(fs.readFileSync(env.FIXTURE_CAPTURE_PROVIDER));
   assert.equal(request.prompt,authored);assert.deepEqual(request.sourceOrder,body.image.map(hash));
   const replay=await req('/image',body);assert.equal(replay.data.cached,true);assert.equal(replay.data.cost,0);
   const report={scope:'old iPad combined OCR envelope → candidate intent contract → HTTP image handler → supplier fixture',
     exactPrompt:true,sourceOrder:'3/3',replayCost:replay.data.cost,paidCalls:0};
   fs.writeFileSync(file('raw-offline.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report));return;
 }
 const result=file('assets-'+tag+'/'+response.data.url.split('/').at(-1)+'.png');
 const rendered=PNG.sync.read(fs.readFileSync(result));
 const manifest=JSON.parse(fs.readFileSync(env.FIXTURE_CAPTURE_MANIFEST));
 assert.equal(manifest.itemCount,text.length);
 if(tag==='dense') assert.equal(manifest.design.styleId,'hyperreal-product','暖白摄影须保留摄影风格');
 assert.deepEqual(manifest.boxes.map(b=>b.key).sort(),text.map(t=>t.key).sort());
 assert.equal(manifest.copyHash,hash(JSON.stringify(text.map(t=>[t.key,t.text]))));
 const compiled=JSON.parse(fs.readFileSync(env.FIXTURE_CAPTURE_PROVIDER));
 assert.equal(compiled.imageCount,0);
 assert.ok(!compiled.prompt.includes(text.at(-1).text));
 let matched=0;
 if(originals.length){
   for(const [k,zone] of manifest.assets.filter(z=>z.role==='catalog').entries()){
     assert.equal(zone.sourceSha256,hash(fs.readFileSync(originals[k])));
     const [x,y,w,h]=zone.box;
     const count=k===0?8:5,start=k===0?0:8;
     for(let i=0;i<count;i++){
       const px=Math.floor((x+w*((i%2+.5)/2))*rendered.width);
       const py=Math.floor((y+h*((Math.floor(i/2)+.4)/Math.ceil(count/2)))*rendered.height);
       const index=(py*rendered.width+px)*4;
       assert.equal(rendered.data.subarray(index,index+3).toString('hex'),palette[start+i]);matched++;
     }
   }
   assert.equal(matched,13);
   assert.equal(manifest.assets.find(z=>z.role==='logo').sourceSha256,hash(fs.readFileSync(originals[2])));
   assert.equal((await req('/image',{...body,image:[body.image[1],body.image[0],body.image[2]]})).status,409);
 }
 const replay=await req('/image',body);
 assert.equal(replay.status,200);assert.equal(replay.data.cached,true);assert.equal(replay.data.cost,0);
 const state=(await req('/__fixture/state')).data;assert.equal(state.calls.primary,1);assert.equal(state.calls.vision,0);
 const stage=process.argv[3]?'recorded':'offline';
 fs.copyFileSync(result,file(tag+'-'+stage+'.png'));
 const report={tag,stage,copyChars:text.reduce((n,t)=>n+t.text.length,0),items:manifest.itemCount,copyHash:manifest.copyHash,
   fontPx:manifest.fontSize,canvas:[rendered.width,rendered.height],matched,ownAssetCount:originals.length,supplierImageCount:compiled.imageCount,
   cached:replay.data.cached,cachedCost:replay.data.cost,supplierFixtureCalls:state.calls,customerCalls:0};
 fs.writeFileSync(file(tag+'-'+stage+'.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report));
}
main().catch(e=>{console.error(e.message);process.exitCode=1;}).finally(()=>{fs.writeFileSync(file(tag+'-fixture.log'),logs);child.kill();});
