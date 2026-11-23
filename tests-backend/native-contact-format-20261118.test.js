'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),{targets}=require('../cloudfunctions/bf-image/native-copy-transcription');
const rows=[{index:1,bounding_box:{absolute:[0,0,1000,300]},text_recognition:{lines:[{bounding_box:{absolute:[20,20,150,50]},runs:[{text:'合作热线'}]},{bounding_box:{absolute:[400,140,900,200]},runs:[{text:'020-82634719'}]}]}}];
test('a confirmed contact can be split into its existing measured label and phone without changing any digit',()=>{
 const items=[{key:'contact',role:'contact',text:'合作热线 020-82634719'}],r=targets({items,rows,width:1000,height:300,allowFormatting:true});
 assert.deepEqual(r.items.map(x=>x.text),['合作热线','020-82634719']);assert.equal(r.formats[0].digitsPreserved,true);
 assert.throws(()=>targets({items:[{...items[0],text:'合作热线 020-82634718'}],rows,width:1000,height:300,allowFormatting:true}));
 assert.throws(()=>targets({items,rows,width:1000,height:300,allowFormatting:false}));
});
