"use strict";
const test=require('node:test');
const assert=require('node:assert/strict');
const ref=require('../cloudfunctions/bf-api/reference-text');
const guard=require('../cloudfunctions/bf-api/requirement-guard');
const poster=require('../cloudfunctions/shared/poster-delivery');
const brand=require('../cloudfunctions/bf-api/poster-brand-guidance');

test('restyling uses the current whole diagram and keeps source terminology',()=>{
  const user='帮我把这张图片重新帮我生成一张换一种风格';
  const part=s=>({type:'image_url',image_url:{url:'data:image/png;base64,'+s}});
  const a=[{role:'user',content:[part('old')]},{role:'user',content:[{type:'text',text:user},part('new')]}];
  assert.equal(ref.firstUserImage(a), 'data:image/png;base64,new');
  assert.ok(ref.shouldTranscribe(a));
  assert.ok(poster.nativePoster({source:'attached',prompt:'产品结构海报'},user));
  assert.ok(poster.nativePoster({source:'attached',prompt:'重新绘制这张产品系统架构图'},user,{referenceDesign:true}));
  assert.ok(!poster.nativePoster({source:'attached',prompt:'把肖像重画成插画'},user));
  assert.ok(poster.nativePoster({source:'attached',prompt:'产品结构海报'},'只换一种风格，保留原图比例'));
  assert.ok(!poster.nativePoster({source:'attached',prompt:'产品结构海报'},'只换这个Logo，其余内容不变'));
  assert.equal(guard.classify([{index:1,size:{w:2709,h:3200}}],user).poster.index,1);
  assert.ok(!ref.restylesReference('换个风格，删掉原来的栏目'));
  const terms=ref.linesOf('400-7758-119\n- 无线门磁\n红外探测器\n？烟雾\nPGM接口');
  const blocks=ref.keepSourceLines([{key:'first',text:'现有 PGM 接口',role:'body'}],terms);
  assert.deepEqual(blocks.map(b=>b.text),['现有 PGM 接口','400-7758-119','无线门磁','红外探测器']);
  assert.equal(ref.keepSourceLines(blocks,terms).length,blocks.length);
  const structured=poster.mark({text:blocks},user,{referenceRedesign:true});
  const final=poster.compile({visual:'浅灰白背景、四列卡片、不用照片',structured,density:'dense'});
  assert.doesNotMatch(final,/浅灰白背景|四列卡片|不用照片/);
  assert.match(final,/原图主标题/);
  assert.match(final,/"无线门磁"/);
});

test('explicit style is passed to the request ahead of default artistic guidance',()=>{
  const direction='改成红白摄影杂志风，右侧留白，不要图标';
  const s=poster.mark({text:[{key:'title',role:'title',text:'平台核心能力'}]},direction);
  const prompt=poster.compile({visual:'主题是设备管理',structured:s,density:'dense'});
  assert.ok(prompt.indexOf(direction)<prompt.indexOf('主题是设备管理'));
  assert.match(prompt,/"平台核心能力"/);
  assert.ok(!poster.mark({},'帮我做一张商业海报').poster_delivery.user_direction);
  const marked=poster.mark({text:[{key:'title',role:'title',text:'小雪'}]},'做张小雪海报');
  const cfg={structured:marked,prompt:'江南雪景。不要出现任何文字。',taskKind:'generate',selectedModel:'doubao-seedream-5-5-test'};
  assert.equal(poster.modeFor(cfg),'dense');
  assert.match(poster.compile({visual:cfg.prompt,structured:marked,density:'dense'}),/"小雪"/);
  assert.doesNotMatch(poster.compile({visual:cfg.prompt,structured:marked,density:'dense'}),/不要出现任何文字/);
  assert.equal(poster.modeFor({...cfg,structured:{...marked,poster_delivery:undefined}}),null);
  assert.equal(poster.modeFor({...cfg,textMode:'overlay'}),null);
});

test('brand compositing attaches one original only for eligible new company posters',()=>{
  const text='给我们公司做一张小雪宣传海报，Logo放右上角';
  const make=a=>({function:{name:'image_generate',arguments:JSON.stringify(a)}});
  const binding={fileId:'A37F4CB4-FF43-446D-8D73-F5959DB50D8F'};
  assert.ok(brand.requestedBrand(text));
  assert.ok(!brand.requestedBrand('给我们公司做小雪海报，不用Logo'));
  assert.ok(!brand.brandEnabled({enabled:true,audience:'all'},'x'));
  assert.ok(!brand.brandEnabled({enabled:true,accountIds:['y'],posterBrand:true},'x'));
  const [out]=brand.addBrand([make({source:'none',prompt:'小雪海报'})],binding,text);
  const args=JSON.parse(out.function.arguments);
  assert.equal(args.structured.poster_brand.anchor,'top_right');
  assert.deepEqual(args.structured.image_references,{version:1,mode:'replace',items:[{kind:'library',id:binding.fileId,role:brand.BRAND_ROLE}]});
  assert.deepEqual(brand.addBrand([out],binding,text),[out]);
  const current=make({source:'attached',prompt:'小雪海报',source_indexes:[1]});
  assert.deepEqual(brand.addBrand([current],binding,text),[current]);
});

test('a long request keeps explicit art direction without copying its background notes to the image prompt',()=>{
  const accepted='改成红白杂志风，右侧留白，不要图标，不加装饰';
  const notes='本段项目资料供理解，成品只照定稿排版。'.repeat(25);
  const text=[{key:'title',role:'title',text:'设备巡检与资料归档'}];
  const s=poster.mark({text},notes+accepted,{referenceRedesign:true});
  const p=poster.compile({visual:'给原图套金色发光卡片',structured:s,density:'dense'});
  assert.ok(s.poster_delivery.user_direction.includes(accepted));
  assert.match(p,/红白杂志风.*右侧留白.*不要图标.*不加装饰/);
  assert.doesNotMatch(p,/金色发光卡片|本段项目资料|背景与主体有层次/);
});

test('default production remains rich when asked not to be minimal, and exact long copy is retained once',()=>{
  const text=Array.from({length:18},(_,i)=>({key:'row'+i,role:'body',text:'能力'+(i+1)+'：登记设备位置、维修记录与现场照片，方便交接人员按点位复查。'}));
  const s=poster.mark({text,design_brief:{visual_approach:'暖白卡片'},},'帮我做一张海报，别做成极简，按资料说全。');
  assert.equal(s.poster_delivery.density,'dense');
  const p=poster.compile({visual:'工业园区真实场景，设备柜作为主视觉。',structured:s,density:'dense'});
  for (const row of text) assert.equal(p.split(JSON.stringify(row.text)).length,2);
  assert.doesNotMatch(p,/暖白卡片/);
  assert.equal(poster.mark({},'这次做一张极简海报').poster_delivery.density,'sparse');
});

test('delegating style keeps the content-led visual defaults without overriding actual direction',()=>{
  const text=[{key:'title',role:'title',text:'园区设备运营协作指南'},{key:'body',role:'body',text:'逐项保留现场记录'}];
  const user='按刚才说的做一张海报。每段原样上图，版式你自己定。';
  const ordinary=poster.mark({text},user);
  assert.equal(ordinary.poster_delivery.user_direction,undefined);
  for(const structured of [ordinary,{...ordinary,poster_delivery:{...ordinary.poster_delivery,user_direction:user}}]){
    const p=poster.compile({visual:'清楚的园区场景',structured,density:'dense'});
    assert.match(p,/把标题融入主视觉.*关键分区.*延续到大块空底/);
    for(const row of text) assert.equal(p.split(JSON.stringify(row.text)).length,2);
  }
  const explicit=poster.mark({text},'版式你自己定，但纯白背景，不加装饰。');
  const p=poster.compile({visual:'保留足够对比度',structured:explicit,density:explicit.poster_delivery.density});
  assert.match(p,/不加装饰/);
  assert.doesNotMatch(p,/延续到大块空底/);
});

test('an explicit all-current-assets turn restores missing selections without overriding local or historical bindings',()=>{
  const {apply}=require('../cloudfunctions/bf-api/intent-contract');
  const row={key:'title',role:'title',text:'设备协作'};
  const intent={userText:'产品图和标志都用上，做一张招贴',currentImageCount:6};
  const run=(rest={},request=intent)=>{
    const args={prompt:'设备协作招贴，真实工业场景',structured:{text:[row]},source_index:1,reference_roles:['产品图'],...rest};
    return JSON.parse(apply([{function:{name:'image_generate',arguments:JSON.stringify(args)}}],request)[0].function.arguments);
  };
  const full=run();
  assert.equal(full.source,'attached');
  assert.equal(full.source_index,undefined);
  assert.deepEqual(full.source_indexes,[1,2,3,4,5,6]);
  assert.equal(full.reference_roles[0],'产品图');
  assert.equal(run({source:'both'}).source,'both');
  assert.equal(run({library_refs:['existing']}).source_indexes,undefined);
  assert.equal(run({structured:{text:[row],preserve_assets:[{role:'logo'}]}}).source_indexes,undefined);
  assert.equal(run({}, {...intent,userText:'只用第一张，其他每张都不要用'}).source_indexes,undefined);
});

test('native poster planning leaves the legacy background asset brief optional',()=>{
  const {withImageToolSchema}=require('../cloudfunctions/bf-api/image-tool-schema');
  const tools=[{function:{name:'image_generate',parameters:{properties:{structured:{type:'object'}}}}}];
  const schema=options=>withImageToolSchema(tools,{commercial:true,...options})[0].function.parameters.properties.structured;
  assert.deepEqual(schema({posterPlanner:true}).required,['text']);
  assert.equal(schema({posterPlanner:true}).properties.design_plan,undefined);
  assert.ok(schema({posterPlanner:true}).properties.design_brief.properties.visual_map);
  assert.ok(schema({}).required.includes('artwork_prompt'));
});

test('text-free decoration does not route a titled poster to the legacy template',()=>{
  const { apply }=require('../cloudfunctions/bf-api/intent-contract');
  const args={prompt:'图1是产品图册，横版设备协作海报',source:'attached',source_indexes:[1,2],render_intent:'flat_artwork',structured:{text:[{key:'title',role:'title',text:'让设备运维有据可查'}]}};
  const user='用本轮附件做一张设备海报，保留标题与原字，右侧补接线特写以及设备记录的无字图形。';
  const [call]=apply([{function:{name:'image_generate',arguments:JSON.stringify(args)}}],{userText:user,currentImageCount:2});
  const next=JSON.parse(call.function.arguments);
  assert.equal(next.structured.poster_delivery.version,1);
  assert.doesNotMatch(next.prompt,/六张卡|价格大号/);
  assert.equal(poster.nativePoster(args,'帮我生成一张无字底图'),false);
});


const layout=require('../cloudfunctions/shared/image-layout-protocol');
test('only the explicit single Logo path can ask for placement without copy analysis',()=>{
 const input={image:'data:image/png;base64,AA==',references:[{index:1,role:'logo',aspect:4}],placement_only:true};
 const got=layout.requestOf(input);
 assert.match(layout.messagesOf(got)[0].content,/bbox_2d/);
 const placed=layout.responseOf({confidence:0.9,boxes_xyxy:[[0.25,0.25,0.75,0.5]]},got);
 assert.deepEqual(placed.occupied,[[0.25,0.25,0.5,0.25]]);
 assert.deepEqual(layout.responseOf(placed,got),placed);
 const official=layout.responseOf({objects:[{label:'标题',bbox_2d:[250,250,750,500]}]},got);
 assert.deepEqual(official.occupied,placed.occupied);
 assert.deepEqual(layout.responseOf(official,got),official);
 assert.throws(()=>layout.responseOf({objects:[{bbox_2d:[250,250,1200,500]}]},got),/IMAGE_LAYOUT_UNCERTAIN/);
 assert.throws(()=>layout.requestOf({...input,references:[{index:1,role:'ui',aspect:4}]}),/IMAGE_LAYOUT_INVALID/);
 assert.throws(()=>layout.responseOf({confidence:0.9,boxes_xyxy:[[0.99,0.99,0.1,0.1]]},got),/IMAGE_LAYOUT_UNCERTAIN/);
 assert.throws(()=>layout.responseOf({confidence:0.9,occupied:[[0.2,0.2,0.2,0.2]]},layout.requestOf({...input,placement_only:undefined})),/IMAGE_LAYOUT_UNCERTAIN/);
});


test('native posters dispatch the planner’s visual expressions with each confirmed copy line once', () => {
  const text = [
    { key: 'title', role: 'title', text: '设备运营协作' },
    { key: 'wires', role: 'label', text: '现场接入' },
    { key: 'inspection', role: 'label', text: '状态巡检' },
    { key: 'followup', role: 'body', text: '处理记录按项目交接' },
  ];
  const design_brief = {
    purpose: 'product_explainer', audience: '园区运营人员', goal: '介绍设备协作',
    information_density: 'dense', density_source: 'default', visual_approach: '暖色手绘插画',
    visual_map: [
      { form: '主视觉', text_keys: ['title'], expression: '远处厂房与近处设备形成前后层次' },
      { form: '场景群像', text_keys: ['wires', 'inspection', 'followup'], expression: '接线端子特写和现场巡检动作呼应，背景延续厂区环境' },
    ],
  };
  const user = '改成暖色手绘插画风，保留原文。';
  const structured = poster.mark({ text, design_brief }, user);
  const compile = spec => poster.compile({ visual: '园区设备协作', structured: spec, density: 'dense' });
  const prompt = compile(structured);
  assert.match(prompt, /最高优先级.*暖色手绘插画风/);
  assert.match(prompt, /接线端子特写和现场巡检动作/);
  assert.doesNotMatch(prompt, /分区标题：/);
  for (const row of text) assert.equal(prompt.split(JSON.stringify(row.text)).length, 2);
  const incomplete = { ...structured, design_brief: { ...design_brief, visual_map: design_brief.visual_map.slice(0, 1) } };
  const fallback = compile(incomplete);
  for (const row of text) assert.equal(fallback.split(JSON.stringify(row.text)).length, 2);
  assert.doesNotMatch(fallback, /远处厂房与近处设备/);
});

test('a mixed reference turn reads an explicitly numbered source, not its style sample', () => {
  const part = id=>({type:'image_url',image_url:{url:'data:image/png;base64,'+id}});
  const request='图二是原海报，图一只参考风格。把图二换成科技风，文字保留。';
  const messages=[{role:'user',content:[{type:'text',text:request},part('style'),part('original')]}];
  assert.ok(ref.restylesReference('换成科技风'));
  assert.ok(ref.shouldTranscribe(messages));
  assert.equal(ref.firstUserImage(messages),'data:image/png;base64,original');
  const actual = [{role:'user',content:[
    {type:'text',text:'【本次编辑前生成图预览】历史成图'},part('previous'),
    {type:'text',text:'【以下是用户本轮输入与上传附件，source_index仍按原附件顺序从1计数】'},
    ...messages[0].content
  ]}];
  assert.equal(ref.firstUserImage(actual),'data:image/png;base64,original');
  assert.equal(ref.sourceImageIndex('用这两张图做一张新的海报',2),null);
  assert.equal(ref.sourceImageIndex('图一是原图，图二是原图',2),null);
  const long='机电设备运维记录包括巡检计划、状态监控及故障处置情况，维护记录归档供现场人员复查。';
  assert.deepEqual(ref.linesOf(long),[long]);
});

test('a restyle sends the explicitly identified original before the style reference', () => {
  const {apply}=require('../cloudfunctions/bf-api/intent-contract');
  const userText='图二是原海报，图一只参考风格。把图二换成科技风，文字保留。';
  const lines=['原海报标题','必须保留的原文'];
  const original={function:{name:'image_generate',arguments:JSON.stringify({
    source:'attached',source_indexes:[1,2],reference_roles:['风格参考','素材图'],
    prompt:'按参考视觉设计',structured:{text:[{key:'title',role:'title',text:lines[0]}]}})}};
  const [call]=apply([original],{userText,currentImageCount:2,referenceLines:lines});
  const result=JSON.parse(call.function.arguments);
  assert.deepEqual(result.source_indexes,[2,1]);
  assert.deepEqual(result.reference_roles,['原海报','风格参考']);
  assert.ok(result.structured.poster_delivery.reference_redesign);
  assert.ok(result.structured.text.some(row=>row.text===lines[1]));
});

test('a colloquial user style survives reference compilation without the default palette', () => {
  const request='把这张图换成科技风的并保留原稿内容';
  const structured=poster.mark({text:[{key:'title',role:'title',text:'设备运营日报'}]},request,{referenceRedesign:true});
  assert.equal(structured.poster_delivery.user_direction,request);
  const prompt=poster.compile({visual:'截图上方用四列卡片',structured,density:'dense'});
  assert.ok(prompt.includes(request));
  assert.doesNotMatch(prompt,/四列卡片|高饱和/);
});

test('a numbered product set and its final logo survive catalog planning', () => {
  const {apply}=require('../cloudfunctions/bf-api/intent-contract');
  const userText='用这13张产品图和最后的Logo制作一张蓝橙工业风横版产品海报。只使用图中能确认的产品，全部放进去，保留编号对应。';
  const call={function:{name:'image_generate',arguments:JSON.stringify({source:'attached',source_indexes:[1,2],reference_roles:['图册1','图册2'],
    structured:{text:[{key:'t',role:'title',text:'产品海报'}]}})}};
  const run=text=>JSON.parse(apply([call],{userText:text,currentImageCount:14})[0].function.arguments);
  assert.equal(run(userText).use_entire_catalog,true);
  assert.equal(run(userText+'只用第二张').use_entire_catalog,false);
});

test('a smaller photo or larger square Logo is never assigned a role from its geometry',()=>{
 const photos=[{index:1,size:{w:200,h:180}},{index:2,size:{w:1400,h:1400}},{index:3,size:{w:900,h:1100}}];
 assert.equal(guard.classify(photos,'用这三张图一起制作海报').logo,null);
 assert.equal(guard.classify(photos,'把图二的Logo放在图三海报右下角').logo,photos[1]);
 assert.equal(guard.classify(photos,'图一是原海报，把它重绘并加上图二的Logo').poster,photos[0]);
 assert.equal(guard.classify([photos[1]],'在海报上加上这个Logo').logo,photos[1]);
});

test('isolated 5.5 poster uses authored wording, ordered references and opt-in defaults',async()=>{
 const {harness}=require('./reference-http-fixture.cjs'),vm=require('node:vm');
 const {resolve,apply}=require('../cloudfunctions/bf-api/intent-contract');
 const {sanitizeToolCall}=require('../cloudfunctions/shared/image-delivery');
 const refs=['https://fixture.myqcloud.com/cabinet.png','https://fixture.myqcloud.com/logo.png'];
 const rows=[{key:'t',role:'title',text:'园区储能联合运维'},{key:'p',role:'body',text:'额定容量 240 kWh'},
   ...['负荷核验','现场勘查','接入测试','交付培训','巡检维护','运营复盘'].map((text,i)=>({key:'s'+i,role:'body',text})),
   {key:'c',role:'contact',text:'400-620-7319'}];
 const protectedArgs={source:'attached',source_indexes:[1,2],structured:{text:rows,design_brief:{style_source:'default'}}};
 const protectedIntent={currentImageCount:2,compactPosterBrief:true,userText:'做一张海报，Logo 原样保留。'};
 assert.equal(poster.compactBriefFor(protectedArgs,protectedIntent,false),null);
 const h=await harness();
 vm.runInContext('RT.IMAGE_MODEL_FAST=RT.IMAGE_MODEL_PRO="doubao-seedream-5-5-261028"; RT.IMAGE_COMPOSITION_POLICY=JSON.stringify({compactPosterAccounts:["A"]})',h.context);
 for(const [name,detail,source,expectsDefault] of [
   ['normal','','default',true],
   ['explicit','用黑白银灰、低饱和，不加装饰。','user',false],
   ['explicit-fallback','做单色，不加装饰。','default',false],
   ['described-by-planner','给它一种肃静质感。','user',false]
 ]){
  const user='照刚才说的做一张海报，照片和 Logo 都用上。'+detail;
  const messages=[{role:'user',content:[{type:'text',text:user},
    ...refs.map(url=>({type:'image_url',image_url:{url}}))]}];
  const raw={function:{name:'image_generate',arguments:JSON.stringify({prompt:'旧规划强制紫色霓虹，仅用来验证拦截。',source:'attached',
   source_indexes:[1,2],reference_roles:['设备实拍参考','Logo原件'],structured:{text:rows,design_brief:{style_source:source},
   poster_delivery:{compact_brief:{request:'模型捏造的用户原话'}}}})}};
  const cleaned=sanitizeToolCall(raw,user);
  assert.equal(JSON.parse(cleaned.function.arguments).structured.poster_delivery.compact_brief,undefined);
  const intent={...resolve({messages}),compactPosterBrief:true};
  const [finalized]=apply([cleaned],intent);
  const args=JSON.parse(finalized.function.arguments);
  const payload={requestId:name,prompt:args.prompt,structured:args.structured,reference_roles:args.reference_roles,
   image:refs,task_kind:'reference',size:'1536x2048'};
  const response=await h.request('/image',payload);
  assert.equal(response.status,200,JSON.stringify(response.body));
  const actual=h.calls.at(-1);
  assert.deepEqual(actual.image,refs);
  assert.ok(actual.prompt.startsWith('用户原话：'+user+'\n'));
  assert.match(actual.prompt,/图1=设备实拍参考.*图2=Logo原件/);
  assert.equal(actual.prompt.includes('明亮高饱和色'),expectsDefault);
  assert.doesNotMatch(actual.prompt,/旧规划强制紫色|模型捏造|必须重新设计整张/);
  for(const {text} of rows) assert.equal(actual.prompt.split('“'+text+'”').length,2);
  const replay=await h.request('/image',payload);
  assert.equal(replay.status,200);
  assert.equal(replay.body.cost,0);
  assert.equal(h.calls.at(-1),actual);
  const ordinary=await h.request('/image',{...payload,requestId:name+'-off'},'OTHER');
  assert.equal(ordinary.status,200);
  assert.doesNotMatch(h.calls.at(-1).prompt,/^用户原话：/);
 }
});
