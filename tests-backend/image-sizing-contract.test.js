const test = require("node:test");
const assert = require("node:assert/strict");
const { resolveImageSize } = require("../cloudfunctions/bf-image/image-sizing");

function dimensions(size) {
  const [width, height] = String(size).split("x").map(Number);
  return { width, height, ratio: width / height, pixels: width * height };
}

test("Seedream 5.0 documented aspect presets are used for every resolution tier", () => {
  assert.equal(resolveImageSize("1K", "21:9"), "1568x672");
  assert.equal(resolveImageSize("1.5K", "1:1"), "1536x1536");
  assert.equal(resolveImageSize("1.5K", "16:9"), "2048x1152");
  assert.equal(resolveImageSize("2K", "4:3"), "2368x1776");
  assert.equal(resolveImageSize("2K", "16:9"), "2816x1584");
});

test("arbitrary valid aspect ratios retain their ratio at the requested pixel tier", () => {
  const result = dimensions(resolveImageSize("1.5K", "4:5"));
  assert.ok(Math.abs(result.ratio - 0.8) < 0.01, `unexpected ratio: ${result.width}x${result.height}`);
  assert.ok(result.pixels >= 921_600 && result.pixels <= 4_622_220);
});

test("explicit pixel dimensions win over an incompatible aspect hint", () => {
  assert.equal(resolveImageSize("1200x800", "1:1"), "1200x800");
});

test("unrepresentable aspect ratios fail closed instead of silently becoming square", () => {
  assert.equal(resolveImageSize("1.5K", "1:16"), null);
});

test("malformed explicit aspect ratios fail closed instead of silently using the default tier", () => {
  assert.equal(resolveImageSize("1.5K", "not-a-ratio"), null);
});

test("unknown and invalid explicit sizes fail closed instead of silently becoming 1.5K", () => {
  assert.equal(resolveImageSize("very-large", "16:9"), null);
  assert.equal(resolveImageSize("99999x99999", "16:9"), null);
});

test("auto uses a validated configured default and never leaks auto to the provider", () => {
  assert.equal(resolveImageSize("auto", "16:9", "2K"), "2816x1584");
  assert.equal(resolveImageSize("auto", "16:9", "invalid-default"), null);
});
