"use strict";

const COLLECTIONS = Object.freeze({
  billing: "bf_billing_events",
  accounts: "bf_accounts",
  usage: "bf_usage_logs",
});
const one = result => Array.isArray(result?.data) ? result.data[0] : result?.data;
const money = value => Number(Math.max(0, Number(value) || 0).toFixed(4));

// Account, usage row and event state commit in one database transaction. The
// event ID is stable per paid image, so replay never increments the account again.
async function settleImageCharge({ db, accountId, chargeCny, meta = {}, eventId, now = new Date() }) {
  const charge = money(chargeCny);
  const upstream = money(meta.upstreamCostCny != null ? meta.upstreamCostCny : charge);
  return db.runTransaction(async tx => {
    const eventRef = tx.collection(COLLECTIONS.billing).doc(eventId);
    const existing = one(await eventRef.get());
    if (existing && (money(existing.priceCny) !== charge || money(existing.costCny) !== upstream)) {
      return { state: "conflict" };
    }
    if (existing?.state === "committed") return { state: "committed", replayed: true };

    if (!existing) {
      await eventRef.set({
        accountId, costCny: upstream, priceCny: charge,
        marginCny: Number((charge - upstream).toFixed(4)), model: meta.model || "", kind: meta.kind || "image",
        jobId: String(meta.jobKey || meta.jobId || ""), parentJobId: meta.parentJobId || "",
        index: Number.isFinite(Number(meta.index)) ? Number(meta.index) : null,
        state: "pending", accountApplied: false, usageApplied: false, ts: now,
      });
    }

    // Compatibility with an in-flight event written by the previous CAS
    // implementation. Its true flag means the account increment was already
    // attempted; do not charge it a second time during migration.
    const accountAlreadyApplied = existing?.accountApplied === true;
    if (!accountAlreadyApplied) {
      const accountRef = tx.collection(COLLECTIONS.accounts).doc(accountId);
      const account = one(await accountRef.get());
      if (!account) return { state: "account_missing" };
      await accountRef.update({
        imageUsedCny: money(Number(account.imageUsedCny || 0) + charge),
        dayUsedCny: money(Number(account.dayUsedCny || 0) + charge),
        weekUsedCny: money(Number(account.weekUsedCny || 0) + charge),
      });
    }

    await tx.collection(COLLECTIONS.usage).doc(eventId).set({
      accountId, kind: "image", costCny: upstream, priceCny: charge,
      marginCny: Number((charge - upstream).toFixed(4)), ts: now,
      model: meta.model || "unknown", estimated: false, source: "bf-image",
      jobId: String(meta.jobKey || meta.jobId || ""), parentJobId: meta.parentJobId || "",
    });
    await eventRef.update({
      state: "committed", accountApplied: true, usageApplied: true, committedAt: now,
    });
    return { state: "committed", replayed: false };
  });
}

module.exports = { COLLECTIONS, settleImageCharge, money };
