"use strict";
const test=require('node:test'),assert=require('node:assert/strict');
const {compileQwenImage:compile,resolveQwenSize:size,qwenImageCost:cost,parseQwenImageResponse:parse}=require('../cloudfunctions/shared/image-provider-qwen');
test('Qwen compiler preserves all copy and reference order, removes Ark/business fields',()=>{
 const input={prompt:'完整原文'.repeat(1000),size:'2816x1584',image:['a','b','c'],task_kind:'edit',structured:{text:[]},optimize_prompt_options:{mode:'fast'}};
 const p=compile(input);assert.equal(p.prompt,input.prompt);assert.deepEqual(p.image,input.image);assert.equal(p.n,1);assert.equal(p.prompt_extend_mode,'direct');assert.ok(!('structured'in p));assert.ok(!('task_kind'in p));assert.ok(!('optimize_prompt_options'in p));assert.ok(!('stream'in p));
 const [w,h]=p.size.split('x').map(Number);assert.ok(w*h<=4194304);assert.ok(Math.abs(w/h-16/9)<.01);
});
test('Qwen unsupported four-reference, layer, extreme-ratio inputs fail before upstream',()=>{
 for(const [extra,code]of [[{image:['a','b','c','d']},'QWEN_REFERENCE_LIMIT'],[{layer_decomposition:true},'QWEN_LAYERS_UNSUPPORTED'],[{size:'3456x384'},'QWEN_RATIO_UNSUPPORTED']])assert.throws(()=>compile({prompt:'x',size:'1024x1024',...extra}),{code});
});
test('Qwen no image omits field; exact size and explicit prompt rewrite opt-out preserved',()=>{
 const p=compile({prompt:'海报',size:'1536x1536'},{promptExtend:false,seed:7319});assert.equal(p.image,undefined);assert.equal(p.size,'1536x1536');assert.equal(p.prompt_extend,false);assert.equal(p.seed,7319);
 assert.throws(()=>size('2K'),{code:'QWEN_EXPLICIT_SIZE_REQUIRED'});assert.throws(()=>compile({prompt:'',size:'1024x1024'}));
});
test('Qwen pricing includes EVERY input and official 2250000 pixel tier boundary',()=>{
 assert.equal(cost({model:'qwen-image-3.0-pro',size:'1500x1500'}),.25);assert.equal(cost({model:'qwen-image-3.0-pro',size:'1501x1500',image:['a','b','c']}),.56);
 assert.equal(cost({model:'qwen-image-3.0',size:'2048x2048',image:'a'}),.20);
 assert.equal(cost({model:'qwen-image-3.0-pro',size:'1024x1024'},{output_width:2048,output_height:2048,input_image_count:2,output_image_count:1}),.54);
});
test('Qwen result validates one HTTPS result, no silent first-result or broken-body success',()=>{
 assert.equal(parse({data:[{url:'https://example.com/a.png'}]}).url,'https://example.com/a.png');
 for(const x of [{error:{code:'Quota'}},{data:[]},{data:[{url:'http://example.com/x'}]},{data:[{url:'https://example.com/a'},{url:'https://example.com/b'}]}])assert.throws(()=>parse(x));
});
test('Native DashScope compiler preserves reference order, exact copy and correct size separator',()=>{
 const p=compile({prompt:'不可改的中文和电话',size:'1536x2048',image:['base','person','logo']},{protocol:'dashscope'});
 assert.deepEqual(p.input.messages[0].content,[{image:'base'},{image:'person'},{image:'logo'},{text:'不可改的中文和电话'}]);assert.equal(p.parameters.size,'1536*2048');assert.equal(p.parameters.n,1);assert.equal(cost(p),.56);
 assert.equal(parse({output:{choices:[{message:{content:[{image:'https://example.com/a.png'}]}}]}}).url,'https://example.com/a.png');
});
test('No-text negative prompt is explicit and never removes required native poster copy',()=>{
 const input={prompt:'必须保留完整标题',size:'1024x1024'};
 assert.equal(compile(input).negative_prompt,undefined);
 const p=compile(input,{protocol:'dashscope',noText:true,promptExtend:false});assert.match(p.parameters.negative_prompt,/文字/);assert.equal(p.parameters.prompt_extend,false);assert.equal(p.input.messages[0].content[0].text,input.prompt);
});
