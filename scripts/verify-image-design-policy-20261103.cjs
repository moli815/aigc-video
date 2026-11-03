// Isolated real planning checks. Never generates images or reads customer chats.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const sdk=require(path.resolve('cloudfunctions/bf-api/node_modules/@cloudbase/node-sdk'));
const c=JSON.parse(fs.readFileSync(path.join(process.env.USERPROFILE,'.config/.cloudbase/auth.json'),'utf8')).credential;
const db=sdk.init({env:'xmy-test-d5g8c0xcifcefcfd5',region:'ap-shanghai',secretId:c.tmpSecretId,secretKey:c.tmpSecretKey,sessionToken:c.tmpToken}).database();
const host='https://xmy-test-d5g8c0xcifcefcfd5-1449098021.ap-shanghai.app.tcloudbase.com';
const folder='outputs/design-policy-20261103';fs.mkdirSync(folder,{recursive:true});
const id='design-policy-'+crypto.randomBytes(5).toString('hex');let token='',created=false;
const report={at:new Date().toISOString(),cases:[],imagesGenerated:0};
const cases=[
 {id:'context-guide',messages:[{role:'user',content:'我们是安防报警运营商，去参加安防展。需要给同行老板看的参展行动指南，帮助找合作、找渠道、找场景和找联动，不是我们公司的预约广告。信息要具体，包含优先找谁、三天怎么行动、现场问什么、怎么筛选及下一步。没有提供展馆号，不要编造。'}, {role:'assistant',content:'先前草稿建议做公司预约广告，并去A馆。这个草稿还没确认。'}, {role:'user',content:'就按刚才的参展要求做9:16海报，给报警行业老板用，信息具体，不要编馆号。'}],purpose:'action_guide'},
 {id:'latest-minimal',messages:[{role:'user',content:'做详细参展攻略海报，内容要丰富。'},{role:'assistant',content:'可以分为走访、筛选、跟进等部分。'},{role:'user',content:'这次改成极简预约广告，不做参展攻略。白底留白，不要蓝色科技风，只保留“中防AI现场体验”“预约专属演示”和热线400-7758-119，不要增加其他画面文字。'}],purpose:'advertisement'},
 {id:'new-industry',messages:[{role:'user',content:'我们做安防报警，之前做过深蓝科技风展会海报。'},{role:'assistant',content:'之前的参展攻略已结束。'},{role:'user',content:'换一个任务：给朋友的咖啡店做新品拿铁海报，用真实咖啡摄影，温暖自然光，要说明咖啡风味、到店体验及适合的日常场景。没有提供价格或地址，不要编造。店名“晨光咖啡”，新品名“榛香拿铁”。'}],purpose:'advertisement'}
];
const tool={type:'function',function:{name:'image_generate',description:'根据用户要求生成图片',parameters:{type:'object',properties:{prompt:{type:'string'},source:{type:'string'},aspect_ratio:{type:'string'},quality_tier:{type:'string'},structured:{type:'object',additionalProperties:true}},required:['prompt']}}};
async function call(url,body){const r=await fetch(host+url,{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+token},body:JSON.stringify(body),signal:AbortSignal.timeout(240000)});const s=await r.text();assert.equal(r.status,200,url+' HTTP '+r.status);return JSON.parse(s);}
(async()=>{try{
 const salt=crypto.randomBytes(16).toString('hex'),password=crypto.randomBytes(24).toString('hex'),now=new Date();
 await db.collection('bf_accounts').doc(id).set({username:id,displayName:'设计策略隔离验证',status:'active',tier:'ultra',expiresAt:new Date(Date.now()+3600000),createdAt:now,cycleAnchorAt:now,quotaOverrideCny:10,pwv:0,sv:0,chatUsedCny:0,imageUsedCny:0,passwordHash:'scrypt$'+salt+'$'+crypto.scryptSync(password,salt,64).toString('hex')});created=true;
 token=(await call('/api/login',{username:id,password})).token;
 for(const entry of cases){
  const started=Date.now();
  const response=await call('/api/chat',{stream:false,chatMode:'standard',max_tokens:8500,messages:entry.messages,tools:[tool],tool_choice:{type:'function',function:{name:'image_generate'}}});
  const toolCall=response.choices?.[0]?.message?.tool_calls?.[0];assert.ok(toolCall,entry.id+' missing tool call');
  const args=JSON.parse(toolCall.function.arguments);fs.writeFileSync(folder+'/'+entry.id+'.json',JSON.stringify({messages:entry.messages,args},null,2));
  const brief=args.structured?.design_brief;assert.ok(brief,entry.id+' missing brief');
  assert.equal(brief.purpose,entry.purpose,entry.id+' wrong deliverable purpose');
  assert.ok(brief.goal&&brief.audience&&brief.visual_approach);assert.ok(Array.isArray(brief.reader_questions));
  const items=args.structured.text;assert.ok(Array.isArray(items));const copy=items.map(i=>i.text||'').join('\n');
  if(entry.id==='context-guide'){assert.notEqual(brief.information_density,'sparse');assert.match(copy,/合作|渠道|联动/);assert.match(copy,/问|问题/);assert.doesNotMatch(copy,/[A-Z一二三四五六七八九]馆|预约专属演示/);}
  if(entry.id==='latest-minimal'){assert.equal(brief.information_density,'sparse');assert.match(copy,/中防AI现场体验/);assert.match(copy,/400-7758-119/);assert.doesNotMatch(copy,/三天|合作方|优先级/);}
  if(entry.id==='new-industry'){assert.match(copy,/晨光咖啡/);assert.match(copy,/榛香拿铁/);assert.doesNotMatch(copy,/安防|报警|400-|参展/);assert.match(brief.visual_approach+' '+args.prompt,/摄影|写实|真实/);}
  const row={id:entry.id,ms:Date.now()-started,purpose:brief.purpose,density:brief.information_density,copyChars:copy.length,items:items.length,ok:true};report.cases.push(row);console.log(JSON.stringify(row));
 }
 report.ok=true;
 }catch(e){report.ok=false;report.error=String(e.message).slice(0,350);console.error(report.error);process.exitCode=1;}
 finally{if(created){await db.collection('bf_accounts').doc(id).remove();report.temporaryAccountDeleted=true;}fs.writeFileSync(folder+'/live-planning-checks.json',JSON.stringify(report,null,2));}
})();
