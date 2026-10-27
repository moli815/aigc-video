"use strict";
function createFoundationHandler({ requireMember, readJsonBody, syncV2, eventService, assetStore, sendJson, sendError, logSafe, currentRequestId }) {
return async function handleFoundation(req, res, url) {
  const auth = await requireMember(req, res);
  if (!auth) return;
  const path = url.pathname;
  const body = req.method === "GET" ? {} : await readJsonBody(req);
  try {
    if (path === "/api/sync/v2/push") return sendJson(res, 200, { ok: true, ...await syncV2.push(auth.sub, body.records) });
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
    logSafe({ tag: "foundation_failed", stage: path, code: input || missing ? code : "STORAGE_UNAVAILABLE", requestId: currentRequestId() });
    return sendError(res, input ? 422 : missing ? 404 : 503,
      input || missing ? code : "STORAGE_UNAVAILABLE",
      input ? "这份文件暂时无法保存，请检查文件格式和大小。" : missing ? "没有找到可访问的文件。" : "云端保存暂未完成，本机内容已保留，请稍后重试保存。");
  }
}

}
module.exports = { createFoundationHandler };
