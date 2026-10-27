const test=require('node:test'),assert=require('node:assert/strict');
const {chatRejection}=require('../cloudfunctions/bf-api/domains/chat-diagnostics');
test('chat rejection diagnostics classify the boundary without retaining user data',()=>{
 const result=chatRejection(400,JSON.stringify({error:{code:'InvalidParameter',param:'messages[0].content',message:'invalid image; customer prompt and sk-secret must not be logged'}}),{model:'example',messages:[{content:[{type:'image_url',image_url:{url:'data:image/jpeg;base64,private'}}]}],tools:[{}]});
 assert.equal(result.category,'image_invalid');assert.equal(result.imageCount,1);assert.equal(result.upstreamStatus,400);
 assert.ok(!JSON.stringify(result).includes('customer'));assert.ok(!JSON.stringify(result).includes('base64'));assert.ok(!JSON.stringify(result).includes('sk-secret'));
});
test('upstream code and parameter cannot smuggle free text into logs',()=>{
 const result=chatRejection(400,JSON.stringify({error:{code:'customer email: private@example.com',param:'secret bearer value',message:'max_tokens exceeds limit'}}),{});
 assert.equal(result.upstreamCode,'');assert.equal(result.parameter,'');assert.equal(result.category,'token_limit');
});
