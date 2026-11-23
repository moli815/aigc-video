"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const { fulfillApproval } = require("../cloudfunctions/bf-api/approval-fulfillment");

const NAMES = ["bf_accounts", "bf_requests", "bf_notifications", "bf_deliveries"];
function fakeDb(initial = {}, failCollection = "") {
  const stores = Object.fromEntries(NAMES.map(name => [name, structuredClone(initial[name] || {})]));
  const tx = {
    collection(name) {
      return {
        doc(id) {
          return {
            async get() { return { data: stores[name][id] ? [stores[name][id]] : [] }; },
            async set(value) { if (name === failCollection) throw new Error("INJECTED_WRITE_FAILURE"); stores[name][id] = { _id: id, ...structuredClone(value) }; },
            async update(patch) { if (name === failCollection) throw new Error("INJECTED_WRITE_FAILURE"); Object.assign(stores[name][id], structuredClone(patch)); },
          };
        },
      };
    },
  };
  let queue = Promise.resolve();
  return {
    stores,
    runTransaction(work) {
      const result = queue.then(async () => {
        const snapshot = structuredClone(stores);
        try { return await work(tx); }
        catch (error) { for (const name of NAMES) stores[name] = snapshot[name]; throw error; }
      });
      queue = result.catch(() => {});
      return result;
    },
  };
}

const tiers = { plus: { key: "plus", priceCny: 166, poolCapCny: 140 }, pro: { key: "pro", priceCny: 399, poolCapCny: 300 } };
const base = {
  staff: { sub: "admin1" }, auto: false, now: new Date("2026-11-10T02:00:00Z"), tiers,
  tierDefOf: account => tiers[account.tier || "plus"], memberMonths: 1, periodKey: () => "2026-11",
  decryptPassword: value => value === "cipher-valid" ? "valid-password" : null,
  verifyPassword: (plain, hash) => plain === "valid-password" && hash === "hash-valid",
};

test("renew replay never extends twice and keeps one deterministic notification", async () => {
  const request = { _id: "req1", type: "renew", accountId: "a1", tier: "plus", customerName: "客户", submittedBy: "staff1" };
  const db = fakeDb({
    bf_accounts: { a1: { _id: "a1", tier: "plus", expiresAt: new Date("2026-12-01T00:00:00Z"), chatUsedCny: 2 } },
    bf_requests: { req1: { _id: "req1", status: "processing" } },
  });
  const [first, replay] = await Promise.all([
    fulfillApproval({ ...base, db, request }),
    fulfillApproval({ ...base, db, request }),
  ]);
  assert.equal(first.idempotent, false);
  assert.equal(replay.idempotent, true);
  assert.equal(new Date(replay.to).toISOString().slice(0, 10), "2027-01-01");
  assert.deepEqual(db.stores.bf_accounts.a1.renewedRequestIds, ["req1"]);
  assert.equal(db.stores.bf_requests.req1.status, "approved");
  assert.equal(Object.keys(db.stores.bf_notifications).length, 1);
});

test("notification failure rolls back account creation instead of leaving an orphan", async () => {
  const request = { _id: "req2", type: "create", tier: "plus", customerName: "客户", submittedBy: "staff1" };
  const db = fakeDb({ bf_requests: { req2: { _id: "req2", status: "processing" } } }, "bf_notifications");
  await assert.rejects(() => fulfillApproval({ ...base, db, request, generated: {
    username: "customer@gmail.com", passwordHash: "hash-new", passwordCipher: "cipher-new",
  } }), /INJECTED_WRITE_FAILURE/);
  assert.equal(db.stores.bf_accounts.acct_req2, undefined);
  assert.equal(db.stores.bf_deliveries.dlv_req2, undefined);
  assert.equal(db.stores.bf_requests.req2.status, "processing");
});

test("legacy mismatched credentials are repaired together; valid replay is unchanged", async () => {
  const request = { _id: "req3", type: "create", tier: "plus", customerName: "客户", submittedBy: "staff1" };
  const generated = { username: "new@gmail.com", passwordHash: "hash-new", passwordCipher: "cipher-new" };
  const db = fakeDb({
    bf_accounts: { acct_req3: { _id: "acct_req3", username: "actual@gmail.com", passwordHash: "hash-old", pwv: 2 } },
    bf_deliveries: { dlv_req3: { _id: "dlv_req3", username: "wrong@gmail.com", passwordCipher: "cipher-wrong" } },
    bf_requests: { req3: { _id: "req3", status: "processing" } },
  });
  const repaired = await fulfillApproval({ ...base, db, request, generated });
  assert.equal(repaired.username, "actual@gmail.com");
  assert.equal(db.stores.bf_accounts.acct_req3.passwordHash, "hash-new");
  assert.equal(db.stores.bf_accounts.acct_req3.pwv, 3);
  assert.equal(db.stores.bf_deliveries.dlv_req3.passwordCipher, "cipher-new");
  assert.equal(db.stores.bf_deliveries.dlv_req3.username, "actual@gmail.com");
  assert.equal(db.stores.bf_notifications.ntf_req3.refDeliveryId, "dlv_req3");

  db.stores.bf_accounts.acct_req3.passwordHash = "hash-valid";
  db.stores.bf_deliveries.dlv_req3.passwordCipher = "cipher-valid";
  const replay = await fulfillApproval({ ...base, db, request, generated: {
    username: "another@gmail.com", passwordHash: "hash-another", passwordCipher: "cipher-another",
  } });
  assert.equal(replay.idempotent, true);
  assert.equal(db.stores.bf_accounts.acct_req3.passwordHash, "hash-valid");
  assert.equal(db.stores.bf_accounts.acct_req3.pwv, 3);
  assert.equal(db.stores.bf_deliveries.dlv_req3.passwordCipher, "cipher-valid");
});
