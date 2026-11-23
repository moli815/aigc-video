"use strict";
const test=require('node:test'),assert=require('node:assert/strict'),mod=require('../cloudfunctions/bf-image/native-copy-refinement');
const fixture=require('./fixtures/native-text-55-20261116.json'),clone=x=>JSON.parse(JSON.stringify(x));
const items=[{key:'inspection',role:'body',text:'按项目安排巡检路线和检查项，记录检查时间、现场照片与处理说明，管理人员可查看完成情况与待跟进项。'},
{key:'archive',role:'body',text:'设备手册、巡检照片、工单说明和验收记录按项目整理，交接时能找到上下文，便于查询与复盘。'}];
test('fully bold measured body lines preserve emphasis without making surrounding body bold',()=>{
 const f=clone(fixture);for(const r of f.rows)for(const line of r.text_recognition.lines)line.runs.forEach(s=>s.style.bold=false);f.rows[0].text_recognition.lines[0].runs.forEach(r=>r.style.bold=true);
 const result=mod.planOf({...f,items,preserveNativeSize:true});assert.equal(result.plan.blocks[0].weight,700);assert.ok(result.plan.blocks.slice(1).every(b=>b.weight===400));
});
test('official text lines bind to confirmed original copy rather than trusting OCR substitutions',()=>{
 const p=mod.planOf({...fixture,items});assert.deepEqual(p.matched.map(m=>m.ocrSubstitutions),[0,2]);
 for(const item of items){const actual=p.lines.filter(l=>l.key.startsWith(item.key+':')).map(l=>l.text).join('');assert.equal(actual,item.text);}
 assert.ok(p.plan.blocks.every(b=>b.weight===400&&b.fontSize>=22));assert.ok(p.plan.protected.some(b=>b[2]*fixture.width<12));
 assert.ok(mod.planOf({...fixture,items,bodyWeight:700}).plan.blocks.every(b=>b.weight===700));
});
test('ambiguous, unavailable and mismatched copies are rejected rather than guessed',()=>{
 assert.throws(()=>mod.planOf({...fixture,rows:[...fixture.rows,{...fixture.rows[0],index:3}],items}),/AMBIGUOUS_OR_MISSING/);
 assert.throws(()=>mod.planOf({...fixture,rows:fixture.rows.slice(0,1),items}),/AMBIGUOUS_OR_MISSING/);
 assert.throws(()=>mod.planOf({...fixture,items:[{...items[0],text:'不能用完全不相干的内容匹配另一个用户的文案。'}]}),/AMBIGUOUS_OR_MISSING/);
 assert.throws(()=>mod.planOf({...fixture,items:[{...items[0],role:'invented_role'}]}),/CONTRACT/);
});
test('wrong geometry, decorative or missing styles and resource limits fail before drawing',()=>{
 const f=clone(fixture);f.rows[0].text_recognition.lines[0].bounding_box.absolute[0]=-1;
 assert.throws(()=>mod.planOf({...f,items}),/GEOMETRY/);
 const bad=clone(fixture);bad.rows[0].text_recognition.lines[0].runs[0].style.foreground_color='javascript:bad';
 assert.throws(()=>mod.planOf({...bad,items}),/STYLES/);
 assert.throws(()=>mod.planOf({...fixture,items,width:8192,height:8192}),/CONTRACT/);
 assert.throws(()=>mod.planOf({...fixture,items:[{...items[0],text:'字'.repeat(1001)}]}),/CONTRACT/);
});
test('bounded matching cannot silently accept a distant transcription',()=>{
 assert.equal(mod.distanceAtMost('设备手册','投备手册',2),1);
 assert.equal(mod.distanceAtMost('交接时能找到上下文','交接时能技到上下文',2),1);
 assert.ok(mod.distanceAtMost('设备手册','全部乱写',2)>2);
});
test('nearby heading and number badge cannot split an actually present body paragraph',()=>{
 const lines=[
  ['1',[353,1089,368,1119]],['设备台账：',[383,1091,509,1117]],
  ['分散设备按位置、类型与负责人登记到',[352,1135,634,1152]],
  ['同一份台账，现场人员能查到设备资料、',[352,1161,646,1178]],
  ['维护记录和责任归属，减少资料散落和同',[352,1187,641,1204]],
  ['一设备重复登记。',[352,1213,482,1230]]
 ].map(([text,b])=>({bounding_box:{absolute:b},runs:[{text,style:{foreground_color:'#162F2A'}}]}));
 const text=lines.slice(2).map(l=>l.runs[0].text).join(''),rows=[{index:1,bounding_box:{absolute:[0,0,1344,3128]},text_recognition:{lines}}];
 assert.equal(mod.hasCandidate({rows,text,width:1344,height:3128}),true);
 const matches=mod.matchFieldsOf({rows,items:[{key:'body',role:'body',text}],width:1344,height:3128});assert.equal(matches[0].lineIds.length,4);assert.equal(matches[0].d,0);
});

test('regular labels, subtitles, contact and footer are corrected with body rather than silently omitted',()=>{
 for(const role of ['subtitle','label','contact','footer']){
  const p=mod.planOf({...fixture,items:items.map(item=>({...item,role}))});
  assert.equal(p.matched.length,items.length);
  assert.ok(p.lines.every(line=>line.role===role));
  assert.ok(p.plan.blocks.every(block=>block.weight===(['label','subtitle'].includes(role)?700:400)));
  assert.equal(p.lines.map(l=>l.text).join(''),items.map(t=>t.text).join(''));
 }
});

test('a title keeps measured scale and hierarchy while using canonical glyphs',()=>{
 const f=clone(fixture);f.rows=f.rows.slice(0,1);const line=f.rows[0].text_recognition.lines[0];
 f.rows[0].text_recognition.lines=[line];f.rows[0].bounding_box.absolute=[0,0,f.width,f.height];line.runs[0].text='设备协作平台';
 line.bounding_box.absolute=[100,100,900,220];
 const p=mod.planOf({...f,items:[{key:'title',role:'title',text:'设备协作平台'}],preserveNativeSize:true});
 assert.equal(p.lines[0].text,'设备协作平台');assert.equal(p.plan.blocks[0].weight,700);assert.equal(p.plan.blocks[0].fontSize,90);
});

test('one missing or duplicated recognised character is repaired without dropping canonical copy',()=>{
 for(const change of [text=>text.slice(1),text=>text[0]+text]){
  const f=clone(fixture);f.rows[0].text_recognition.lines[0].runs[0].text=change(f.rows[0].text_recognition.lines[0].runs[0].text);
  const p=mod.planOf({...f,items});assert.equal(p.lines.filter(l=>l.key.startsWith('inspection:')).map(l=>l.text).join(''),items[0].text);
  assert.ok(p.matched[0].ocrSubstitutions<=3);
 }
 assert.deepEqual(mod.canonicalLineCounts('甲乙丙丁戊',['甲乙','丁戊'],1),[3,2]);
 assert.throws(()=>mod.canonicalLineCounts('甲乙丙丁戊',['完全','不相干'],1),/COPY_COVERAGE/);
});

test('a unique four-character heading can repair one Chinese recognition error, but not a number or brand',()=>{
 const f=clone(fixture);f.rows=f.rows.slice(0,1);f.rows[0].bounding_box.absolute=[0,0,f.width,f.height];
 f.rows[0].text_recognition.lines=f.rows[0].text_recognition.lines.slice(0,1);
 const line=f.rows[0].text_recognition.lines[0];line.runs[0].text='资料总档';
 assert.equal(mod.planOf({...f,items:[{key:'archive',role:'label',text:'资料归档'}]}).lines[0].text,'资料归档');
 for(const [observed,confirmed]of [['步骤02资料归档','步骤03资料归档'],['DHARMB设备平台','DHARMA设备平台'],['资料归档,便于查询','资料归档:便于查询']]){
  line.runs[0].text=observed;assert.throws(()=>mod.planOf({...f,items:[{key:'critical',role:'body',text:confirmed}]}),/AMBIGUOUS_OR_MISSING/);
 }
});

test('full-copy delivery rejects even a distant extra or duplicated numbered line; partial edit preserves other copy',()=>{
 const f=clone(fixture),extra=clone(f.rows[0].text_recognition.lines[0]);extra.runs[0].text='02 重复的步骤不允许悄悄保留';extra.bounding_box.absolute=[100,50,900,90];
 f.rows[0].bounding_box.absolute=[0,0,f.width,f.height];f.rows[0].text_recognition.lines.unshift(extra);
 assert.doesNotThrow(()=>mod.planOf({...f,items}));
 assert.throws(()=>mod.planOf({...f,items,requireFullCopy:true}),/NATIVE_TEXT_EXTRA_COPY/);
 assert.doesNotThrow(()=>mod.planOf({...fixture,items,requireFullCopy:true}));
});

test('missing colon between a spatial heading and paragraph is formatting, not an OCR deletion to erase as one box',()=>{
 const f=clone(fixture);f.rows=f.rows.slice(0,1);f.rows[0].bounding_box.absolute=[0,0,f.width,f.height];
 const first=f.rows[0].text_recognition.lines[0],heading=clone(first),y=first.bounding_box.absolute[1];
 heading.runs=[{text:'巡检任务',style:{foreground_color:'#141414'}}];heading.bounding_box.absolute=[first.bounding_box.absolute[0],y-65,first.bounding_box.absolute[0]+180,y-25];
 f.rows[0].text_recognition.lines.unshift(heading);
 const item={key:'cap',role:'body',text:'巡检任务：'+items[0].text};assert.equal(mod.hasCandidate({...f,text:item.text}),false);
 const targets=require('../cloudfunctions/bf-image/native-copy-transcription').targets({...f,items:[item],allowFormatting:true});
 assert.equal(targets.items.length,2);assert.equal(targets.formats[0].separator,'colon_as_line_break');
});
test('line spacing is measured, cannot become negative tracking or crop below permitted bounds',()=>{
 const surface=require('../cloudfunctions/bf-image/surface-typography'),p=mod.planOf({...fixture,items});
 for(const mutate of [b=>b.lineHeight=1,b=>b.letterSpacing=-1,b=>b.lineHeight=2,b=>b.letterSpacing=20]){
  const plan=clone(p.plan);mutate(plan.blocks[0]);assert.throws(()=>surface.validate(plan,p.lines,fixture.width,fixture.height),/TYPE_INVALID/);
 }
});

function combined(){const f=clone(fixture);f.rows=[{index:1,bounding_box:{absolute:[0,0,f.width,f.height]},text_recognition:{lines:f.rows.flatMap(r=>r.text_recognition.lines)}}];return f;}
test('several paragraphs may share one native text layer without losing or reusing lines',()=>{
 const p=mod.planOf({...combined(),items});assert.equal(p.matched.length,2);assert.deepEqual(p.matched.map(x=>x.layer),[1,1]);
 assert.equal(new Set(p.matched.flatMap(m=>m.lineIds)).size,8);
 assert.deepEqual(p.lines.map(l=>l.text).join(''),items.map(i=>i.text).join(''));
 const f=combined();f.rows[0].text_recognition.lines.push(clone(f.rows[0].text_recognition.lines[0]));
 assert.throws(()=>mod.planOf({...f,items}),/AMBIGUOUS_OR_MISSING/);
});
test('spatial grouping handles interleaved columns instead of concatenating OCR reading order',()=>{
 const f=combined(),lines=f.rows[0].text_recognition.lines;
 const y0=lines[0].bounding_box.absolute[1],y1=lines[4].bounding_box.absolute[1];
 for(const l of lines.slice(0,4)){l.bounding_box.absolute[0]-=400;l.bounding_box.absolute[2]-=400;}
 for(const l of lines.slice(4)){l.bounding_box.absolute[1]-=y1-y0;l.bounding_box.absolute[3]-=y1-y0;l.bounding_box.absolute[0]+=350;l.bounding_box.absolute[2]+=350;}
 f.rows[0].text_recognition.lines=[lines[0],lines[4],lines[1],lines[5],lines[2],lines[6],lines[3],lines[7]];
 const p=mod.planOf({...f,items});assert.equal(p.matched.length,2);assert.equal(p.surfaces.length,2);
});
test('a heading sharing the layer stays outside the approved paragraph region; incomplete fields reject all',()=>{
 const f=combined(),l=clone(f.rows[0].text_recognition.lines[0]);l.runs[0].text='巡检任务';l.bounding_box.absolute[1]-=75;l.bounding_box.absolute[3]-=75;
 f.rows[0].text_recognition.lines.unshift(l);const p=mod.planOf({...f,items});assert.ok(p.surfaces[0][1]>l.bounding_box.absolute[3]);
 assert.throws(()=>mod.planOf({...f,items:[...items,{key:'missing',role:'body',text:'这是原件里没有的一段必须保留的真实文案。'}]}),/AMBIGUOUS_OR_MISSING/);
});
test('wide canvas readable body size is based on short edge rather than inflating to forty pixels',()=>{
 const f=clone(fixture);f.width=3136;f.height=1344;
 for(const r of f.rows){r.bounding_box.absolute=[0,0,3136,1344];for(const l of r.text_recognition.lines){l.bounding_box.absolute[1]-=600;l.bounding_box.absolute[3]-=600;}}
 assert.ok(mod.planOf({...f,items}).plan.blocks.every(b=>b.fontSize===22));
});
test('canonical English spaces survive reflow and an unselected heading cannot be erased',()=>{
 const f=clone(fixture);f.rows=f.rows.slice(0,1);f.rows[0].text_recognition.lines=f.rows[0].text_recognition.lines.slice(0,1);
 const text='设备 A 模块与 B 模块统一接入平台';f.rows[0].text_recognition.lines[0].runs[0].text=text;
 const p=mod.planOf({...f,items:[{key:'body',role:'body',text}]});assert.equal(p.lines[0].text,text);
 const hidden=clone(f.rows[0]);hidden.index=2;hidden.text_recognition.lines[0].runs[0].text='原位置的另一个栏目';f.rows.push(hidden);
 assert.throws(()=>mod.planOf({...f,items:[{key:'body',role:'body',text}]}),/UNSELECTED_OVERLAP/);
});
function raster(bg){const data=Buffer.alloc(120*80*4);for(let i=0;i<data.length;i+=4){for(let k=0;k<3;k++)data[i+k]=bg[k];data[i+3]=255;}return{width:120,height:80,data};}
function paint(r,color){for(let y=20;y<30;y++)for(let x=20;x<60;x++){const i=(y*r.width+x)*4;for(let k=0;k<3;k++)r.data[i+k]=color[k];}return r;}
test('clean-base checks support light and dark surfaces and reject remaining glyphs, photo texture and shifted boundaries',()=>{
 for(const [bg,fg,hex]of [[[245,244,242],[18,26,36],'#121A24'],[[15,30,45],[245,245,245],'#F5F5F5']]){
  const original=paint(raster(bg),fg),base=raster(bg),box=[5,5,110,70];assert.ok(mod.auditRegion(original,base,box,[hex]).oldInkRatio>.008);
  assert.throws(()=>mod.auditRegion(original,original,box,[hex]),/BASE_NOT_CLEAN/);
  const bad=raster(bg);for(let y=10;y<60;y++)for(let x=10;x<100;x++){const i=(y*bad.width+x)*4;bad.data[i]=(x%2)?255:0;}
  assert.throws(()=>mod.auditRegion(original,bad,box,[hex]),/BASE_NOT_CLEAN/);
  assert.throws(()=>mod.auditRegion(original,raster([120,120,120]),box,[hex]),/BASE_NOT_CLEAN|LOW_CONTRAST/);
 }
 assert.throws(()=>mod.auditRegion(paint(raster([245,245,245]),[220,220,220]),raster([245,245,245]),[5,5,110,70],['#DCDCDC']),/LOW_CONTRAST/);
});
