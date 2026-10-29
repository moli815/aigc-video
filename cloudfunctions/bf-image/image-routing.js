"use strict";
const { requestsQuality, requestsModel } = require("./shared/image-quality-intent");

// Runtime JSON is validated here too: DB writes can bypass the admin form.
const DEFAULT_POLICY = Object.freeze({
  defaultTier: "fast", honorClientHigh: false, proTaskKinds: [],
  proReasons: ["complex_edit", "identity_sensitive"], minReferencesForPro: 3,
  nativeTextCharsForPro: 180, retryQualityToPro: true, capabilityFallback: true,
  honorUserQuality: false, proPromptTerms: [],
  fallbackCodes: ["ModelNotSupport", "ModelCapabilityNotSupported", "UnsupportedOperation"],
});
function parseAutoPolicy(raw) {
  let value;
  try { value = typeof raw === "string" ? JSON.parse(raw) : raw; } catch { value = null; }
  if (!value || typeof value !== "object" || Array.isArray(value)) return { ...DEFAULT_POLICY };
  const out = { ...DEFAULT_POLICY };
  if (["fast", "high"].includes(value.defaultTier)) out.defaultTier = value.defaultTier;
  for (const key of ["honorClientHigh", "honorUserQuality", "retryQualityToPro", "capabilityFallback"]) if (typeof value[key] === "boolean") out[key] = value[key];
  for (const key of ["proTaskKinds", "proReasons", "fallbackCodes", "proPromptTerms"]) {
    if (Array.isArray(value[key]) && value[key].length <= 30 && value[key].every(x => typeof x === "string" && x.trim().length > 0 && x.length <= 80)) out[key] = value[key];
  }
  for (const [key, min, max] of [["minReferencesForPro", 2, 7], ["nativeTextCharsForPro", 0, 10000]]) {
    if (Number.isInteger(value[key]) && value[key] >= min && value[key] <= max) out[key] = value[key];
  }
  return out;
}
function autoDecision(input, rawPolicy) {
  const policy = parseAutoPolicy(rawPolicy);
  const fields = input.structured || {}, routing = fields.routing || {};
  const text = String(input.prompt || "");
  const refs = Array.isArray(input.image) ? input.image.length : input.image ? 1 : 0;
  const kind = input.taskKind || "generate";
  // Client high is generally a baked-in safety default. In auto mode, it is a
  // recommendation, not proof that the human explicitly requested Pro.
  if (routing.preference === "pro" || requestsModel(text, "pro")) return { tier: "high", reason: "auto:explicit-pro" };
  if (routing.preference === "flash") return { tier: "fast", reason: "auto:explicit-flash" };
  if (policy.honorUserQuality && routing.user_quality === "high") return { tier: "high", reason: "auto:user-quality" };
  // Older/direct requests have no user-origin signal. Configured literal terms
  // are a fallback only; Agent-added adjectives cannot override an explicit auto.
  if (policy.honorUserQuality && routing.user_quality === undefined && requestsQuality(text, policy.proPromptTerms)) return { tier: "high", reason: "auto:prompt-quality" };
  if (policy.retryQualityToPro && (routing.reason === "quality_retry" || /未通过(?:画质|视觉|质量)检查|质量复检失败|Flash效果不佳|flash[_ -]quality[_ -]failed/i.test(text))) return { tier: "high", reason: "auto:quality-retry" };
  if (policy.proTaskKinds.includes(kind)) return { tier: "high", reason: "auto:complex-task" };
  if (refs >= policy.minReferencesForPro) return { tier: "high", reason: "auto:multi-reference" };
  // Roles/identity are protected for reference edits; ordinary two-image
  // composites can still use Flash unless the Agent explicitly classifies them.
  if (policy.proReasons.includes(routing.reason)) return { tier: "high", reason: "auto:" + routing.reason };
  const copy = Array.isArray(fields.text) ? fields.text.map(x => x && x.text || "").join("") : String(fields.text || "");
  if (input.textMode !== "overlay" && policy.nativeTextCharsForPro > 0 && copy.length >= policy.nativeTextCharsForPro) return { tier: "high", reason: "auto:dense-native-text" };
  if (policy.honorClientHigh && ["high", "pro", "quality", "best", "hd", "2k"].includes(String(input.qualityTier || "").toLowerCase())) return { tier: "high", reason: "auto:client-high" };
  return { tier: policy.defaultTier, reason: "auto:default-" + policy.defaultTier };
}
function canFallbackToPro({ mode, selected, pro, status, body, policy: rawPolicy }) {
  const policy = parseAutoPolicy(rawPolicy);
  if (mode !== "auto" || !policy.capabilityFallback || !pro || selected === pro) return false;
  if (![400, 422].includes(status)) return false;
  const error = body && body.error;
  const code = typeof error === "object" && error ? error.code : body && body.code;
  // Only a definite capability rejection. Timeouts, 5xx, safety rejection,
  // malformed success and missing URLs may already have incurred cost.
  return policy.fallbackCodes.includes(String(code || ""));
}
module.exports = { DEFAULT_POLICY, parseAutoPolicy, autoDecision, canFallbackToPro };
