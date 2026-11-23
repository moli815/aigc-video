"use strict";
// Seedream 5.5: explicit pixels, total area 921600..4624220,
// aspect 1/16..16. Geometry is a planning aid, never a text-quality guarantee.
// https://docs.volcengine.com/docs/ark/seedream-5-5?lang=zh
function ratioOf(raw) {
  const m = String(raw || "").trim().match(/^(\d+(?:\.\d+)?)\s*[:：x×]\s*(\d+(?:\.\d+)?)$/i);
  if (!m) return null;
  const w = Number(m[1]), h = Number(m[2]), ratio = w / h;
  return w > 0 && h > 0 && ratio >= 1 / 16 && ratio <= 16 ? { key: `${w}:${h}`, ratio } : null;
}
function planPosterCanvas({ blocks = [], aspectRatio = "", orientation = "", hasPhoto = false } = {}) {
  const rows = blocks.filter(b => typeof b?.text === "string" && b.text.trim());
  const totalChars = rows.reduce((n, b) => n + [...b.text.replace(/\s+/g, "")].length, 0);
  const explicit = aspectRatio ? ratioOf(aspectRatio) : null;
  if (aspectRatio && !explicit) throw Object.assign(Error("POSTER_RATIO_INVALID"), { code: "POSTER_RATIO_INVALID" });
  const size = totalChars > 120 || hasPhoto ? "2K" : "1.5K";
  // Direction is an explicit caller decision. Never infer a mandatory blue
  // wide poster merely because an input screenshot happens to be landscape.
  const dense = totalChars > 300 || rows.length > 20;
  const ratio = explicit || ratioOf(orientation === "landscape"
    ? dense ? "21:9" : "16:9"
    : dense ? totalChars > 800 || rows.length > 35 ? "9:32" : totalChars > 500 ? "9:21" : "9:16" : "3:4");
  const area = size === "2K" ? 4194304 : 2359296;
  const snap = x => Math.round(x / 8) * 8;
  const width = snap(Math.sqrt(area * ratio.ratio)), height = snap(Math.sqrt(area / ratio.ratio));
  if (width > 8192 || height > 8192 || width * height > 4624220 || width * height < 921600) {
    throw Object.assign(Error("POSTER_CANVAS_UNSUPPORTED"), { code: "POSTER_CANVAS_UNSUPPORTED" });
  }
  return { size, aspectRatio: ratio.key, ratioSource: explicit ? "explicit" : "content",
    width, height, pixels: `${width}×${height}`, providerSize: `${width}x${height}`,
    totalChars, blocks: rows.length, outputTierCny: size === "2K" ? 0.23 : 0.13,
    capacityWarning: totalChars > 800 || rows.length > 40,
    reason: explicit ? "保留指定比例" : dense ? "按完整文案与阅读方向选择长画布" : "常规信息量",
    caveat: "同一像素档改变比例不增加总像素；长画布仍须验证字形、完整性和实际阅读尺寸，不自动拆页或缩字。" };
}
module.exports = { ratioOf, planPosterCanvas };
