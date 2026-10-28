"use strict";
const crypto = require("crypto");
const MAX_ASSET_BYTES = 24 * 1024 * 1024;
const MIME_EXT = Object.freeze({ "image/png": "png", "image/jpeg": "jpg", "image/webp": "webp",
  "image/gif": "gif", "application/pdf": "pdf", "text/plain": "txt", "text/markdown": "md",
  "text/csv": "csv", "application/json": "json", "application/zip": "zip", "application/octet-stream": "bin",
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx",
  "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "xlsx",
  "application/vnd.openxmlformats-officedocument.presentationml.presentation": "pptx" });
function hash(data) { return crypto.createHash("sha256").update(data).digest("hex"); }
function assetKey(owner, sha) { return hash(owner + ":" + sha).slice(0, 40); }
function assetSpec(raw) {
  if (!raw || !/^[a-f0-9]{64}$/.test(raw.sha256 || "")) throw new Error("INVALID_ASSET_HASH");
  if (!Number.isSafeInteger(raw.byteCount) || raw.byteCount < 1 || raw.byteCount > MAX_ASSET_BYTES) throw new Error("ASSET_SIZE_LIMIT");
  if (!MIME_EXT[raw.mime]) throw new Error("ASSET_TYPE_UNSUPPORTED");
  return { sha256: raw.sha256, byteCount: raw.byteCount, mime: raw.mime };
}
function imageInfo(bytes) {
  if (bytes.length >= 24 && bytes.subarray(0, 8).equals(Buffer.from([137,80,78,71,13,10,26,10]))) {
    return { mime: "image/png", width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20) };
  }
  if (bytes[0] === 255 && bytes[1] === 216) return { mime: "image/jpeg" };
  if (bytes.toString("ascii", 0, 3) === "GIF") return { mime: "image/gif" };
  if (bytes.toString("ascii", 0, 4) === "RIFF" && bytes.toString("ascii", 8, 12) === "WEBP") return { mime: "image/webp" };
  return null;
}
function descriptor(row) {
  const out = { id: row._id, sha256: row.sha256, mime: row.mime, byteCount: row.byteCount };
  if (row.width) out.width = row.width;
  if (row.height) out.height = row.height;
  return out;
}
function validateBytes(row, bytes) {
  if (!Buffer.isBuffer(bytes) || bytes.length !== row.byteCount || hash(bytes) !== row.sha256) throw new Error("ASSET_INTEGRITY_FAILED");
  const info = imageInfo(bytes);
  if (row.mime.startsWith("image/") && (!info || info.mime !== row.mime)) throw new Error("ASSET_TYPE_MISMATCH");
  if (info && info.width && (!(info.width > 0 && info.height > 0) || info.width * info.height > 40e6)) throw new Error("ASSET_PIXEL_LIMIT");
  return info || {};
}
async function boundedBytes(url, limit, fetcher = fetch) {
  const parsed = new URL(url);
  if (parsed.protocol !== "https:" || parsed.username || parsed.password || (parsed.port && parsed.port !== "443") ||
      ![".myqcloud.com", ".tcloudbase.com", ".volces.com", ".byteimg.com", ".bytecdn.cn"].some(s => parsed.hostname.endsWith(s))) throw new Error("ASSET_URL_REJECTED");
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 20000);
  try {
    const response = await fetcher(url, { signal: controller.signal, redirect: "error" });
    if (!response.ok || Number(response.headers.get("content-length") || 0) > limit || !response.body) throw new Error("ASSET_DOWNLOAD_FAILED");
    const reader = response.body.getReader(), parts = [];
    let bytes = 0;
    try {
      while (true) {
        const item = await reader.read();
        if (item.done) break;
        bytes += item.value.byteLength;
        if (bytes > limit) { await reader.cancel(); throw new Error("ASSET_SIZE_LIMIT"); }
        parts.push(Buffer.from(item.value));
      }
    } finally { reader.releaseLock(); }
    return Buffer.concat(parts);
  } finally { clearTimeout(timer); }
}
// Object ACL overrides the legacy bucket's public-read default. Never upload
// account assets with the SDK's default inherited ACL.
async function uploadPrivate(app, cloudPath, bytes, fetcher = fetch) {
  const metadata = await app.getUploadMetadata({ cloudPath });
  const d = metadata.data || {};
  if (!d.url || !d.fileId || !d.authorization) throw new Error("ASSET_UPLOAD_UNAVAILABLE");
  const url = new URL(d.url);
  if (url.protocol !== "https:" || url.username || url.password ||
      !url.hostname.endsWith(".myqcloud.com") || (url.port && url.port !== "443")) throw new Error("ASSET_URL_REJECTED");
  const controller = new AbortController(), timer = setTimeout(() => controller.abort(), 30000);
  try {
    const response = await fetcher(url.href, { method: "PUT", redirect: "error", signal: controller.signal,
      headers: { Signature: d.authorization, authorization: d.authorization,
        "x-cos-security-token": d.token || "", "x-cos-meta-fileid": d.cosFileId || "",
        key: encodeURIComponent(cloudPath), "x-cos-acl": "private" }, body: bytes });
    if (!response.ok) throw new Error("ASSET_UPLOAD_FAILED");
    // COS normally returns an empty body. Reject an XML error without logging it.
    const body = await response.text();
    if (body.includes("<Error>")) throw new Error("ASSET_UPLOAD_FAILED");
    return { fileID: d.fileId };
  } finally { clearTimeout(timer); }
}
function createAssetStore({ db, app, collection = "bf_assets", fetcher = fetch }) {
  const col = () => db.collection(collection);
  async function owned(owner, id) {
    if (!/^[a-f0-9]{40}$/.test(String(id))) throw new Error("INVALID_ASSET_ID");
    const row = ((await col().doc(id).get()).data || [])[0];
    if (!row || row.accountId !== owner) throw new Error("ASSET_NOT_FOUND");
    return row;
  }
  async function ensurePending(owner, spec) {
    const id = assetKey(owner, spec.sha256);
    let row = ((await col().doc(id).get()).data || [])[0];
    if (!row) {
      row = { _id: id, accountId: owner, ...spec, state: "pending", createdAt: Date.now(),
        cloudPath: `user/${hash(owner).slice(0, 24)}/assets/${spec.sha256}.${MIME_EXT[spec.mime]}` };
      try { await col().add(row); }
      catch (error) {
        row = ((await col().doc(id).get()).data || [])[0];
        if (!row || row.accountId !== owner) throw error;
      }
    }
    if (row.mime !== spec.mime || row.byteCount !== spec.byteCount) throw new Error("ASSET_METADATA_CONFLICT");
    return row;
  }
  async function markReady(row, fileID, bytes) {
    const info = validateBytes(row, bytes);
    const patch = { state: "ready", privateACL: true, fileID, verifiedAt: Date.now(), updatedAt: Date.now(),
      ...(info.width ? { width: info.width, height: info.height } : {}) };
    await col().doc(row._id).update(patch);
    return descriptor({ ...row, ...patch });
  }
  return {
    async prepare(owner, raw) {
      const row = await ensurePending(owner, assetSpec(raw));
      if (row.state === "ready" && row.privateACL === true) return { ready: true, asset: descriptor(row) };
      const metadata = await app.getUploadMetadata({ cloudPath: row.cloudPath });
      const data = metadata.data || {};
      const fileID = data.fileId || data.fileID;
      if (!fileID || !data.url) throw new Error("ASSET_UPLOAD_UNAVAILABLE");
      await col().doc(row._id).update({ fileID, updatedAt: Date.now() });
      return { ready: false, assetId: row._id, upload: { url: data.url, token: data.token || "",
        authorization: data.authorization || "", cloudPath: row.cloudPath, cosFileId: data.cosFileId || "" } };
    },
    async commit(owner, id) {
      const row = await owned(owner, id);
      if (row.state === "ready" && row.privateACL === true) return descriptor(row);
      if (!row.fileID) throw new Error("ASSET_UPLOAD_INCOMPLETE");
      const signed = await app.getTempFileURL({ fileList: [{ fileID: row.fileID, maxAge: 60, urlType: "COS_URL" }] });
      const url = signed.fileList && signed.fileList[0] && signed.fileList[0].tempFileURL;
      if (!url) throw new Error("ASSET_URL_FAILED");
      const bytes = await boundedBytes(url, row.byteCount, fetcher);
      validateBytes(row, bytes);
      const uploaded = await uploadPrivate(app, row.cloudPath, bytes, fetcher);
      return markReady(row, uploaded.fileID, bytes);
    },
    async archive(owner, bytes, mime) {
      const spec = assetSpec({ sha256: hash(bytes), byteCount: bytes.length, mime });
      const row = await ensurePending(owner, spec);
      if (row.state === "ready" && row.privateACL === true) return descriptor(row);
      validateBytes(row, bytes);
      const uploaded = await uploadPrivate(app, row.cloudPath, bytes, fetcher);
      if (!uploaded.fileID) throw new Error("ASSET_UPLOAD_INCOMPLETE");
      return markReady(row, uploaded.fileID, bytes);
    },
    async sign(owner, ids) {
      if (!Array.isArray(ids) || ids.length > 25) throw new Error("INVALID_ASSET_BATCH");
      const rows = await Promise.all([...new Set(ids)].map(id => owned(owner, id)));
      if (rows.some(row => row.state !== "ready")) throw new Error("ASSET_NOT_READY");
      if (!rows.length) return [];
      // Migrate legacy inherited-ACL objects on first authenticated access.
      // Sequential byte buffers avoid multiplying the function's memory budget.
      for (const row of rows) if (row.privateACL !== true) {
        const old = await app.getTempFileURL({ fileList: [{ fileID: row.fileID, maxAge: 60, urlType: "COS_URL" }] });
        const url = old.fileList && old.fileList[0] && old.fileList[0].tempFileURL;
        if (!url) throw new Error("ASSET_URL_FAILED");
        const bytes = await boundedBytes(url, row.byteCount, fetcher);
        validateBytes(row, bytes);
        const uploaded = await uploadPrivate(app, row.cloudPath, bytes, fetcher);
        await markReady(row, uploaded.fileID, bytes);
        row.fileID = uploaded.fileID; row.privateACL = true;
      }
      const response = await app.getTempFileURL({ fileList: rows.map(row => ({ fileID: row.fileID, maxAge: 900, urlType: "COS_URL" })) });
      return rows.map(row => {
        const match = (response.fileList || []).find(item => item.fileID === row.fileID);
        if (!match || !(match.tempFileURL || match.download_url)) throw new Error("ASSET_URL_FAILED");
        return { id: row._id, url: match.tempFileURL || match.download_url, expiresIn: 900 };
      });
    },
    async verifyReferences(owner, refs) {
      const checked = new Map();
      for (const ref of refs) {
        const id = typeof ref === "string" ? ref : ref.id;
        const row = checked.get(id) || await owned(owner, id);
        checked.set(id, row);
        if (row.state !== "ready") throw new Error("ASSET_NOT_READY");
        if (typeof ref !== "string" && (ref.sha256 !== row.sha256 || ref.mime !== row.mime || ref.byteCount !== row.byteCount)) throw new Error("ASSET_METADATA_CONFLICT");
      }
    },
  };
}
module.exports = { uploadPrivate, createAssetStore, assetSpec, assetKey, imageInfo, validateBytes, descriptor, boundedBytes, MAX_ASSET_BYTES };
