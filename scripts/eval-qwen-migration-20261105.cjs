"use strict";
// Isolated supplier evaluation. Does not change production code, settings or routing.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict'),cp=require('node:child_process');
const {compileQwenImage,qwenImageCost,parseQwenImageResponse}=require('../cloudfunctions/shared/image-provider-qwen');
const {createModelCallLedger}=require('../cloudfunctions/shared/model-call-ledger');
const {cases}=require('../tests-fixtures/complex-image-eval-20261104.cjs');
const {resolveImageSize}=require('../cloudfunctions/bf-image/image-sizing');
const {probeImageSize}=require('../cloudfunctions/bf-image/media-guards');
const sdk=require('../cloudfunctions/bf-api/node_modules/@cloudbase/node-sdk');
const scf=require(path.resolve('outputs/commercial-text-repair-20261104/ops-tools/node_modules/tencentcloud-sdk-nodejs-scf'));
const credential=JSON.parse(fs.readFileSync(path.join(process.env.USERPROFILE,'.config/.cloudbase/auth.json'),'utf8')).credential;
const cloudCredentials={secretId:credential.tmpSecretId,secretKey:credential.tmpSecretKey,sessionToken:credential.tmpToken};
const app=sdk.init({env:'xmy-test-d5g8c0xcifcefcfd5',region:'ap-shanghai',...cloudCredentials}),db=app.database();
const client=new scf.scf.v20180416.Client({credential:{secretId:credential.tmpSecretId,secretKey:credential.tmpSecretKey,token:credential.tmpToken},region:'ap-shanghai',profile:{httpProfile:{endpoint:'scf.tencentcloudapi.com',reqTimeout:180}}});
const root=path.resolve('outputs/qwen-image-migration-20261105'),file=path.join(root,'report.json');fs.mkdirSync(root,{recursive:true});
const report=fs.existsSync(file)?JSON.parse(fs.readFileSync(file,'utf8')):{startedAt:new Date().toISOString(),scope:'Synthetic fixtures; real current server chat planning plus isolated supplier calls and existing server compositor. No production routing/settings changes. Manual memory fixture is NOT real client recall. Not UIKit acceptance.',cases:[],status:'running'};
const doc=r=>Array.isArray(r.data)?r.data[0]:r.data,id='qwen-migration-'+crypto.randomBytes(6).toString('hex'),host='https://xmy-test-d5g8c0xcifcefcfd5-1449098021.ap-shanghai.app.tcloudbase.com';
let token='',env,fonts,engines,runtime,context={},created=false;
const ledger=createModelCallLedger({db,context:()=>context,source:'qwen-migration-eval',log:x=>console.log(JSON.stringify({tag:x.tag,code:x.code})),pricing:p=>({unitCostCny:p.model.startsWith('qwen-')?qwenImageCost(p):p.model.includes('pro')?.6:.12,costBasis:'official_public_image_rate_estimate'})});
const save=()=>fs.writeFileSync(file,JSON.stringify(report,null,2));
const errorText=e=>String(e.message||e.code||e.name).replace(/https?:\/\/\S+/g,'[url]').replace(/sk-[a-zA-Z0-9_-]+/g,'[secret]').slice(0,230);
const uri=filename=>{const b=fs.readFileSync(filename);return 'data:'+(b[0]===137?'image/png':'image/jpeg')+';base64,'+b.toString('base64');};
async function setup(){
 const d=await client.GetFunction({FunctionName:'bf-api',Namespace:'xmy-test-d5g8c0xcifcefcfd5'});env=Object.fromEntries((d.Environment?.Variables||[]).map(x=>[x.Key,x.Value]));
 runtime=doc(await db.collection('bf_config').doc('runtime').get()).data;
 const password=crypto.randomBytes(20).toString('hex'),salt=crypto.randomBytes(16).toString('hex'),now=new Date();
 await db.collection('bf_accounts').doc(id).set({username:id,displayName:'千问迁移隔离验收',status:'active',tier:'ultra',expiresAt:new Date(Date.now()+7200000),createdAt:now,cycleAnchorAt:now,quotaOverrideCny:120,pwv:0,sv:0,chatUsedCny:0,imageUsedCny:0,passwordHash:'scrypt$'+salt+'$'+crypto.scryptSync(password,salt,64).toString('hex')});created=true;
 const r=await fetch(host+'/api/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username:id,password}),signal:AbortSignal.timeout(30000)});assert.equal(r.status,200);token=(await r.json()).token;
 report.status='running';save();
}
async function generate(entry){
 const existing=report.cases.find(r=>r.id===entry.id);if(existing){console.log(JSON.stringify({id:entry.id,skipped:'record already exists; no duplicate supplier call'}));return existing;}
 const row={id:entry.id,name:entry.name,model:entry.model||'qwen-image-3.0-pro',status:'running',mode:entry.mode||'native',copy:entry.copy||'',prompt:entry.prompt,inputImages:entry.image?Array.isArray(entry.image)?entry.image.length:1:0};report.cases.push(row);save();
 try{
  // Never initiate a paid evaluation when its account/ledger cannot be reached.
  assert.equal(doc(await db.collection('bf_accounts').doc(id).get())?.username,id,'Evaluation account is not available');
  const source={prompt:entry.prompt,size:entry.size||'1536x1536',...(entry.image?{image:entry.image}:{})};
  let payload=row.model.startsWith('qwen-')?compileQwenImage(source,{model:row.model,promptExtend:entry.promptExtend,noText:entry.noText,seed:7319,protocol:'dashscope'}):{...source,model:row.model,response_format:'url',watermark:false,optimize_prompt_options:{mode:'standard'}};
  row.requestedSize=payload.size||payload.parameters?.size;row.promptChars=entry.prompt.length;row.protocol=row.model.startsWith('qwen-')?'dashscope':'ark';
  context={accountId:id,requestId:crypto.randomUUID(),businessRequestId:crypto.randomUUID(),endpoint:'isolated-qwen-migration-evaluation',taskKind:entry.image?'edit':'generate'};
  row.requestId=context.requestId;save();const start=Date.now();
  const url=row.model.startsWith('qwen-')?'https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation':'https://ark.cn-beijing.volces.com/api/v3/images/generations';
  const r=await ledger.fetch(url,{method:'POST',headers:{Authorization:'Bearer '+(row.model.startsWith('qwen-')?(env.DASHSCOPE_API_KEY||env.CHAT_API_KEY):env.IMAGE_API_KEY),'Content-Type':'application/json'},body:JSON.stringify(payload),signal:AbortSignal.timeout(260000)});
  row.http=r.status;row.modelCallId=r.modelCallId;row.vendorRequestId=r.headers.get('x-request-id')||'';row.ms=Date.now()-start;save();
  const raw=await r.text();let j;try{j=JSON.parse(raw);}catch{row.responseBytes=Buffer.byteLength(raw);throw Error('NON_JSON_RESPONSE HTTP '+r.status);}
  row.vendorRequestId||=j.request_id||'';
  if(!r.ok){row.upstreamCode=j.error?.code||j.code;throw Error('HTTP '+r.status+' '+String(j.error?.message||j.message||row.upstreamCode||'').slice(0,160));}
  const out=row.model.startsWith('qwen-')?parseQwenImageResponse(j):{url:j.data?.[0]?.url,usage:j.usage};assert.ok(out.url);
  row.usage=out.usage;row.supplierEstimateCny=row.model.startsWith('qwen-')?qwenImageCost(payload,out.usage):.6;
  const media=await fetch(out.url,{signal:AbortSignal.timeout(45000)});assert.equal(media.status,200);const bytes=Buffer.from(await media.arrayBuffer());
  const filename=entry.id+(bytes[0]===137?'.png':'.jpg');fs.writeFileSync(path.join(root,filename),bytes);row.imageFile=filename;row.dimensions=probeImageSize(bytes);
  if(entry.mode==='composition')await composeResult(row,entry,bytes);
  row.status='generated_pending_visual_review';
  try{const ocr=path.join(root,entry.id+'-ocr.json');cp.execFileSync('powershell.exe',['-NoProfile','-ExecutionPolicy','Bypass','-File','scripts/local-image-ocr.ps1','-ImagePath',path.join(root,row.imageFile),'-OutputPath',ocr],{timeout:60000,stdio:'pipe'});const o=JSON.parse(fs.readFileSync(ocr,'utf8'));row.ocrFile=path.basename(ocr);row.ocrText=o.text;row.ocrRequired=(entry.required||[]).map(t=>({text:t,found:String(o.text).replace(/\s/g,'').includes(t.replace(/\s/g,''))}));}catch{row.ocrUnavailable=true;}
  try{await db.collection('bf_model_calls').doc(r.modelCallId).update({evaluationOnly:true,chargeState:'not_charged',costBasis:'official_public_image_rate_estimate',supplierCostEstimateCny:row.supplierEstimateCny});}
  catch{row.auditRecoveryNeeded=true;throw Error('Image generated; test ledger requires credential refresh and recovery; do not generate again');}
 }catch(e){row.status=row.imageFile?'generated_audit_or_review_incomplete':'failed';row.error=errorText(e);}
 save();console.log(JSON.stringify({id:row.id,status:row.status,ms:row.ms,cost:row.supplierEstimateCny,error:row.error,dimensions:row.dimensions}));return row;
}
async function getFonts(){if(fonts)return fonts;fonts=[];for(const spec of JSON.parse(runtime.IMAGE_COMPOSITION_POLICY).fonts){const signed=await app.getTempFileURL({fileList:[{fileID:spec.fileId,maxAge:120,urlType:'COS_URL'}]});const r=await fetch(signed.fileList[0].tempFileURL);assert.equal(r.status,200);const b=Buffer.from(await r.arrayBuffer());assert.equal(crypto.createHash('sha256').update(b).digest('hex'),spec.sha256);fonts.push({name:'Noto CJK',weight:spec.weight,style:'normal',data:b});}return fonts;}
async function composeResult(row,entry,artwork){
 const {loadEngines}=require('../cloudfunctions/bf-image/commercial-composition-runtime');engines||=await loadEngines();
 const [width,height]=entry.outputSize.split('x').map(Number);const {compose}=require('../cloudfunctions/bf-image/commercial-composer');
 const result=await compose({structured:entry.structured,prompt:entry.designPrompt,width,height,fonts:await getFonts(),background:'data:image/'+(artwork[0]===137?'png':'jpeg')+';base64,'+artwork.toString('base64'),satori:engines.satori,resvg:engines.resvg,designEngine:'poster'});
 row.artworkFile=row.imageFile;row.imageFile=entry.id+'-composed.png';fs.writeFileSync(path.join(root,row.imageFile),result.png);row.compositionManifest=result.manifest;row.copy=entry.structured.text.map(x=>x.text).join('\n');row.dimensions=probeImageSize(result.png);
}
const item={type:'object',properties:{key:{type:'string'},role:{type:'string',enum:['title','subtitle','body','label','contact','footer']},text:{type:'string'}},required:['key','role','text']};
const tools=[{type:'function',function:{name:'image_generate',description:'生成完整商业图片。精确文案按语义放在structured.text，不得删减用户已确认信息。',parameters:{type:'object',properties:{prompt:{type:'string'},aspect_ratio:{type:'string'},quality_tier:{type:'string'},structured:{type:'object',properties:{text:{type:'array',items:item}},additionalProperties:true}},required:['prompt','structured']}}}];
async function planScene(entry){
 const stored=path.join(root,entry.id+'-plan.json');if(fs.existsSync(stored))return JSON.parse(fs.readFileSync(stored,'utf8'));
 let remain=48000;const trimmed=[];for(const m of entry.messages.slice(-40).reverse()){if(remain<=0)break;const content=m.content.slice(0,remain);remain-=content.length;trimmed.push({...m,content});}trimmed.reverse();
 const messages=[{role:'system',content:'你是中防AI专属智能助手。使用合成测试资料，不联网。按用户最终批准资料直接调用image_generate，不增加未经确认事实。structured.text每项只含字符串key/role/text，按语义分组并保留全部信息。视觉风格遵循用户要求。'+(entry.memory?'\n已确认历史摘要夹具：'+entry.memory:'')},...trimmed];
 fs.writeFileSync(path.join(root,entry.id+'-context.json'),JSON.stringify({scope:'Actual 40-message / 48000-character replay; supplied summary is a fixture, not verified memory retrieval.',sourceMessages:entry.messages.length,sourceChars:entry.messages.reduce((n,m)=>n+m.content.length,0),sent:messages},null,2));
 const began=Date.now(),r=await fetch(host+'/api/chat',{method:'POST',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json','X-Request-Id':crypto.randomUUID()},body:JSON.stringify({messages,tools,stream:false,chatMode:'standard',max_tokens:10500}),signal:AbortSignal.timeout(200000)});const j=await r.json();assert.equal(r.status,200,'Planning failed '+r.status);
 const call=j.choices?.[0]?.message?.tool_calls?.find(x=>x.function?.name==='image_generate');assert.ok(call,'No image tool');const args=JSON.parse(call.function.arguments);assert.ok(Array.isArray(args.structured?.text));
 const copy=args.structured.text.map(x=>x.text).join('\n'),result={args,copy,planMs:Date.now()-began,retainedMessages:trimmed.length,sentContextChars:messages.reduce((n,m)=>n+m.content.length,0),checks:entry.checks.map(([re,name])=>({name,present:re.test(copy)})),forbidden:entry.forbidden.filter(x=>copy.includes(x))};
 fs.writeFileSync(stored,JSON.stringify(result,null,2));return result;
}
const portraitPrompt='纪实商业摄影，半身至膝上的25岁成年东亚女性，短而蓬松的深棕卷发，细金边圆框眼镜，红色针织开衫，米白色衬衫，深灰长裤。她在阳光柔和的现代展馆中面向镜头，自信而自然，轻微微笑，双手自然放松。真实皮肤纹理、清晰眼镜结构、自然手指、真实布料纤维、柔和接触阴影、摄影级景深。背景是米白墙与绿植，不出现文字、标识或水印，不要塑料皮肤或卡通。';
async function reviewPosters(){
 const {compose}=require('../cloudfunctions/bf-image/commercial-composer');
 const {loadEngines,EMPTY}=require('../cloudfunctions/bf-image/commercial-composition-runtime');
 const {artworkPrompt}=require('../cloudfunctions/bf-image/commercial-artwork');engines||=await loadEngines();
 for(const code of ['B-procurement-matrix','D-memory-wide-board','E-revision-injection']){
  const entry=cases.find(x=>x.id===code),plan=await planScene(entry),structured=plan.args.structured;
  const outputSize=resolveImageSize('2K',entry.ratio),[width,height]=outputSize.split('x').map(Number);
  const prepared=await compose({structured,prompt:plan.args.prompt,width,height,fonts:await getFonts(),background:EMPTY,satori:engines.satori,resvg:engines.resvg,designEngine:'poster'});
  const model=code==='D-memory-wide-board'?'qwen-image-3.0-pro':'qwen-image-3.0';
  const prompt=artworkPrompt(structured,prepared.manifest.artwork)+'\n当前只生成商业视觉素材层，成品由服务器用准确文案排版。不得出现文字、字符、数字、商标或预留文字框。';
  const row=await generate({id:code+'-production-artwork',name:entry.name+' · 实际线上素材编译',model,mode:'composition',structured,designPrompt:plan.args.prompt,outputSize,prompt,size:resolveImageSize('2K',prepared.manifest.artwork.aspectRatio),promptExtend:false,copy:plan.copy});
  row.promptCompiler='actual commercial-artwork.js and commercial-composer.js';row.planning={planMs:plan.planMs,retainedMessages:plan.retainedMessages,sentContextChars:plan.sentContextChars,copyChars:plan.copy.length,checks:plan.checks,forbidden:plan.forbidden};save();
 }
 // Native dense-copy comparison isolates model text rendering from our compositor.
 const native=await planScene(cases.find(x=>x.id==='B-procurement-matrix'));
 for(const model of ['qwen-image-3.0-pro','qwen-image-3.0','doubao-seedream-5-0-pro-260628'])await generate({id:'dense-native-'+(model==='qwen-image-3.0-pro'?'qwen-pro':model==='qwen-image-3.0'?'qwen-standard':'seedream'),name:'1083字采购矩阵 · 模型原生文字对照',model,prompt:native.args.prompt+'\n【全部准确原文，不允许漏项或改变字段对应关系】\n'+native.copy,copy:native.copy,size:'2816x1584',required:['6800','12800','21800','400-810-2026','365']});
}
async function finalDiagnostics(){
 const {compose}=require('../cloudfunctions/bf-image/commercial-composer'),{loadEngines,EMPTY}=require('../cloudfunctions/bf-image/commercial-composition-runtime'),{artworkPrompt}=require('../cloudfunctions/bf-image/commercial-artwork');engines||=await loadEngines();
 for(const code of ['D-memory-wide-board','E-revision-injection']){
  const entry=cases.find(x=>x.id===code),plan=await planScene(entry),structured=plan.args.structured,outputSize=resolveImageSize('2K',entry.ratio),[width,height]=outputSize.split('x').map(Number);
  const pre=await compose({structured,prompt:plan.args.prompt,width,height,fonts:await getFonts(),background:EMPTY,satori:engines.satori,resvg:engines.resvg,designEngine:'poster'});
  await generate({id:code+'-negative-no-text',name:entry.name+' · 原生反向约束复核',model:code==='D-memory-wide-board'?'qwen-image-3.0-pro':'qwen-image-3.0',mode:'composition',structured,designPrompt:plan.args.prompt,outputSize,prompt:artworkPrompt(structured,pre.manifest.artwork),size:resolveImageSize('2K',pre.manifest.artwork.aspectRatio),promptExtend:false,noText:true,copy:plan.copy});
 }
 const prompt='保持参考图同一位女性的面部、短卷发、细金边圆框眼镜、红色针织开衫、米白衬衫全部不变，只把背景改成暖色木质咖啡厅。保持原来姿态、镜头、人物大小；不要换脸、换衣或增添人物，重建自然接触阴影与光色。无任何文字。';
 for(const model of ['qwen-image-3.0-pro','doubao-seedream-5-0-pro-260628'])await generate({id:'edit-direct-'+(model.startsWith('qwen-')?'qwen':'seedream'),name:'同原图换背景 · '+(model.startsWith('qwen-')?'千问关闭改写':'Seedream基线'),model,prompt,promptExtend:false,image:uri(path.join(root,'portrait-pro.png')),size:'1536x2048'});
}
async function suite(){
 const p=await generate({id:'portrait-pro',name:'写实人物：Pro',prompt:portraitPrompt,size:'1536x2048'});
 if(p.status==='failed')throw Error('Initial real model generation failed; stopped before batch');
 if(process.argv.includes('--smoke'))return;
 await generate({id:'portrait-standard',name:'同条件写实人物：标准版',model:'qwen-image-3.0',prompt:portraitPrompt,size:'1536x2048'});
 for(const code of ['A-expo-guide','B-procurement-matrix','D-memory-wide-board','E-revision-injection']){
  const entry=cases.find(x=>x.id===code);let plan;
  try{plan=await planScene(entry);}catch(e){report.planningErrors||=[];report.planningErrors.push({id:code,error:errorText(e)});save();continue;}
  const models=code==='A-expo-guide'?['qwen-image-3.0-pro','qwen-image-3.0']:['qwen-image-3.0-pro'];
  for(const model of models){const suffix=model.endsWith('-pro')?'pro':'standard';const structured=plan.args.structured;
   const input={id:code+'-'+suffix,name:entry.name+' · '+suffix,model,prompt:plan.args.prompt+'\n【图中准确原文，必须完整保留】\n'+plan.copy,size:resolveImageSize('2K',entry.ratio),copy:plan.copy,required:code==='D-memory-wide-board'?['青禾智储S240','240kWh','CY-7319','400-620-7319']:code==='A-expo-guide'?['400-810-2026','A1','B2','C3','48']:['6800','12800','21800']};
   // Compare raw model typography for the same dense A brief; preserve current
   // server composition for other complex scenarios (not a new layout change).
   if(code!=='A-expo-guide'){input.mode='composition';input.structured=structured;input.outputSize=resolveImageSize('2K',entry.ratio);input.designPrompt=plan.args.prompt;input.prompt=plan.args.prompt+'\n当前只生成无字商业视觉素材，所有标题、正文、数字、商标、电话由后续程序一次准确排版。画面不得出现文字、字符、数字、水印或预留文字框。场景需完整、写实、光影自然。';input.size=resolveImageSize('2K','3:1');input.promptExtend=false;}
   const row=await generate(input);row.planning={planMs:plan.planMs,retainedMessages:plan.retainedMessages,sentContextChars:plan.sentContextChars,copyChars:plan.copy.length,checks:plan.checks,forbidden:plan.forbidden};save();
  }
 }
 const person=uri(path.join(root,p.imageFile));
 await generate({id:'person-edit-pro',name:'人物身份与局部编辑 · Pro',image:person,size:'1536x2048',prompt:'保持参考图同一位女性的面部、短卷发、细金边圆框眼镜、红色针织开衫、米白衬衫全部不变，只把背景改成暖色木质咖啡厅。保持原来姿态、镜头、人物大小；不要换脸、换衣或增添人物，重建自然接触阴影与光色。无任何文字。'});
 const base=uri(path.resolve('outputs/poster-design-20261104/live-1793796794984/expo-blue-artwork.jpg'));
 const cabinet=uri(path.resolve('outputs/poster-design-20261104/live-1793796794984/product-photo-artwork.jpg'));
 await generate({id:'two-ref-person-standard',name:'两图合成与人物保持 · 标准版',model:'qwen-image-3.0',image:[base,person],size:'2816x1584',prompt:'以图1蓝白展馆为底图，把图2的同一位短卷发、金边圆框眼镜、红色开衫女性放在左侧前景站立。必须保留图2面部、发型、眼镜、服装，不得替换为其他人。人物比例、透视、地面接触阴影与展馆光线一致；保留右侧展板和大致布局，不添加文字。'});
 await generate({id:'three-ref-commercial-pro',name:'三张素材复杂商业合成 · Pro',image:[base,person,cabinet],size:'2816x1584',prompt:'图1是底图，图2是必须保留身份的真实素材女性，图3是深青色工业储能柜产品。保留图1展馆大致布局，在左前景加入图2同一位短卷发金边圆框眼镜红开衫女性，在右前景加入图3同款深青储能柜，保持通风格栅、浅色侧板、厚重比例。人物不遮挡产品，产品不过大，统一透视、色温、接触阴影和摄影级质感，不照搬图3工程师。不得添加文字。'});
 // A same-prompt supplier baseline: no assumption that a different seed means
 // identity equality. Evaluate photographic quality/content only.
 await generate({id:'portrait-seedream-baseline',name:'同条件 Seedream Pro 人物基线',model:'doubao-seedream-5-0-pro-260628',prompt:portraitPrompt,size:'1536x2048'});
 report.compatibilityFailures=[{feature:'4 current+historical reference inputs',code:'QWEN_REFERENCE_LIMIT',existing:'4 supported by current mixed-reference contract',candidate:'maximum 3; may not drop a source'},{feature:'9:1 output',code:'QWEN_RATIO_UNSUPPORTED',existing:'current Seedream allows supported 9:1 canvases',candidate:'maximum 8:1; may not crop silently'},{feature:'native layer decomposition',code:'QWEN_LAYERS_UNSUPPORTED',existing:'Seedream layer_decomposition contract',candidate:'not documented by Qwen 3.0 API; cannot claim equivalent'}];
}
(async()=>{try{await setup();if(process.argv.includes('--final-diagnostics'))await finalDiagnostics();else if(process.argv.includes('--poster-review'))await reviewPosters();else await suite();report.status='completed_pending_review';}catch(e){report.status='failed';report.error=errorText(e);process.exitCode=1;}finally{
 if(created)try{await db.collection('bf_accounts').doc(id).remove();report.temporaryAccountsDeleted=true;}catch{report.cleanupFailed=true;}
 report.finishedAt=new Date().toISOString();save();console.log(JSON.stringify({status:report.status,cases:report.cases.length,error:report.error,productionChanged:false}));
}})();
