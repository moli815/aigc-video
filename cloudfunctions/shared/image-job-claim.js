"use strict";
const { documentOf } = require("./document-store");

// A request ID identifies a paid operation, not a five-minute response cache.
// Elapsed wall time never proves that an upstream operation failed or was free.
async function claimImageJob({ db, key, rid, accountId, referenceFingerprint,copyFingerprint, replayOnly = false, now = Date.now() }) {
  if(referenceFingerprint!==undefined&&!/^[a-f0-9]{64}$/.test(referenceFingerprint))return {state:'unavailable'};
  if(copyFingerprint!==undefined&&!/^[a-f0-9]{64}$/.test(copyFingerprint))return {state:'unavailable'};
  try {
    return await db.runTransaction(async tx => {
      const ref = tx.collection("bf_image_jobs").doc(key);
      const row = documentOf(await ref.get());
      if (row && String(row.accountId || "") !== String(accountId)) return { state: "unavailable" };
      if(row&&(row.referenceFingerprint!==undefined||referenceFingerprint!==undefined)&&row.referenceFingerprint!==referenceFingerprint)return {state:'conflict'};
      if(row&&(row.copyFingerprint!==undefined||copyFingerprint!==undefined)&&row.copyFingerprint!==copyFingerprint&&!(row.state==='done'&&copyFingerprint===undefined))return{state:'conflict'};
      if (row && row.state === "done") return { state: "done", url: row.url,
        kind: row.kind || "", result: row.result || null, model: row.model || "", asset: row.asset || null };
      if (replayOnly) {
        if (row?.state === "processing" || row?.state === "uncertain") {
          return { state: "busy", confirming: row.state === "uncertain" };
        }
        return { state: "unclaimed" };
      }
      if(row?.state==='copy_rejected')return{state:'copy_rejected'};
      if(copyFingerprint&&row?.copyInput)return{state:'resume_copy',copyInput:row.copyInput};
      if (row && row.state !== "failed") return { state: "busy", confirming: row.state === "uncertain" };
      // Only a definitive preflight/provider rejection can be claimed again.
      await ref.set({ accountId, clientRequestId: rid, state: "processing", ts: now,
        leanSec: Math.floor(now / 1000), costCommitted: false,
        ...(referenceFingerprint!==undefined?{referenceFingerprint}:{}) });
      if(copyFingerprint)await ref.update({copyFingerprint});
      return { state: "new" };
    });
  } catch { return { state: "unavailable" }; }
}
module.exports = { claimImageJob };
