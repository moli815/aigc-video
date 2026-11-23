"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const path = require("path");
const root = path.join(__dirname, "..");
const image = fs.readFileSync(path.join(root, "cloudfunctions/bf-image/index.js"), "utf8");
const api = fs.readFileSync(path.join(root, "cloudfunctions/bf-api/index.js"), "utf8");

test("Seedream reference images never inherit automatic prompt rewriting", () => {
  const guards = image.match(/caps\.fastPromptMode && !image/g) || [];
  assert.equal(guards.length, 2, "initial and capability-fallback payloads must both exclude references");
  assert.match(image, /if \(image\) payload\.image = image/);
});

test("native series uses official nested max_images and capability matrix", () => {
  assert.match(image, /payload\.sequential_image_generation = "auto"/);
  assert.match(image, /payload\.sequential_image_generation_options = \{ max_images:/);
  assert.doesNotMatch(image, /payload\.max_images\s*=/);
  assert.match(image, /doubao-seedream-4-0-250828[\s\S]{0,100}series: true/);
  assert.match(image, /doubao-seedream-4-5-251128[\s\S]{0,100}series: true/);
  assert.match(image, /doubao-seedream-5-0-pro-260628[\s\S]{0,100}series: false/);
  assert.match(image, /doubao-seedream-5-0-flash-260915[\s\S]{0,100}series: false/);
  assert.match(image, /key: "series", args: \{ taskKind: "series"/);
});

test("current Pro billing threshold stays at the official 2.61 million pixels", () => {
  assert.match(image, /const large = px > 2_610_000/);
  assert.match(image, /IMAGE_COST_PRO_SMALL: process\.env\.IMAGE_COST_PRO_SMALL \|\| "0\.3"/);
  assert.match(image, /IMAGE_COST_PRO_LARGE: process\.env\.IMAGE_COST_PRO_LARGE \|\| "0\.6"/);
  assert.doesNotMatch(image, /≤236 万|>236 万/);
});

test("non-idempotent chat and image POSTs do not use generic transient retry", () => {
  const chat = api.slice(api.indexOf("async function handleChat"), api.indexOf("async function enhanceImagePrompt"));
  const dashscope = api.slice(api.indexOf("async function callDashscopeImage"), api.indexOf("async function callImageUpstream"));
  assert.match(chat, /upstream = await fetchWithTimeout/);
  assert.doesNotMatch(chat, /upstream = await fetchWithTransientRetry/);
  assert.match(dashscope, /const r = await fetchWithTimeout/);
  assert.doesNotMatch(dashscope, /fetchWithTransientRetry/);
});
