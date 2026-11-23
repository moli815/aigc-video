"use strict";
// 2026-11-22：体积超限要说人话。旧文案「这次内容没有完整保存，请检查输入后重试」既不提
// 体积也不提上限，用户只会拿同一张图反复重试。这里把实际体积与上限都报出来。
function toMb(bytes) { return Math.max(1, Math.round(Number(bytes || 0) / (1024 * 1024))); }
function assetSizeMessage(error) {
  const limit = toMb((error && error.limitBytes) || 24 * 1024 * 1024);
  const actual = Number(error && error.actualBytes);
  return Number.isFinite(actual) && actual > 0
    ? `这张图约 ${toMb(actual)}MB，超过 ${limit}MB 上限；请压缩后或换一张再发。`
    : `这张图超过 ${limit}MB 上限，请压缩后或换一张再发。`;
}
function createFoundationHandler({ requireMember, readJsonBody, syncV2, eventService, assetStore, sendJson, sendError, logSafe, currentRequestId, afterSync }) {
return async function handleFoundation(req, res, url) {
  const auth = await requireMember(req, res);
  if (!auth) return;
  const path = url.pathname;
  const body = req.method === "GET" ? {} : await readJsonBody(req);
  try {
    if (path === "/api/sync/v2/push") {
      const result = await syncV2.push(auth.sub, body.records);
      if (afterSync) {
        try { await afterSync(auth.sub, body.records, result); }
        catch { logSafe({ tag: "optional_sync_index_failed", requestId: currentRequestId() }); }
      }
      return sendJson(res, 200, { ok: true, ...result });
    }
    if (path === "/api/sync/v2/pull") {
      const q = url.searchParams;
      return sendJson(res, 200, { ok: true, ...await syncV2.pull(auth.sub,
        q.get("since") || 0, q.has("watermark") ? q.get("watermark") : null, q.get("after") || 0, q.get("limit") || 50) });
    }
    if (path === "/api/events") {
      const acceptedIds = await eventService.receive(auth.sub, body.events);
      return sendJson(res, 200, { ok: true, acceptedIds });
    }
    if (path === "/api/assets/prepare") return sendJson(res, 200, { ok: true, ...await assetStore.prepare(auth.sub, body) });
    if (path === "/api/assets/commit") return sendJson(res, 200, { ok: true, asset: await assetStore.commit(auth.sub, body.id) });
    if (path === "/api/assets/urls") return sendJson(res, 200, { ok: true, items: await assetStore.sign(auth.sub, body.ids) });
  } catch (error) {
    const code = String(error && error.message || "");
    const input = /^(INVALID_|SYNC_(INVALID|DUPLICATE|BATCH|RECORD|MESSAGES|CURSOR)|ASSET_(SIZE_LIMIT|TYPE_|INTEGRITY|PIXEL|METADATA))/.test(code);
    const missing = code === "ASSET_NOT_FOUND";
    const diagnosticCode = /^[A-Z][A-Z0-9_]{0,79}$/.test(code) ? code :
      /^[A-Z][A-Z0-9_]{0,79}$/.test(String(error && error.code || "")) ? error.code : "UNCLASSIFIED";
    logSafe({ tag: "foundation_failed", stage: path, code: input || missing ? code : "STORAGE_UNAVAILABLE",
      diagnosticCode, errorType: String(error && error.name || "Error").slice(0, 40), requestId: currentRequestId() });
    return sendError(res, input ? 422 : missing ? 404 : 503,
      input ? "CLOUD_INPUT_INVALID" : missing ? "ASSET_NOT_FOUND" : "STORAGE_UNAVAILABLE",
      input ? (code === "ASSET_SIZE_LIMIT" ? assetSizeMessage(error) : "这次内容没有完整保存，请检查输入后重试。")
        : missing ? "没有找到可访问的文件。" : "云端保存暂未完成，本机内容已保留，请稍后重试保存。");
  }
}

}
module.exports = { createFoundationHandler };
