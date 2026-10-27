"use strict";
const { documentOf } = require("./document-store");

// A request ID identifies a paid operation, not a five-minute response cache.
// Elapsed wall time never proves that an upstream operation failed or was free.
async function claimImageJob({ db, key, rid, accountId, now = Date.now() }) {
  try {
    return await db.runTransaction(async tx => {
      const ref = tx.collection("bf_image_jobs").doc(key);
      const row = documentOf(await ref.get());
      if (row && String(row.accountId || "") !== String(accountId)) return { state: "unavailable" };
      if (row && row.state === "done") return { state: "done", url: row.url,
        kind: row.kind || "", result: row.result || null, model: row.model || "", asset: row.asset || null };
      if (row && row.state !== "failed") return { state: "busy", confirming: row.state === "uncertain" };
      // Only a definitive preflight/provider rejection can be claimed again.
      await ref.set({ accountId, clientRequestId: rid, state: "processing", ts: now,
        leanSec: Math.floor(now / 1000), costCommitted: false });
      return { state: "new" };
    });
  } catch { return { state: "unavailable" }; }
}
module.exports = { claimImageJob };
