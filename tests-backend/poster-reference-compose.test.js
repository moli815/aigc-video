"use strict";
const test = require("node:test");
const assert = require("node:assert");
const path = require("path");
const { PNG } = require(path.join(__dirname, "../cloudfunctions/bf-image/node_modules/pngjs"));
const RC = require("../cloudfunctions/bf-image/poster-reference-compose.js");
const compositor = require("../cloudfunctions/bf-image/protected-asset-compositor.js");

function makeCanvas(w, h, box) {
  const png = new PNG({ width: w, height: h });
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const i = (y * w + x) * 4;
    png.data[i] = 10; png.data[i + 1] = 20; png.data[i + 2] = 40; png.data[i + 3] = 255;
  }
  if (box) {
    const [bx, by, bw, bh] = box;
    for (let y = by; y < by + bh; y++) for (let x = bx; x < bx + bw; x++) {
      const i = (y * w + x) * 4;
      png.data[i] = 255; png.data[i + 1] = 0; png.data[i + 2] = 255; png.data[i + 3] = 255;
    }
  }
  return PNG.sync.write(png);
}

function makePhoto(w, h, rgb) {
  const png = new PNG({ width: w, height: h });
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const i = (y * w + x) * 4;
    png.data[i] = rgb[0]; png.data[i + 1] = rgb[1]; png.data[i + 2] = rgb[2]; png.data[i + 3] = 255;
  }
  return PNG.sync.write(png);
}

test("占位色提示词里写死了纯品红与独占要求", () => {
  const c = RC.placeholderClause();
  assert.match(c, /#FF00FF/);
  assert.match(c, /不得出现在画面任何其他位置/);
});

test("能定位占位矩形并给出归一化坐标", () => {
  const bytes = makeCanvas(400, 600, [100, 120, 200, 300]);
  const r = RC.findPlaceholder(compositor.decode(bytes));
  assert.ok(r, "没找到占位块");
  assert.ok(Math.abs(r.box[0] - 100 / 400) < 0.01, "x 偏差过大：" + r.box[0]);
  assert.ok(Math.abs(r.box[1] - 120 / 600) < 0.01, "y 偏差过大：" + r.box[1]);
  assert.ok(Math.abs(r.box[2] - 200 / 400) < 0.01);
  assert.ok(Math.abs(r.box[3] - 300 / 600) < 0.01);
});

test("没有占位块时返回 null，不瞎猜", () => {
  const bytes = makeCanvas(300, 300, null);
  assert.equal(RC.findPlaceholder(compositor.decode(bytes)), null);
});

test("散落的少量品红像素不算占位块（防止误判）", () => {
  const png = new PNG({ width: 300, height: 300 });
  for (let i = 0; i < png.data.length; i += 4) { png.data[i] = 10; png.data[i + 1] = 20; png.data[i + 2] = 40; png.data[i + 3] = 255; }
  // 只点 20 个孤立像素
  for (let k = 0; k < 20; k++) { const i = (k * 37) * 4; png.data[i] = 255; png.data[i + 1] = 0; png.data[i + 2] = 255; }
  assert.equal(RC.findPlaceholder(compositor.decode(PNG.sync.write(png))), null);
});

test("占位区被涂成中性底色，合成后不会透出品红", () => {
  const bytes = makeCanvas(200, 200, [50, 50, 100, 100]);
  const r = RC.findPlaceholder(compositor.decode(bytes));
  const cleaned = RC.cleanPlate(compositor.decode(bytes), r.box);
  let magenta = 0;
  for (let i = 0; i < cleaned.data.length; i += 4) {
    if (cleaned.data[i] > 200 && cleaned.data[i + 1] < 60 && cleaned.data[i + 2] > 200) magenta++;
  }
  assert.equal(magenta, 0);
});

test("合成后占位区里出现的是原图颜色", async () => {
  const canvas = makeCanvas(400, 600, [100, 120, 200, 300]);
  const photo = makePhoto(300, 400, [20, 200, 90]);
  const out = await RC.composeReferencePhoto({ canvasBytes: canvas, photoBytes: photo });
  assert.ok(out && Buffer.isBuffer(out.png), "合成失败");
  const r = compositor.decode(out.png);
  const cx = Math.floor(r.width * 0.5), cy = Math.floor(r.height * 0.45);
  const i = (cy * r.width + cx) * 4;
  assert.ok(Math.abs(r.data[i] - 20) < 24, "R 不像原图：" + r.data[i]);
  assert.ok(Math.abs(r.data[i + 1] - 200) < 24, "G 不像原图：" + r.data[i + 1]);
  assert.ok(Math.abs(r.data[i + 2] - 90) < 24, "B 不像原图：" + r.data[i + 2]);
});
