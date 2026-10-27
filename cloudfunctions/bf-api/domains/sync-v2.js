"use strict";
const crypto = require("crypto");
const KINDS = new Set(["conversation", "message", "memory", "file"]);
const UUID = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
function digest(value) { return crypto.createHash("sha256").update(value).digest("hex"); }
function canonical(value) {
  if (Array.isArray(value)) return "[" + value.map(canonical).join(",") + "]";
  if (value && typeof value === "object") return "{" + Object.keys(value).sort().map(k => JSON.stringify(k) + ":" + canonical(value[k])).join(",") + "}";
  return JSON.stringify(value);
}
function normalizeRecord(raw) {
  if (!raw || !KINDS.has(raw.kind) || !UUID.test(raw.refId || "")) throw new Error("SYNC_INVALID_RECORD");
  const payload = typeof raw.payload === "string" ? JSON.parse(raw.payload) : raw.payload;
  if (!payload || Array.isArray(payload) || typeof payload !== "object" || payload.id !== raw.refId) throw new Error("SYNC_INVALID_PAYLOAD");
  if (raw.kind === "conversation" && payload.messages) throw new Error("SYNC_MESSAGES_MUST_BE_SEPARATE");
  if (raw.kind === "message" && !UUID.test(payload.conversationId || "")) throw new Error("SYNC_INVALID_PARENT");
  const serialized = canonical(payload);
  if (Buffer.byteLength(serialized) > 240 * 1024) throw new Error("SYNC_RECORD_TOO_LARGE");
  return { kind: raw.kind, refId: raw.refId, payload: serialized, hash: digest(serialized),
    parentId: raw.kind === "message" ? payload.conversationId : "",
    baseVersion: Number.isSafeInteger(raw.baseVersion) && raw.baseVersion >= 0 ? raw.baseVersion : 0,
    deleted: payload.isDeleted === true };
}
function key(owner, kind, id) { return digest(owner + "|" + kind + "|" + id).slice(0, 40); }
function publicRow(row) {
  return { kind: row.kind, refId: row.refId, payload: row.payload, version: row.version,
    revision: row.revision, hash: row.hash, deleted: row.deleted === true };
}
function createSyncService({ db, collection = "bf_sync_v2", metaCollection = "bf_sync_meta", assetStore }) {
  async function head(owner, tx = db) {
    const ref = tx.collection(metaCollection).doc("v2_" + digest(owner).slice(0, 32));
    const data = ((await ref.get()).data || [])[0];
    return { ref, revision: Number(data && data.revision || 0) };
  }
  return {
    async push(owner, inputs) {
      if (!Array.isArray(inputs) || inputs.length > 25) throw new Error("SYNC_BATCH_TOO_LARGE");
      const records = inputs.map(normalizeRecord);
      // Never publish references to another account's objects or an unverified upload.
      const ids = [];
      for (const record of records) {
        const payload = JSON.parse(record.payload);
        for (const asset of payload.assets || []) ids.push(asset.id);
        if (payload.asset) ids.push(payload.asset.id);
      }
      if (ids.length && assetStore) await assetStore.verifyReferences(owner, ids);
      return db.runTransaction(async tx => {
        const counter = await head(owner, tx);
        let revision = counter.revision;
        const acknowledged = [], conflicts = [];
        // Read parents/records before writes, so transaction semantics stay predictable.
        const current = new Map();
        for (const record of records) {
          for (const [kind, id] of [[record.kind, record.refId], ...(record.parentId ? [["conversation", record.parentId]] : [])]) {
            const idKey = key(owner, kind, id);
            if (!current.has(idKey)) current.set(idKey, ((await tx.collection(collection).doc(idKey).get()).data || [])[0] || null);
          }
        }
        for (const record of records) {
          const id = key(owner, record.kind, record.refId);
          const existing = current.get(id);
          const parent = record.parentId ? current.get(key(owner, "conversation", record.parentId)) : null;
          if (parent && parent.deleted) {
            acknowledged.push({ kind: record.kind, refId: record.refId, version: 0, hash: record.hash, discarded: "parent_deleted" });
            continue;
          }
          if (existing && existing.hash === record.hash) { acknowledged.push(publicRow(existing)); continue; }
          if (existing && existing.deleted && !record.deleted) { conflicts.push(publicRow(existing)); continue; }
          if (existing && existing.version !== record.baseVersion && !record.deleted) { conflicts.push(publicRow(existing)); continue; }
          revision++;
          const row = { accountId: owner, kind: record.kind, refId: record.refId,
            payload: record.payload, parentId: record.parentId, hash: record.hash, deleted: record.deleted,
            version: (existing ? existing.version : 0) + 1, revision, committedAt: Date.now() };
          await tx.collection(collection).doc(id).set(row);
          current.set(id, row);
          acknowledged.push(publicRow(row));
        }
        if (revision !== counter.revision) await counter.ref.set({ accountId: owner, protocol: 2, revision });
        return { acknowledged, conflicts, revision };
      });
    },
    async pull(owner, rawSince, rawWatermark, rawAfter, rawLimit) {
      const integer = (value, fallback = 0) => Number.isSafeInteger(Number(value)) && Number(value) >= 0 ? Number(value) : fallback;
      const since = integer(rawSince), after = Math.max(since, integer(rawAfter));
      const currentHead = (await head(owner)).revision;
      const watermark = rawWatermark == null ? currentHead : Math.min(integer(rawWatermark), currentHead);
      if (since > currentHead) throw new Error("SYNC_CURSOR_AHEAD");
      const limit = Math.max(1, Math.min(100, integer(rawLimit, 50)));
      const q = db.command;
      const rows = ((await db.collection(collection).where({ accountId: owner,
        revision: q.gt(after).and(q.lte(watermark)) }).orderBy("revision", "asc").limit(limit + 1).get()).data || []);
      const page = rows.slice(0, limit);
      return { items: page.map(publicRow), watermark, hasMore: rows.length > limit,
        after: page.length ? page[page.length - 1].revision : after };
    },
    async deleteConversation(owner, id) {
      return this.push(owner, [{ kind: "conversation", refId: id, payload: { id, isDeleted: true } }]);
    },
  };
}
module.exports = { createSyncService, normalizeRecord, canonical, key, publicRow };
