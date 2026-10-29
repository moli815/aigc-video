"use strict";

// Independent observation ledger. It never debits an account or changes a provider payload.
const crypto = require("node:crypto");
const COLLECTION = "bf_model_calls";
const finite = value => value != null && Number.isFinite(Number(value)) && Number(value) >= 0 ? Number(value) : null;
const safeId = value => typeof value === "string" ? value.replace(/[^a-zA-Z0-9_.:\/-]/g, "").slice(0, 160) : "";
function providerOf(url) {
  const host = new URL(url).hostname;
  if (host.endsWith("volces.com")) return "volcengine";
  if (host.endsWith("aliyuncs.com")) return "aliyun-bailian";
  if (host === "api.deepseek.com") return "deepseek";
  return host;
}
function orderIdOf(accountId, requestId) {
  return "ord_" + crypto.createHash("sha256").update(accountId + "\0" + requestId).digest("hex").slice(0, 32);
}
function usageOf(value) {
  const u = value && (value.usage || value.output?.usage);
  if (!u) return { inputTokens: null, outputTokens: null, cachedInputTokens: null, reasoningTokens: null, totalTokens: null, usageSource: "unavailable" };
  return {
    inputTokens: finite(u.prompt_tokens ?? u.input_tokens),
    outputTokens: finite(u.completion_tokens ?? u.output_tokens),
    cachedInputTokens: finite(u.prompt_tokens_details?.cached_tokens ?? u.input_tokens_details?.cached_tokens ?? u.prompt_cache_hit_tokens),
    reasoningTokens: finite(u.completion_tokens_details?.reasoning_tokens),
    totalTokens: finite(u.total_tokens), usageSource: "provider_response",
  };
}
function tokenCost(usage, rates) {
  if (!rates || usage.inputTokens == null || usage.outputTokens == null) return null;
  const input = finite(rates.input), output = finite(rates.output), cache = finite(rates.cachedInput);
  if (input == null || output == null) return null;
  const cached = Math.min(usage.inputTokens, usage.cachedInputTokens || 0);
  // Unknown cached-token price is not silently assumed equal to the input price.
  if (cached && cache == null) return null;
  return Number((((usage.inputTokens - cached) * input + cached * (cache || 0) + usage.outputTokens * output) / 1e6).toFixed(10));
}
function createModelCallLedger({ db, context, source, log, pricing = () => null }) {
  const database = () => typeof db === "function" ? db() : db;
  async function write(id, value, insert = false) {
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        const col = database().collection(COLLECTION);
        if (insert) await col.add({ _id: id, ...value });
        else await col.doc(id).update(value);
        return true;
      } catch (error) {
        if (attempt === 1) {
          // A pending row remains recoverable if finalization fails. Never log content/keys.
          log({ tag: "model_call_ledger_write_failed", callId: id, operation: insert ? "insert" : "update", code: safeId(error.code || error.name), record: JSON.parse(JSON.stringify(value)) });
        }
      }
    }
    return false;
  }
  async function charge(callId, priceCny, billingEventId) {
    if (!callId) return;
    await write(callId, { priceCny: finite(priceCny), chargeState: "committed", billingEventId: safeId(billingEventId), chargedAt: new Date() });
  }
  async function cached(model, kind = "chat") {
    const c = context() || {};
    if (!c.accountId) return;
    const id = "call_" + crypto.randomUUID();
    await write(id, { orderId: orderIdOf(c.accountId, c.businessRequestId || c.requestId), requestId: safeId(c.requestId), clientRequestId: safeId(c.businessRequestId), accountId: c.accountId,
      source, endpoint: c.endpoint || "", kind, model, provider: "local-cache", status: "cached", startedAt: new Date(), endedAt: new Date(),
      durationMs: 0, inputTokens: 0, outputTokens: 0, usageSource: "cache", supplierCostEstimateCny: 0,
      supplierBilledCny: null, reconciliationState: "not_applicable", priceCny: 0, chargeState: "not_charged", currency: "CNY" }, true);
  }
  async function fetchTracked(url, options, fetchImpl = globalThis.fetch) {
    const pathname = new URL(url).pathname;
    if (!/\/(chat\/completions|images\/generations|multimodal-generation\/generation|tools\/(search|fetch))$/.test(pathname)) return fetchImpl(url, options);
    const c = context() || {};
    let payload;
    try { payload = JSON.parse(options.body); } catch { return fetchImpl(url, options); }
    const id = "call_" + crypto.randomUUID(), started = Date.now();
    const fingerprint = crypto.createHash("sha256").update(pathname + "\0" + String(options.body)).digest("hex");
    c.ledgerAttempts ||= new Map();
    const retryIndex = c.ledgerAttempts.get(fingerprint) || 0;
    c.ledgerAttempts.set(fingerprint, retryIndex + 1);
    const kind = /chat\/completions$/.test(pathname) ? "chat" : /tools\//.test(pathname) ? "tool" : "image";
    const row = {
      schemaVersion: 1, orderId: orderIdOf(c.accountId || "system", c.businessRequestId || c.requestId || id), requestId: safeId(c.requestId), clientRequestId: safeId(c.businessRequestId),
      accountId: c.accountId || "", source, endpoint: c.endpoint || "", provider: providerOf(url),
      kind, model: safeId(payload.model || pathname.split("/").pop()), stream: payload.stream === true, retryIndex,
      taskKind: c.taskKind || "", inputImages: kind === "chat" ? (payload.messages || []).reduce((n, m) => n + (Array.isArray(m.content) ? m.content.filter(p => p?.type === "image_url").length : 0), 0) : Array.isArray(payload.image) ? payload.image.length : payload.image ? 1 : 0,
      credentialFingerprint: crypto.createHash("sha256").update(String(new Headers(options.headers).get("authorization") || "")).digest("hex").slice(0, 16),
      requestedSize: safeId(payload.size), startedAt: new Date(started), status: "pending", currency: "CNY",
      supplierCostEstimateCny: null, supplierBilledCny: null, reconciliationState: "pending_vendor_bill",
      priceCny: null, chargeState: "not_recorded", ...usageOf(null),
    };
    const persisted = await write(id, row, true);
    if (!persisted) log({ tag: "model_call_ledger_fallback", callId: id, record: JSON.parse(JSON.stringify(row)) });
    const priceSnapshot = pricing(payload, row);
    let completed = false, lastUsage = usageOf(null), responseModel = row.model, vendorId = "", providerResponseId = "", json = "", line = "", outputImages = null;
    let tooLarge = false, errorCode = "", finishReason = "", streamDone = false, truncated = false, cancelled = false;
    const decoder = new TextDecoder();
    function consumeObject(value) {
      if (!value || typeof value !== "object") return;
      if (value.usage || value.output?.usage) lastUsage = usageOf(value);
      if (typeof value.model === "string") responseModel = safeId(value.model);
      providerResponseId = safeId(value.id || value.request_id || providerResponseId);
      errorCode = safeId(value.error?.code || (value.code && value.code !== "Success" ? value.code : errorCode));
      for (const choice of value.choices || []) if (choice.finish_reason) { finishReason = safeId(choice.finish_reason); if (choice.finish_reason === "length") truncated = true; }
      if (Array.isArray(value.data)) outputImages = value.data.filter(item => item?.url || item?.b64_json).length;
      if (Array.isArray(value.output?.choices)) outputImages = value.output.choices.flatMap(x => x.message?.content || []).filter(x => x.image).length;
    }
    function feed(text, isSSE) {
      if (!isSSE) { if (json.length + text.length <= 1048576) json += text; else tooLarge = true; return; }
      line += text;
      let pos;
      while ((pos = line.indexOf("\n")) >= 0) {
        const data = line.slice(0, pos).replace(/\r$/, ""); line = line.slice(pos + 1);
        if (!data.startsWith("data:")) continue;
        const content = data.slice(5).trim();
        if (content === "[DONE]") { streamDone = true; continue; }
        try { consumeObject(JSON.parse(content)); } catch { /* A non-JSON SSE event is not a usage event. */ }
      }
      if (line.length > 1048576) { line = ""; tooLarge = true; }
    }
    async function finish(status, extra = {}) {
      if (completed) return; completed = true;
      const rates = priceSnapshot?.rates;
      const estimate = kind === "chat" ? tokenCost(lastUsage, rates)
        : kind === "image" && outputImages > 0 && priceSnapshot?.unitCostCny != null ? Number((priceSnapshot.unitCostCny * outputImages).toFixed(10)) : null;
      await write(id, { status, endedAt: new Date(), durationMs: Date.now() - started, model: responseModel,
        vendorRequestId: vendorId, providerResponseId, ...lastUsage, outputImages, supplierCostEstimateCny: estimate,
        costBasis: estimate == null ? "unknown" : priceSnapshot?.costBasis || "configured_rate", rateSnapshot: priceSnapshot || null,
        errorCode, finishReason, ...extra });
    }
    let response;
    try { response = await fetchImpl(url, options); }
    catch (error) { await finish("outcome_unknown", { errorCode: safeId(error.name), httpStatus: null }); throw error; }
    vendorId = safeId(response.headers.get("x-request-id") || response.headers.get("x-tt-logid") || response.headers.get("request-id") || "");
    const httpStatus = response.status;
    const isSSE = /text\/event-stream/i.test(response.headers.get("content-type") || "");
    if (!response.ok) {
      // HTTP rejection is known immediately, even if a retry discards the body.
      await finish(httpStatus >= 500 ? "outcome_unknown" : "rejected", { httpStatus });
      Object.defineProperty(response, "modelCallId", { value: id });
      return response;
    }
    if (!response.body) { await finish("outcome_unknown", { httpStatus, errorCode: "EMPTY_BODY" }); return response; }
    const reader = response.body.getReader();
    const tracked = new Response(new ReadableStream({
      async pull(controller) {
        try {
          const next = await reader.read();
          if (cancelled) return;
          if (!next.done) { feed(decoder.decode(next.value, { stream: true }), isSSE); controller.enqueue(next.value); return; }
          feed(decoder.decode(), isSSE);
          if (isSSE) feed("\n", true);
          else if (!tooLarge) { try { consumeObject(JSON.parse(json)); } catch { errorCode = "INVALID_JSON"; } }
          const valid = !errorCode && (isSSE ? streamDone || !!finishReason : kind !== "image" || outputImages > 0);
          await finish(valid ? (truncated ? "partial" : "succeeded") : "outcome_unknown", { httpStatus, responseTooLarge: tooLarge });
          controller.close();
        } catch (error) { await finish("outcome_unknown", { httpStatus, errorCode: safeId(error.name) }); controller.error(error); }
      },
      async cancel(reason) { cancelled = true; await finish("outcome_unknown", { httpStatus, errorCode: "CONSUMER_CANCELLED" }); await reader.cancel(reason); },
    }), { status: response.status, statusText: response.statusText, headers: response.headers });
    Object.defineProperty(tracked, "modelCallId", { value: id });
    return tracked;
  }
  return { fetch: fetchTracked, charge, cached };
}
module.exports = { COLLECTION, createModelCallLedger, usageOf, tokenCost, orderIdOf, providerOf };
