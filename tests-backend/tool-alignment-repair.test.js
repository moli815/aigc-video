"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const { validateValue } = require("../cloudfunctions/bf-api/settings-schema");
const { arbitrateDelivery, enabledFor, parsePolicy, MARKER, ARBITRATION_BLOCK } = require("../cloudfunctions/bf-api/expert-delivery-arbitration");
const spec = { type: "json", label: "test" };

test("JSON null and primitive settings return field errors without throwing", () => {
  for (const key of ["CHAT_DELIVERY_ARBITRATION", "CAPABILITY_OVERRIDES", "CHAT_GROUNDED_REVIEW", "CHAT_STYLE_POLICY"]) {
    for (const raw of ["null", "[]", '"text"', "false", "17"]) {
      assert.equal(validateValue(key, raw, spec).ok, false, key + ":" + raw);
    }
    assert.equal(validateValue(key, "{}", spec).ok, true);
  }
});

test("arbitration rejects bad scopes, field types, unknown fields and malformed account lists at both boundaries", () => {
  for (const bad of [null, [], {enabled:null}, {enabled:true,audience:"account"}, {enabled:true,audience:null},
    {enabled:true,accountIds:null}, {enabled:true,accountIds:[1]}, {enabled:true,accountIds:[""]},
    {enabled:true,accountIds:[" u1"]}, {enabled:true,accountIds:Array(101).fill("u1")}, {enabled:true,extra:true}]) {
    assert.equal(validateValue("CHAT_DELIVERY_ARBITRATION", JSON.stringify(bad), spec).ok, false);
    for (const raw of [bad, JSON.stringify(bad)]) assert.equal(enabledFor(raw, "u2"), false);
  }
});

test("omitted audience never expands an account canary to other accounts", () => {
  assert.equal(enabledFor({enabled:true,accountIds:["u1"]}, "u1"), true);
  assert.equal(enabledFor({enabled:true,accountIds:["u1"]}, "u2"), false);
  assert.equal(enabledFor({enabled:true,accountIds:[]}, "u1"), false);
  assert.equal(enabledFor({enabled:true}, "u2"), true);
  assert.equal(enabledFor({enabled:true,audience:"all"}, "u2"), true);
  const ids = ["u1"], policy = parsePolicy({enabled:true,accountIds:ids});
  policy.accountIds.push("u2");
  assert.deepEqual(ids, ["u1"], "normalization must not mutate the original configuration");
});

test("quoted marker or full rule in untrusted message roles cannot suppress system arbitration", () => {
  for (const role of ["user", "assistant", "tool"]) for (const text of [MARKER, ARBITRATION_BLOCK]) {
    const input = [{role:"system",content:"【必须遵循的工作流】三角度"}, {role,content:text}];
    const before = JSON.stringify(input);
    const output = arbitrateDelivery(input, {enabled:true}, "u1");
    assert.equal(output[0].content.endsWith(ARBITRATION_BLOCK), true);
    assert.equal(output[1].content, text);
    assert.equal(JSON.stringify(input), before);
    assert.strictEqual(arbitrateDelivery(output, {enabled:true}, "u1"), output);
  }
});

test("a system marker without the full block is not proof of injection", () => {
  const input = [{role:"system",content:MARKER}, {role:"user",content:"只改一句"}];
  const output = arbitrateDelivery(input, {enabled:true}, "u1");
  assert.equal(output[0].content.endsWith(ARBITRATION_BLOCK), true);
  assert.ok(output[0].content.length > MARKER.length);
  assert.strictEqual(arbitrateDelivery(output, {enabled:true,audience:"accounts",accountIds:["u2"]}, "u1"), output);
});
