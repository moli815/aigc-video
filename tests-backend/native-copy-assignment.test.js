"use strict";
const test=require('node:test'),assert=require('node:assert/strict'),mod=require('../cloudfunctions/bf-image/native-copy-assignment');
const items=[{key:'a',role:'body',text:'确认文案甲'},{key:'b',role:'body',text:'确认文案乙'}],rows=[{index:1,text_recognition:{lines:['观察甲','观察乙'].map((text,i)=>({runs:[{text}],bounding_box:{absolute:[10,10+i*30,100,30+i*30]}}))}}];
const valid=()=>({assignments:[{key:'a',lines:['1:0']}],missing:[{key:'b',reason:'not_present'}]});
test('semantic selectors cannot create a missing word, line ID, key, geometry or repeated assignment',()=>{
 const r=mod.validate(valid(),items,rows);assert.equal(r.complete,false);assert.equal(r.requiresPixelAndSpatialReview,true);assert.deepEqual(r.unassignedLines,['1:1']);
 for(const mutate of [r=>r.assignments[0].lines=['9:9'],r=>r.assignments[0].box=[0,0,1,1],r=>r.missing[0].key='a',r=>r.assignments.push({key:'b',lines:['1:0']}),r=>r.assignments[0].key='foreign',r=>r.assignments[0].text='模型编的文案']){const r=valid();mutate(r);assert.throws(()=>mod.validate(r,items,rows),/ASSIGNMENT_INVALID/);}
});
test('a complete assignment remains a mapping hypothesis, not pixel or font approval',()=>{
 const raw={assignments:[{key:'a',lines:['1:0']},{key:'b',lines:['1:1']}],missing:[]},r=mod.validate(raw,items,rows);assert.equal(r.complete,true);assert.equal(r.requiresPixelAndSpatialReview,true);assert.deepEqual(items.map(i=>i.text),['确认文案甲','确认文案乙']);
});
