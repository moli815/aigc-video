"use strict";
const { STYLES, LAYOUTS } = require("./shared/image-workflow");

// Only sheets packed by the member client can use this path. Ownership and
// the byte digest of every slot are verified before the provider call.
function plan(structured, image, taskKind, textMode, layers) {
  const spec = structured.print_catalog;
  const count = Array.isArray(image) ? image.length : image ? 1 : 0;
  if (spec?.version !== 1 || ![1, 2].includes(spec.sheets) || typeof spec.logo !== "boolean"
      || count !== spec.sheets + Number(spec.logo) || !["reference", "generate"].includes(taskKind)
      || textMode === "overlay" || layers || structured.verbatim_prompt || structured.image_references
      || structured.poster_reformat || structured.preserve_assets?.length
      || !Array.isArray(structured.text) || !structured.text.length) {
    throw Object.assign(Error("CATALOG_SOURCES_INVALID"), {code: "CATALOG_SOURCES_INVALID"});
  }

  const design = structured.image_plan || {};
  const slots = Array.from({length: spec.sheets}, (_, i) => ({index: i + 1, role: "catalog"}));
  if (spec.logo) slots.push({index: count, role: "logo"});
  return {
    catalog: true, native: false, protectUI: true, intent: "product_reference",
    visual_style: STYLES.includes(design.visual_style) ? design.visual_style : "photographic",
    layout: LAYOUTS.includes(design.layout) ? design.layout : undefined,
    protected_references: slots
  };
}
// ImageCompressor.referenceSheets uses exactly two 384 × 310 cells per row.
// Unknown sheet formats keep the existing whole-image path.
function tiles(raster, expected) {
  if (raster.width !== 768 || raster.height % 310 !== 0 || raster.height > 1240) return null;
  if (!Number.isInteger(expected) || expected < 1 || expected > 8 || raster.height !== 310*Math.ceil(expected/2)) return null;
  const {PNG} = require("pngjs");
  const result = [];
  const count = (raster.height / 310) * 2;
  for (let i = 0; i < count; i++) {
    const tile = new PNG({width:384,height:310});
    PNG.bitblt(raster,tile,(i % 2) * 384,Math.floor(i / 2) * 310,384,310,0,0);
    // Only discard confirmed empty padding. A count conflict preserves the whole sheet.
    if (i >= expected) {
      if (!tile.data.every(value => value === 255)) return null;
      break;
    }
    result.push("data:image/png;base64," + PNG.sync.write(tile).toString("base64"));
  }
  return result;
}
module.exports = {plan,tiles};
