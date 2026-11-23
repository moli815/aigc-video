"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const { capabilityEnabled, authorizeImageExecution } = require("../cloudfunctions/bf-image/image-execution-gate");
const { COLLECTIONS, settleImageCharge } = require("../cloudfunctions/bf-image/image-billing");

function fakeDb(initial = {}) {
  const stores = Object.fromEntries(Object.values(COLLECTIONS).map(name => [name, structuredClone(initial[name] || {})]));
  const tx = {
    collection(name) {
      return {
        doc(id) {
          return {
            async get() { return { data: stores[name][id] ? [stores[name][id]] : [] }; },
            async set(value) { stores[name][id] = { _id: id, ...structuredClone(value) }; },
            async update(patch) { Object.assign(stores[name][id], structuredClone(patch)); },
          };
        },
      };
    },
  };
  let queue = Promise.resolve();
  return {
    stores,
    runTransaction(work) {
      const result = queue.then(() => work(tx));
      queue = result.catch(() => {});
      return result;
    },
  };
}

test("paid gate honors global stop before quota and normalizes all denial classes", async () => {
  assert.equal(capabilityEnabled("0"), false);
  assert.equal(capabilityEnabled("false"), false);
  assert.equal(capabilityEnabled("1"), true);
  let quotaCalls = 0;
  const disabled = await authorizeImageExecution({}, { enabled: "0", quotaExhausted: async () => { quotaCalls++; } });
  assert.equal(disabled.denial.status, 503);
  assert.equal(disabled.denial.body.error, "IMAGE_DISABLED");
  assert.equal(quotaCalls, 0);
  for (const [quota, status] of [
    [{ denied: 401, code: "UNAUTHORIZED" }, 401],
    [{ denied: 403, code: "MEMBERSHIP_EXPIRED" }, 403],
    [{ unavailable: true }, 503],
    [{ exhausted: true }, 429],
  ]) {
    const result = await authorizeImageExecution({}, { enabled: "1", quotaExhausted: async () => quota });
    assert.equal(result.ok, false);
    assert.equal(result.denial.status, status);
  }
  const quota = { exhausted: false, remainingCny: 12 };
  const allowed = await authorizeImageExecution({}, { enabled: true, quotaExhausted: async () => quota });
  assert.equal(allowed.ok, true);
  assert.equal(allowed.quota, quota);
});

test("concurrent charge and replay commit account, usage and event exactly once", async () => {
  const db = fakeDb({ [COLLECTIONS.accounts]: { a1: { _id: "a1", imageUsedCny: 2, dayUsedCny: 2, weekUsedCny: 2 } } });
  const input = { db, accountId: "a1", chargeCny: 0.6, meta: { upstreamCostCny: 0.3, jobKey: "job1", model: "pro" }, eventId: "event1" };
  const [first, replay] = await Promise.all([settleImageCharge(input), settleImageCharge(input)]);
  assert.equal(first.state, "committed");
  assert.equal(replay.state, "committed");
  assert.equal(db.stores[COLLECTIONS.accounts].a1.imageUsedCny, 2.6);
  assert.equal(db.stores[COLLECTIONS.accounts].a1.dayUsedCny, 2.6);
  assert.equal(db.stores[COLLECTIONS.usage].event1.priceCny, 0.6);
  assert.equal(db.stores[COLLECTIONS.usage].event1.costCny, 0.3);
  assert.equal(db.stores[COLLECTIONS.billing].event1.state, "committed");
});

test("legacy in-flight event is completed without a second account increment", async () => {
  const db = fakeDb({
    [COLLECTIONS.accounts]: { a1: { _id: "a1", imageUsedCny: 5, dayUsedCny: 5, weekUsedCny: 5 } },
    [COLLECTIONS.billing]: { old: { _id: "old", accountId: "a1", state: "pending", accountApplied: true, costCny: 0.3, priceCny: 0.6 } },
  });
  const result = await settleImageCharge({ db, accountId: "a1", chargeCny: 0.6, meta: { upstreamCostCny: 0.3 }, eventId: "old" });
  assert.equal(result.state, "committed");
  assert.equal(db.stores[COLLECTIONS.accounts].a1.imageUsedCny, 5);
  assert.equal(db.stores[COLLECTIONS.billing].old.state, "committed");
});

test("same event cannot be reused for a different price", async () => {
  const db = fakeDb({
    [COLLECTIONS.accounts]: { a1: { _id: "a1", imageUsedCny: 1 } },
    [COLLECTIONS.billing]: { event1: { _id: "event1", accountId: "a1", state: "pending", accountApplied: false, costCny: 0.3, priceCny: 0.6 } },
  });
  const result = await settleImageCharge({ db, accountId: "a1", chargeCny: 1.2, meta: { upstreamCostCny: 0.6 }, eventId: "event1" });
  assert.equal(result.state, "conflict");
  assert.equal(db.stores[COLLECTIONS.accounts].a1.imageUsedCny, 1);
  assert.equal(db.stores[COLLECTIONS.usage].event1, undefined);
});
