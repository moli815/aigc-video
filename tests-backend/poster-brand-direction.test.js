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
  assert.ok(schema({}).required.includes('artwork_prompt'));
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

