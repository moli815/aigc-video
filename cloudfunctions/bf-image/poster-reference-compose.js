"use strict";
/**
 * 参考图确定性合成：让客户给的真实照片「像素级」出现在成品里。
 *
 * 为什么不再靠提示词（2026-11-16 实测）：
 *   把文案约束加严之后，模型把客户给的指挥中心大屏换成了相似的街景照片。
 *   提示词对「保真」这件事没有强制力——约束越紧，压力会转移到另一处。
 *
 * 做法（占位色抠图 + 本地贴回）：
 *   1) 生成时要求模型在照片位置留一块纯品红矩形占位（不加内容、不加边框）；
 *   2) 服务端按颜色找到这块矩形，得到精确坐标；
 *   3) 用 protected-asset-compositor 把原图按坐标贴回去，透视/缩放由 OpenCV 做。
 *   模型只决定「照片放哪、多大」，像素永远来自原图。
 */

const crypto = require("crypto");
const { PNG } = require("pngjs");
const compositor = require("./protected-asset-compositor");

const PLACEHOLDER = [255, 0, 255];

/** 生成阶段要追加的一句。刻意写死「纯品红」和「不得出现在别处」。 */
function placeholderClause() {
  return "在实景照片应该出现的位置，留出一块纯品红色（#FF00FF）的实心矩形占位区，四个角可以是直角；" +
    "这块矩形里不加任何内容、文字、图标、边框或光效。品红色除这块矩形外不得出现在画面任何其他位置。";
}

/**
 * 找品红占位块。
 * @returns {{box:[number,number,number,number], coverage:number, fill:number, pixels:number}|null}
 *          box 为归一化 [x,y,w,h]
 */
function findPlaceholder(raster, opts = {}) {
  const tol = Number.isFinite(opts.tol) ? opts.tol : 60;
  const minCoverage = Number.isFinite(opts.minCoverage) ? opts.minCoverage : 0.008;
  const { width, height, data } = raster;
  let l = width, t = height, r = -1, b = -1, count = 0;
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const i = (y * width + x) * 4;
      if (data[i + 3] < 200) continue;
      if (Math.abs(data[i] - PLACEHOLDER[0]) <= tol && data[i + 1] <= tol && Math.abs(data[i + 2] - PLACEHOLDER[2]) <= tol) {
        count++;
        if (x < l) l = x;
        if (y < t) t = y;
        if (x > r) r = x;
        if (y > b) b = y;
      }
    }
  }
  if (r < l || b < t) return null;
  const bw = r - l + 1, bh = b - t + 1;
  const coverage = count / (width * height);
  if (coverage < minCoverage) return null;
  // 填充率太低说明是散落的误判像素，不是一块实心矩形
  const fill = count / (bw * bh);
  if (fill < 0.55) return null;
  return { box: [l / width, t / height, bw / width, bh / height], coverage, fill, pixels: count };
}

/** 把品红占位块涂成中性底色，避免合成边缘透出品红。 */
function cleanPlate(raster, box) {
  const [nx, ny, nw, nh] = box;
  const x0 = Math.floor(nx * raster.width), y0 = Math.floor(ny * raster.height);
  const x1 = Math.min(raster.width, Math.ceil((nx + nw) * raster.width));
  const y1 = Math.min(raster.height, Math.ceil((ny + nh) * raster.height));
  const out = { width: raster.width, height: raster.height, data: Buffer.from(raster.data) };
  for (let y = y0; y < y1; y++) {
    for (let x = x0; x < x1; x++) {
      const i = (y * out.width + x) * 4;
      out.data[i] = 12; out.data[i + 1] = 20; out.data[i + 2] = 38; out.data[i + 3] = 255;
    }
  }
  return out;
}

function sha256(buf) {
  return crypto.createHash("sha256").update(buf).digest("hex");
}

/**
 * 合成：把 photoBytes 原样贴进 canvasBytes 的占位区。
 * @returns {Promise<{png:Buffer, box, manifest}|null>} 找不到占位块返回 null，由调用方决定降级
 */
async function composeReferencePhoto({ canvasBytes, photoBytes, tol, minCoverage, padding = 0 }) {
  const raster = compositor.decode(canvasBytes);
  const found = findPlaceholder(raster, { tol, minCoverage });
  if (!found) return null;

  let box = found.box.slice();
  if (padding) {
    const p = Math.max(0, Math.min(0.2, padding));
    box = [Math.max(0, box[0] - p), Math.max(0, box[1] - p), Math.min(1 - box[0] + p, box[2] + 2 * p), Math.min(1 - box[1] + p, box[3] + 2 * p)];
  }

  const plate = cleanPlate(raster, found.box);
  const plateBytes = PNG.sync.write(plate);
  const quad = compositor.boxQuad(box);
  const out = await compositor.compose({
    canvas: plateBytes,
    placements: [{
      role: "ui",
      bytes: photoBytes,
      sha256: sha256(photoBytes),
      quad,
      method: "reference-composite",
    }],
  });
  return { png: out.png, box, coverage: found.coverage, fill: found.fill, manifest: out.manifest };
}

module.exports = { PLACEHOLDER, placeholderClause, findPlaceholder, cleanPlate, composeReferencePhoto };
