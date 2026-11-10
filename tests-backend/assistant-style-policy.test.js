const test=require('node:test'),assert=require('node:assert/strict');
const {styleInstructions,tuneExpertCatalog,VERSION}=require('../cloudfunctions/bf-api/assistant-style-policy');
const {injectAssistantGuidance}=require('../cloudfunctions/bf-api/assistant-guidance');
const {isCommercialTask,injectCommercialImageGuidance}=require('../cloudfunctions/bf-api/commercial-image-guidance');
const {validateValue}=require('../cloudfunctions/bf-api/settings-schema');
test('online style settings reject misspelled fields, non-boolean flags and oversized instructions',()=>{
 const spec={type:'json',label:'style'};
 for(const value of ['null','{"enable":false}','{"enabled":"false"}',JSON.stringify({instructions:'a'.repeat(6001)})])assert.equal(validateValue('CHAT_STYLE_POLICY',value,spec).ok,false);
 assert.equal(validateValue('CHAT_STYLE_POLICY','{"enabled":false}',spec).ok,true);
 assert.equal(validateValue('CHAT_STYLE_POLICY','{"instructions":"直接回答"}',spec).ok,true);
 assert.equal(validateValue('CHAT_GROUNDED_REVIEW','{"enabled":true,"audience":"all"}',spec).ok,true);
 assert.equal(validateValue('CHAT_GROUNDED_REVIEW','{"enabled":"true"}',spec).ok,false);
 assert.equal(validateValue('CHAT_GROUNDED_REVIEW','{"enabled":true,"unknown":1}',spec).ok,false);
});
test('style is idempotent, can be tuned or disabled without disabling identity or dropping history',()=>{
 const user={role:'user',content:[{type:'text',text:'只改第二段'},{type:'image_url',image_url:{url:'PRIVATE_ASSET'}}]};
 const source=[{role:'system',content:'【必须遵循的工作流】先给三个选题；不得编造数据。'},user];
 const first=injectAssistantGuidance(source,{enabled:true}),again=injectAssistantGuidance(first,{enabled:true});
 assert.equal(first.at(-1).content,again.at(-1).content);assert.equal(again.filter(m=>m.content.includes(VERSION)).length,1);
 assert.equal(again[1],user);assert.equal(again[0],source[0]);assert.equal(source.length,2);
 const disabled=injectAssistantGuidance(first,'{"enabled":false}');assert.ok(!disabled.some(m=>m.content.includes(VERSION)));
 assert.match(disabled.at(-1).content,/中防AI专属智能助手/);
 assert.match(styleInstructions({enabled:true,instructions:'管理员选择的表达方式'}),/管理员选择的表达方式/);
 assert.equal(styleInstructions(undefined),'');assert.equal(styleInstructions({enabled:'true'}),'');
 assert.doesNotThrow(()=>styleInstructions('invalid-json'));assert.doesNotThrow(()=>styleInstructions(null));
});
test('expert changes preserve IDs, tools, starters outside this function and unrelated custom settings',()=>{
 const experts=[{id:'general',tools:['search'],custom:'keep'},{id:'short_video',role:'原角色',tools:['word'],deliverable:'word'}, {id:'custom',role:'老板自己写的角色',steps:['保留']}];
 const before=structuredClone(experts),out=tuneExpertCatalog(experts);
 assert.deepEqual(experts,before);assert.equal(out[2],experts[2]);assert.deepEqual(out[1].tools,['word']);assert.equal(out[0].custom,'keep');
 assert.deepEqual(tuneExpertCatalog(out),out);assert.ok(!out[1].steps.some(x=>x.startsWith('给 3 个')));
});
test('exhibition writing and company-background followups do not become commercial image planning',()=>{
 const tools=[{type:'function',function:{name:'image_generate'}}];
 const user={role:'user',content:'我们刚参加展会，写纯口播，不要剪辑建议。'};
 for(const text of [user.content,'不要解释，完善我的短视频文案','请只补充说明刚才生成的图片，不要重新生成图片']){
  const msgs=[user,{role:'user',content:text}];assert.equal(isCommercialTask(msgs,text),false);assert.equal(injectCommercialImageGuidance(msgs,tools,text),msgs);
 }
 const text='我现在给你的这张图里面的内容是我们参加展会时的展板上的内容';
 assert.equal(isCommercialTask([user,{role:'user',content:[{type:'text',text},{type:'image_url',image_url:{url:'PRIVATE'}}]}],text),false);
});
test('explicit image requests and independent followups remain available after a writing turn',()=>{
 const msgs=[{role:'user',content:'先写口播'},{role:'user',content:'然后做一张展会海报，用同样文案'}];
 assert.equal(isCommercialTask(msgs,msgs[1].content),true);
 assert.equal(isCommercialTask([{role:'user',content:'做一张展会海报'},{role:'user',content:'更真实一点'}],'更真实一点'),true);
});
