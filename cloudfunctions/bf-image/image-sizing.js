"use strict";

const { clampExplicitSize } = require("./media-guards");

// Seedream 5.0 Pro/Flash documented reference dimensions by resolution tier.
// Explicit WxH payloads are used so the canvas aspect is not left to a second prompt parser.
const ASPECT_SIZE_PRESETS = Object.freeze({
  "1K": Object.freeze({
    "1:1": "1024x1024", "4:3": "1152x864", "3:4": "864x1152",
    "16:9": "1424x800", "9:16": "800x1424", "3:2": "1248x832",
    "2:3": "832x1248", "21:9": "1568x672",
  }),
  "1.5K": Object.freeze({
    "1:1": "1536x1536", "4:3": "1792x1344", "3:4": "1344x1792",
    "16:9": "2048x1152", "9:16": "1152x2048", "3:2": "1872x1248",
    "2:3": "1248x1872", "21:9": "2352x1008",
  }),
  "2K": Object.freeze({
    "1:1": "2048x2048", "4:3": "2368x1776", "3:4": "1776x2368",
    "16:9": "2816x1584", "9:16": "1584x2816", "3:2": "2496x1664",
    "2:3": "1664x2496", "21:9": "3136x1344",
  }),
});

const TARGET_PIXELS_BY_TIER = Object.freeze({
  "1K": 1_048_576,
  "1.5K": 2_359_296,
  "2K": 4_194_304,
});

function normalizedRatio(raw) {
  const value = String(raw || "").trim().replace(/[：xX×*]/g, ":");
  const parts = value.split(":").map((part) => Number(part.trim()));
  if (parts.length !== 2 || !parts.every((part) => Number.isFinite(part) && part > 0)) return null;
  const ratio = parts[0] / parts[1];
  // Seedream accepts ratios in [1/16, 16]; local image guards may reject ratios
  // that cannot fit the bounded output canvas rather than silently changing them.
  if (ratio < 1 / 16 || ratio > 16) return null;
  return { ratio, key: `${parts[0]}:${parts[1]}` };
}

function snapToEight(value) {
  return Math.round(value / 8) * 8;
}

/**
 * Resolve one output canvas size for the provider request.
 * Explicit pixels win. Known ratios use the provider's resolution table; other valid
 * ratios target the same pixel tier. If local safety bounds cannot represent the ratio,
 * return null so callers can fail clearly instead of generating the wrong aspect.
 */
function resolveImageSize(size, aspectRatio, defaultSize = "1.5K") {
  const suppliedSize = String(size || "").trim();
  const configuredDefault = String(defaultSize || "1.5K").trim();
  let rawSize = suppliedSize || configuredDefault;
  const explicitPattern = /^\d+\s*[xX×]\s*\d+$/;
  if (explicitPattern.test(rawSize)) return clampExplicitSize(rawSize);
  if (/^auto$/i.test(rawSize)) rawSize = configuredDefault;

  const presetMatch = /^(1K|1\.5K|2K)$/i.exec(rawSize);
  if (!presetMatch) return null;
  const requestedTier = presetMatch[1].toUpperCase();
  const rawAspect = String(aspectRatio || "").trim();
  if (!rawAspect) return requestedTier;
  const aspect = normalizedRatio(rawAspect);
  if (!aspect) return null;

  const preset = ASPECT_SIZE_PRESETS[requestedTier][aspect.key];
  if (preset) return clampExplicitSize(preset);

  const targetPixels = TARGET_PIXELS_BY_TIER[requestedTier];
  const width = snapToEight(Math.sqrt(targetPixels * aspect.ratio));
  const height = snapToEight(Math.sqrt(targetPixels / aspect.ratio));
  return clampExplicitSize(`${width}x${height}`);
}

module.exports = { ASPECT_SIZE_PRESETS, TARGET_PIXELS_BY_TIER, normalizedRatio, resolveImageSize };
