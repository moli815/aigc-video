"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const { EventEmitter } = require("node:events");
const review = require("../cloudfunctions/bf-api/commercial-chat-review");

const U = text => ({ role: "user", content: text });
const completion = text => ({ choices: [{ index: 0, message: { role: "assistant", content: text }, finish_reason: "stop" }], usage: { prompt_tokens: 10, completion_tokens: 5 } });
const reviewed = answer => completion(JSON.stringify({ answer, unsupported_claims: [] }));

test("selector is opt-in and bypasses JSON, artifacts, utility and unrelated chat", () => {
  const policy = { enabled: true, audience: "all" };
  assert.equal(review.reviewPolicy(undefined).enabled, false);
  const copy = [U("我们参加了展会，写一段纯口播，不要分析")];
  assert.ok(review.selectCommercialCopyRequest(copy, { stream: true }, policy, "a1"));
  assert.equal(review.selectCommercialCopyRequest(copy, { stream: true }, { enabled: false }, "a1"), null);
  assert.equal(review.isCommercialCopyTask([U("只返回JSON：公司名")], { stream: true }), false);
  assert.equal(review.isCommercialCopyTask([U("做一张展会海报")], { stream: true }), false);
  assert.equal(review.isCommercialCopyTask([U("毛利怎么算？一句话")], { stream: true }), false);
  assert.equal(review.isCommercialCopyTask([U("写参展口播"), U("再口语一点，别编客户故事")], { stream: true }), true);
});

test("grounding uses user evidence, excludes assistant claims and preserves image evidence separately", () => {
  const messages = [U("公司业务是设备联网"), { role: "assistant", content: "展会三天，客户排队" },
    { role: "user", content: [{ type: "text", text: "继续改口播" }, { type: "image_url", image_url: { url: "data:image/jpeg;base64,PRIVATE" } }] }];
  const records = review.groundingRecords(messages);
  assert.match(records.map(x => x.text).join("\n"), /设备联网/);
  assert.doesNotMatch(records.map(x => x.text).join("\n"), /展会三天/);
  assert.equal(review.groundingImages(messages).length, 1);
  const built = review.buildReviewMessages({ messages, task: "改口播", draft: "正文" });
  assert.equal(built.images.length, 1);
  assert.equal(built.reviewMessages[1].content[1].type, "image_url");
});

test("independent review returns only final prose and preserves completion contract", async () => {
  const messages = [U("写一段设备联网业务口播")];
  let calls = 0;
  const result = await review.reviewGroundedCompletion({ completion: completion("初稿"), messages,
    request: async () => { calls++; return reviewed("审定正文"); } });
  assert.equal(calls, 1);
  assert.equal(result.answer, "审定正文");
  assert.equal(result.completion.choices[0].message.content, "审定正文");
  assert.equal(result.completion.usage.prompt_tokens, 10);
});

test("text-only draft cannot prove its own invented contact", async () => {
  await assert.rejects(() => review.reviewGroundedCompletion({
    completion: completion("联系电话13812345678"), messages: [U("写公司口播")],
    request: async () => reviewed("联系电话13812345678"),
  }), error => error.code === "GROUNDED_REVIEW_NEW_CONTACT");
  await assert.rejects(() => review.reviewGroundedCompletion({
    completion: completion("初稿"), messages: [U("写公司口播")],
    request: async () => ({ choices: [{ message: { content: "{}" }, finish_reason: "stop" }] }),
  }), error => error.code === "GROUNDED_REVIEW_INVALID_CONTRACT");
});

test("SSE finishes once; a normal POST close is not a disconnected consumer", () => {
  const req = new EventEmitter();
  const writes = [];
  const res = Object.assign(new EventEmitter(), { writableEnded:false, writeHead: () => {}, write: value => writes.push(value), end() {this.writableEnded=true;} });
  let aborts = 0;
  const session = review.createReviewedSseSession(res, req, { onClose: () => { aborts++; } });
  assert.equal(writes.some(value => value.includes("审定正文")), false);
  req.emit("close");
  assert.equal(session.aborted,false);
  session.complete(completion("审定正文"), "masked");
  const output = writes.join("");
  assert.match(output, /审定正文/);
  assert.match(output, /data: \[DONE\]/);
  const count=writes.length;
  session.fail({ error: "ignored after completion" });session.complete(completion("重复正文"),"masked");
  res.emit("close");req.emit("aborted");
  assert.equal(writes.length,count);assert.equal(aborts,0);assert.equal(session.aborted,false);
});

test("a disconnected SSE response cancels its review once and never releases an unfinished draft",()=>{
 const req=new EventEmitter(),writes=[];
 const res=Object.assign(new EventEmitter(),{writableEnded:false,writeHead(){},write(v){writes.push(v);},end(){}});
 let count=0;const session=review.createReviewedSseSession(res,req,{onClose(){count++;}});
 res.emit("close");req.emit("aborted");session.complete(completion("不应展示"),"masked");session.fail({error:"不应展示"});
 assert.equal(count,1);assert.equal(session.aborted,true);assert.ok(!writes.join("").includes("不应展示"));
});
test("business advice review is explicit opt-in and excludes machine formats, artifacts and safety",()=>{
 const messages=[U("预算1000元，明天参展，是否值得重做宣传物料？")];
 assert.equal(review.selectCommercialCopyRequest(messages,{max_tokens:1000},{enabled:true,audience:"all"},"a"),null);
 const policy={enabled:true,audience:"all",includeBusinessAdvice:true};
 assert.ok(review.selectCommercialCopyRequest(messages,{max_tokens:1000},policy,"a"));
 for(const text of ["制作一张展会预算海报","完整写展会方案报告","同事触电怎么处理"] )assert.equal(review.isBusinessAdviceTask([U(text)],{}),false);
 assert.equal(review.isBusinessAdviceTask(messages,{tier:"utility"}),false);
 assert.equal(review.isBusinessAdviceTask(messages,{response_format:{type:"json_object"}}),false);
});
test("reviewed output never includes unreviewed generator reasoning",async()=>{
 const draft=completion("初稿");Object.assign(draft.choices[0].message,{reasoning_content:"未审的内部文本",reasoning_details:["未审"]});
 const result=await review.reviewGroundedCompletion({completion:draft,messages:[U("写一段口播")],request:async()=>reviewed("审定正文")});
 assert.equal(result.completion.choices[0].message.reasoning_content,undefined);
 assert.equal(result.completion.choices[0].message.reasoning_details,undefined);
});
test("local rewrite selector covers return/give and replacement wording, while code edits bypass it",()=>{
 for(const text of ["原文：地址A馆。第二句改为地址B馆，只返回改后的第二句。","原稿三段，第二段换成简介，仅给改好的第二段。","原文：甲。只把第二句改成乙，回复中只给这一句。"]){
  assert.equal(review.isCommercialCopyTask([U(text)],{stream:true}),true);
 }
 assert.equal(review.isCommercialCopyTask([U("原文JavaScript函数，只改第二行代码，仅返回这一行。")],{stream:true}),false);
});
test("bounded review does not cap explicit long-form writing",()=>{
 const policy={enabled:true,audience:"all",includeBusinessAdvice:true};
 for(const text of ["写一篇2000字的公众号文案。","撰写一篇长文介绍公司。","写三千字参展口播。","写5页宣传文案。"]){
  assert.equal(review.selectCommercialCopyRequest([U(text)],{max_tokens:8000},policy,"a"),null);
 }
 assert.ok(review.selectCommercialCopyRequest([U("写一段100字口播。")],{max_tokens:8000},policy,"a"));
});
