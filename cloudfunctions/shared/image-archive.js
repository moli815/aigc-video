"use strict";
const { createAssetStore, boundedBytes, imageInfo, MAX_ASSET_BYTES } = require("./asset-store");
const { documentOf } = require("./document-store");

/// Recovery processes only already-generated results. This module has no model API.
function createImageArchiver({ db, app, fetcher = fetch }) {
  const assets = createAssetStore({ db, app, fetcher });
  return {
    async archive(row) {
      if (!row || !row._id || row.state !== "done" || !row.accountId || !row.url) return { skipped: true };
      if (row.archiveState === "ready" && row.asset) return { asset: row.asset, archiveState: "ready" };
      const ref = db.collection("bf_image_jobs").doc(row._id);
      const claim = await db.runTransaction(async tx => {
        const locked = tx.collection("bf_image_jobs").doc(row._id);
        const fresh = documentOf(await locked.get());
        if (!fresh || fresh.state !== "done") return { skipped: true };
        if (fresh.archiveState === "ready" && fresh.asset) return { asset: fresh.asset, archiveState: "ready" };
        if (Number(fresh.archiveLeaseUntil || 0) > Date.now()) return { skipped: true };
        await locked.update({ archiveLeaseUntil: Date.now() + 120000 });
        return { row: fresh };
      });
      if (!claim.row) return claim;
      row = claim.row;
      try {
        const bytes = await boundedBytes(row.url, MAX_ASSET_BYTES, fetcher);
        const info = imageInfo(bytes);
        if (!info) throw new Error("ASSET_TYPE_MISMATCH");
        const asset = await assets.archive(row.accountId, bytes, info.mime);
        await ref.update({ asset, archiveState: "ready", archivedAt: Date.now(), archiveError: "", archiveLeaseUntil: 0 });
        return { asset, archiveState: "ready" };
      } catch {
        const attempts = Number(row.archiveAttempts || 0) + 1;
        await ref.update({ archiveState: attempts >= 12 ? "needs_attention" : "pending",
          archiveAttempts: attempts, archiveError: "ARCHIVE_RETRY_REQUIRED", archiveAttemptedAt: Date.now(), archiveLeaseUntil: 0 });
        return { archiveState: attempts >= 12 ? "needs_attention" : "pending" };
      }
    },
    async retryBatch(limit = 3) {
      const jobs = ((await db.collection("bf_image_jobs").where({ state: "done", archiveState: "pending" })
        .orderBy("ts", "asc").limit(Math.max(1, Math.min(limit, 5))).get()).data || []);
      const result = [];
      for (const row of jobs) result.push(await this.archive(row));
      return { checked: result.length, ready: result.filter(x => x.archiveState === "ready").length };
    },
  };
}
module.exports = { createImageArchiver };
