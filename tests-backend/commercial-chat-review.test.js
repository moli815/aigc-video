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

test("SSE emits no prose before reviewed completion and close aborts upstream", () => {
  const req = new EventEmitter();
  const writes = [];
  const res = { writeHead: () => {}, write: value => writes.push(value), end: () => {} };
  let aborts = 0;
  const session = review.createReviewedSseSession(res, req, { onClose: () => { aborts++; } });
  assert.equal(writes.some(value => value.includes("审定正文")), false);
  session.complete(completion("审定正文"), "masked");
  const output = writes.join("");
  assert.match(output, /审定正文/);
  assert.match(output, /data: \[DONE\]/);
  session.fail({ error: "ignored after completion" });
  req.emit("close");
  assert.equal(aborts, 1);
  assert.equal(session.aborted, true);
});
