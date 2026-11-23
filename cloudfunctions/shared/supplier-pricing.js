"use strict";
const { tokenCost } = require("./model-call-ledger");
const money = n => Number(n.toFixed(8));
const valid = n => n !== null && n !== undefined && n !== "" && Number.isFinite(Number(n)) && Number(n) >= 0;
function parse(value) { try { return typeof value === "string" ? JSON.parse(value) : value || {}; } catch { return {}; } }
function multiplierOf(runtime) {
  const n = Number(runtime?.USAGE_COST_MULTIPLIER);
  return Number.isFinite(n) && n >= 1 && n <= 10 ? n : 2;
}
function ratesFor(catalog, runtime, provider, model, startedAt) {
  // Provider + exact model is mandatory: identical model names can have different reseller prices.
  const manual = parse(runtime?.MODEL_COST_RATES)[provider + ":" + model];
  const entry = manual || catalog?.models?.[provider + ":" + model];
  if (!entry) return null;
  const hour = new Date(new Date(startedAt).getTime() + 8 * 3600000).getUTCHours();
  if (!Number.isFinite(hour)) return null;
  const scheduled = !!(entry.peak || entry.offpeak);
  const period = scheduled && (hour < 8 || hour >= 22) ? "offpeak" : "peak";
  const rates = scheduled ? entry[period] : entry;
  if (!rates) return null;
  if (!valid(rates.input) || !valid(rates.output)) return null;
  return { rates, provider, model, period, multiplier: multiplierOf(runtime),
    costBasis: manual ? "operator_verified_rate" : "vendor_bill_rate_estimate",
    catalogRevision: catalog?.revision || "", billDay: entry.billDay || "" };
}
function quoteCall(call, snapshot) {
  if (call.kind !== "chat") return null;
  if (!snapshot || snapshot.provider !== call.provider || snapshot.model !== call.model) return null;
  if (!["succeeded", "partial"].includes(call.status) || call.usageSource !== "provider_response") return null;
  if (snapshot.rates.cachedInput != null && call.cachedInputTokens == null) return null;
  for (const name of ["inputTokens", "outputTokens"]) if (!Number.isSafeInteger(call[name]) || call[name] < 0) return null;
  if (call.cachedInputTokens != null && (!Number.isSafeInteger(call.cachedInputTokens) || call.cachedInputTokens < 0 || call.cachedInputTokens > call.inputTokens)) return null;
  const cost = tokenCost(call, snapshot.rates);
  if (cost == null || !valid(snapshot.multiplier)) return null;
  return { supplierCostCny: money(cost), priceCny: money(cost * snapshot.multiplier), multiplier: snapshot.multiplier,
    costBasis: snapshot.costBasis, rateSnapshot: snapshot };
}
// Bills are aggregate evidence for unit rates, NOT per-user invoices. Credits,
// packages, negative adjustments and mixed prices must not become automatic allocations.
function catalogFromBills(snapshots) {
  const buckets = new Map(), issues = [];
  for (const s of [...snapshots].sort((a,b) => b.day.localeCompare(a.day))) {
    if (!s.complete || s.provider !== "aliyun-bailian") continue;
    for (const r of s.rows || []) {
      if (r.product !== "sfm" || r.currency !== "CNY" || r.item !== "token_number" || r.usageUnit !== "千tokens" || !(r.usage > 0) || !valid(r.payableAmount)) continue;
      const parts = String(r.instanceId || "").split(";");
      const idx = parts.findIndex(x => /^(input_token(?:_cache)?|output_token)_(peak|offpeak)$/.test(x));
      if (idx < 1) continue;
      const model = parts[idx-1], tag = parts[idx].match(/^(input_token(?:_cache)?|output_token)_(peak|offpeak)$/);
      const field = tag[1] === "output_token" ? "output" : tag[1] === "input_token_cache" ? "cachedInput" : "input";
      const key = s.provider+":"+model+"|"+tag[2]+"|"+field;
      const existing = buckets.get(key);
      if (existing && existing.day > s.day) continue;
      const rowHasOffsets = [r.resourcePackageDeduction,r.couponDeduction,r.prepaidDeduction,r.adjustAmount].some(n => n != null && Number.isFinite(Number(n)) && Number(n) !== 0) || r.payableAmount === 0;
      const rate = money(r.payableAmount / r.usage * 1000);
      if (existing && existing.day === s.day && (existing.invalid || Math.abs(existing.rate-rate) > 1e-7)) {
        existing.invalid = true; continue;
      }
      buckets.set(key,{day:s.day,rate,invalid:rowHasOffsets,model,period:tag[2],field,provider:s.provider});
    }
  }
  const models = {};
  for (const b of buckets.values()) {
    if (b.invalid) { issues.push({model:b.model,period:b.period,field:b.field,reason:"ambiguous_or_offset_bill"}); continue; }
    const key=b.provider+":"+b.model, e=models[key] ||= {billDay:b.day};
    e[b.period] ||= {}; e[b.period][b.field]=b.rate;
    if (e.billDay < b.day) e.billDay=b.day;
  }
  return {schemaVersion:1,models,issues,source:"official_daily_bills",perRequestInvoice:false};
}
function imageQuote(model, size, inputImages, runtime = {}) {
  let cost;
  if (/seedream-5-0-pro/i.test(model)) {
    const s=String(size).toUpperCase(), m=/^(\d+)[X×](\d+)$/.exec(s);
    if (!m && !["1.5K","2K","4K"].includes(s)) return null;
    const large=m ? Number(m[1])*Number(m[2]) > 2610000 : ["2K","4K"].includes(s);
    cost=Number(runtime[large?"IMAGE_COST_PRO_LARGE":"IMAGE_COST_PRO_SMALL"] ?? (large?0.60:0.30));
    cost+=Math.max(0,(Number(inputImages)||0)-1)*Number(runtime.IMAGE_COST_EXTRA_INPUT ?? 0.02);
  } else if (/seedream-5-0-flash/i.test(model)) cost=Number(runtime.IMAGE_COST_FLASH ?? 0.12);
  else return null;
  if (!valid(cost)) return null;
  return {supplierCostCny:money(cost),priceCny:money(cost*multiplierOf(runtime)),multiplier:multiplierOf(runtime),costBasis:"configured_image_rate"};
}
module.exports={money,multiplierOf,ratesFor,quoteCall,catalogFromBills,imageQuote};
