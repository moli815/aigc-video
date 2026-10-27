"use strict";
const test = require("node:test"), assert = require("node:assert/strict"), crypto = require("crypto");
const { memoryDatabase } = require("./foundation-fixture");
const { createSyncService, normalizeRecord } = require("../cloudfunctions/bf-api/domains/sync-v2");
const { normalizeEvent, createEventService } = require("../cloudfunctions/bf-api/domains/events");
const { createAssetStore, assetSpec, assetKey, boundedBytes } = require("../cloudfunctions/shared/asset-store");
const { createImageArchiver } = require("../cloudfunctions/shared/image-archive");
const id = "B665E22F-B174-4C75-931A-962EC43FE3E1";
const mid = "B665E22F-B174-4C75-931A-962EC43FE3E2";
const record = (kind, refId, payload, baseVersion = 0) => ({ kind, refId, payload: { id: refId, ...payload }, baseVersion });
test("sync revisions use commit order rather than device clocks", async () => {
  const service = createSyncService({ db: memoryDatabase() });
  await service.push("A", [record("conversation", id, { title: "first", updatedAt: 9999999999999 })]);
  const first = await service.pull("A", 0, null, 0, 1);
  await service.push("A", [record("message", mid, { conversationId: id, text: "late", createdAt: 1 })]);
  assert.equal((await service.pull("A", first.watermark, null, 0, 50)).items[0].refId, mid);
});
test("a pinned pagination watermark excludes later commits until next sync", async () => {
  const service = createSyncService({ db: memoryDatabase() });
  await service.push("A", [record("conversation", id, { title: "old" })]);
  const page = await service.pull("A", 0, null, 0, 1);
  await service.push("A", [record("message", mid, { conversationId: id, text: "new" })]);
  assert.equal((await service.pull("A", 0, page.watermark, page.after, 1)).items.length, 0);
  assert.equal((await service.pull("A", page.watermark, null, 0, 10)).items.length, 1);
});
test("concurrent device writes get distinct committed revisions and survive", async () => {
  const service = createSyncService({ db: memoryDatabase() });
  await Promise.all([service.push("A", [record("conversation", id, { title: "A" })]),
    service.push("A", [record("memory", mid, { content: "B" })])]);
  const page = await service.pull("A", 0, null, 0, 10);
  assert.equal(page.items.length, 2); assert.equal(new Set(page.items.map(x => x.revision)).size, 2);
  assert.equal((await service.pull("B", 0, null, 0, 10)).items.length, 0);
});
test("stale overwrite is a conflict, identical replay costs no revision", async () => {
  const service = createSyncService({ db: memoryDatabase() });
  const input = record("conversation", id, { title: "original" });
  await service.push("A", [input]);
  assert.equal((await service.push("A", [input])).revision, 1);
  const reply = await service.push("A", [record("conversation", id, { title: "stale" })]);
  assert.equal(reply.conflicts[0].version, 1); assert.equal(reply.revision, 1);
});
test("conversation tombstone rejects resurrection and discards stale child uploads", async () => {
  const service = createSyncService({ db: memoryDatabase() });
  await service.push("A", [record("conversation", id, { title: "x" })]);
  await service.deleteConversation("A", id);
  assert.equal((await service.push("A", [record("conversation", id, { title: "resurrection" }, 2)])).conflicts.length, 1);
  const child = await service.push("A", [record("message", mid, { conversationId: id, text: "old" })]);
  assert.equal(child.acknowledged[0].discarded, "parent_deleted");
});
test("large snapshots and broken JSON are rejected rather than sliced", () => {
  assert.throws(() => normalizeRecord({ kind: "message", refId: mid, payload: "{broken" }));
  assert.throws(() => normalizeRecord(record("conversation", id, { messages: [] })), /SEPARATE/);
  assert.throws(() => normalizeRecord(record("message", mid, { conversationId: id, text: "字".repeat(100000) })), /TOO_LARGE/);
});

test("UUID casing cannot create duplicate sync identities", async () => {
  const service = createSyncService({ db: memoryDatabase() });
  await service.push("A", [record("conversation", id.toLowerCase(), { title: "same" })]);
  const replay = await service.push("A", [record("conversation", id, { title: "same" })]);
  assert.equal(replay.revision, 1);
  assert.equal((await service.pull("A", 0, null, 0, 50)).items.length, 1);
});

test("children require an owned parent; parent and child can arrive in either batch order", async () => {
  const service = createSyncService({ db: memoryDatabase() });
  await assert.rejects(service.push("A", [record("message", mid, {conversationId:id, text:"orphan"})]), /INVALID_PARENT/);
  const result = await service.push("A", [record("message", mid, {conversationId:id, text:"child"}), record("conversation", id, {title:"parent"})]);
  assert.equal(result.acknowledged.length, 2);
  await assert.rejects(service.push("B", [record("message", mid, {conversationId:id, text:"foreign"})]), /INVALID_PARENT/);
});

test("sync validates variant ownership and rejects repeated record IDs before committing", async () => {
  let seen = [];
  const service = createSyncService({ db: memoryDatabase(), assetStore: { async verifyReferences(owner, refs) { seen = refs; throw Error("ASSET_NOT_FOUND"); } } });
  const asset = {id:"a".repeat(40),variants:{thumbnail:{id:"b".repeat(40)}}};
  await assert.rejects(service.push("A", [record("message", mid, {conversationId:id,assets:[asset]})]), /NOT_FOUND/);
  assert.deepEqual(seen.map(x=>x.id), ["a".repeat(40),"b".repeat(40)]);
  const same = record("conversation", id, {title:"x"});
  await assert.rejects(service.push("A", [same,same]), /DUPLICATE_RECORD/);
  assert.equal((await service.pull("A",0,null,0,50)).watermark,0);
});
test("failed asset verification does not advance sync cursor or publish reference", async () => {
  const service = createSyncService({ db: memoryDatabase(), assetStore: { async verifyReferences() { throw new Error("ASSET_NOT_FOUND"); } } });
  await assert.rejects(service.push("A", [record("message", mid, { conversationId: id, assets: [{ id: "foreign" }] })]));
  assert.equal((await service.pull("A", 0, null, 0, 5)).watermark, 0);
});
test("diagnostic allowlist drops raw prompts, credentials and headers", () => {
  const event = normalizeEvent({ eventId: "test_1234567890", stage: "archive", errorCode: "STORAGE_DOWN",
    durationMs: "2400", prompt: "secret", reason: "customer", token: "private", headers: { Authorization: "secret" } });
  assert.equal(event.durationMs, 2400); assert.equal(event.prompt, undefined); assert.equal(event.reason, undefined);
  assert.equal(event.token, undefined); assert.equal(event.headers, undefined);
});
test("diagnostic acknowledgement is durable, idempotent and account scoped", async () => {
  const db = memoryDatabase(), service = createEventService({ db });
  const event = { eventId: "test_1234567890", requestId: "r1", errorCode: "FAILED", stage: "save" };
  await service.receive("A", [event]); await service.receive("A", [event]); await service.receive("B", [event]);
  const rows = (await db.collection("bf_tool_events").get()).data;
  assert.equal(rows.length, 2); assert.equal(rows[0].requestId, "r1"); assert.equal(rows[0].errorCode, "FAILED");
});
test("event persistence failure is never acknowledged", async () => {
  const service = createEventService({ db: { collection() { return { doc() { return { async get() { throw new Error("offline"); } }; } }; } } });
  await assert.rejects(service.receive("A", [{ eventId: "test_1234567890" }]), /offline/);
});
test("asset archive deduplicates within an account and blocks cross-account signing", async () => {
  const db = memoryDatabase(); let uploads = 0;
  const bytes = Buffer.from([255,216,1,2,3]);
  const app = { async uploadFile({cloudPath}) { uploads++; return { fileID: "cloud://bucket/" + cloudPath }; },
    async getTempFileURL({fileList}) { return { fileList: fileList.map(x => ({ fileID: x.fileID, tempFileURL: "https://bucket.myqcloud.com/object?signature=private" })) }; } };
  const service = createAssetStore({ db, app });
  const first = await service.archive("A", bytes, "image/jpeg");
  assert.deepEqual(await service.archive("A", bytes, "image/jpeg"), first); assert.equal(uploads, 1);
  await service.archive("B", bytes, "image/jpeg"); assert.equal(uploads, 2);
  await assert.rejects(service.sign("B", [first.id]), /NOT_FOUND/);
  assert.equal((await service.sign("A", [first.id]))[0].id, first.id);
  assert.ok(!JSON.stringify(first).includes("signature"));
});
test("asset integrity failure leaves upload pending and content hash keys are tenant scoped", async () => {
  const sha = crypto.createHash("sha256").update("bytes").digest("hex");
  assert.notEqual(assetKey("A", sha), assetKey("B", sha));
  assert.throws(() => assetSpec({ sha256: sha, byteCount: 30e6, mime: "image/png" }), /LIMIT/);
  const db = memoryDatabase(), service = createAssetStore({ db, app: { async uploadFile() { throw new Error("must not upload"); } } });
  await assert.rejects(service.archive("A", Buffer.from("not png"), "image/png"), /TYPE_MISMATCH/);
  assert.equal((await db.collection("bf_assets").get()).data[0].state, "pending");
});
test("bounded asset fetch rejects oversized stream even without a content-length", async () => {
  const fetcher = async () => new Response(new Uint8Array(20));
  await assert.rejects(boundedBytes("https://bucket.myqcloud.com/image", 10, fetcher), /SIZE_LIMIT/);
  await assert.rejects(boundedBytes("http://localhost/private", 100, fetcher), /REJECTED/);
});

test("storage signing explicitly requests the official COS URL contract", async () => {
  const db = memoryDatabase(); const bytes = Buffer.from([255,216,1,2,3]); const calls = [];
  const app = { async uploadFile() { return {fileID:"cloud://bucket/file"}; },
    async getTempFileURL({fileList}) { calls.push(fileList); return {fileList:fileList.map(x=>({fileID:x.fileID,tempFileURL:"https://bucket.myqcloud.com/file"}))}; } };
  const store = createAssetStore({db,app});const asset=await store.archive("A",bytes,"image/jpeg");
  await store.sign("A",[asset.id]);
  assert.equal(calls[0][0].urlType,"COS_URL");
});

test("paid-image archive uses a lease; concurrent retries never call a model or duplicate the upload", async () => {
  const db = memoryDatabase(); let uploads = 0;
  const row = {_id:"paid", state:"done", accountId:"A", url:"https://image.volces.com/result", archiveState:"pending", ts:1};
  await db.collection("bf_image_jobs").doc(row._id).set(row);
  const archiver = createImageArchiver({db, app:{async uploadFile() { uploads++; return {fileID:"cloud://bucket/archived"}; }},
    fetcher:async()=>new Response(Buffer.from([255,216,1,2,3]))});
  await Promise.all([archiver.archive(row),archiver.archive(row)]);
  const stored = (await db.collection("bf_image_jobs").doc("paid").get()).data[0];
  assert.equal(stored.archiveState,"ready");
  assert.equal(uploads,1);
  assert.equal((await archiver.archive(row)).asset.id,stored.asset.id);
  assert.equal(uploads,1);
});

test("archive failure preserves paid success and releases its lease for retry", async () => {
  const db = memoryDatabase();
  const row = {_id:"paid-fail",state:"done",accountId:"A",url:"https://image.volces.com/result",archiveState:"pending",ts:1};
  await db.collection("bf_image_jobs").doc(row._id).set(row);
  const archiver = createImageArchiver({db,app:{},fetcher:async()=>{throw Error("storage unavailable");}});
  await archiver.archive(row);
  const stored = (await db.collection("bf_image_jobs").doc(row._id).get()).data[0];
  assert.equal(stored.state,"done");
  assert.equal(stored.archiveState,"pending");
  assert.equal(stored.archiveAttempts,1);
  assert.equal(stored.archiveLeaseUntil,0);
});
