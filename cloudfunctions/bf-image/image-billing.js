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
  let charge = money(chargeCny);
  const upstream = money(meta.upstreamCostCny != null ? meta.upstreamCostCny : charge);
  let providerCharges;
  function allocate(){if(meta.modelCalls!==undefined){
    const {aggregateCosts,allocateCharge}=require('./native-copy-task'),costs=aggregateCosts(meta.modelCalls);
    if(costs.supplierCostEstimateCny!==upstream)throw Object.assign(Error('COPY_COST_CONFLICT'),{code:'COPY_COST_CONFLICT'});
    providerCharges=allocateCharge(costs,charge);
  }}
  return db.runTransaction(async tx => {
    const eventRef = tx.collection(COLLECTIONS.billing).doc(eventId);
    const existing = one(await eventRef.get());
    if(existing&&existing.accountId!==accountId)return{state:'conflict'};
    const accountRef = tx.collection(COLLECTIONS.accounts).doc(accountId);
    const account = one(await accountRef.get());
    if (!account) return { state: "account_missing" };
    if(account.costBudgetPolicy?.version===1)charge=upstream;
    allocate();
    if(existing?.state==='committed'&&existing.accountId===accountId&&money(existing.costCny)===upstream&&
      (!providerCharges||JSON.stringify(existing.providerCharges?.map(c=>[c.modelCallId,c.supplierCostEstimateCny]))===JSON.stringify(providerCharges.map(c=>[c.modelCallId,c.supplierCostEstimateCny]))))
      return {state:'committed',replayed:true,priceCny:existing.priceCny};
    if (existing && (existing.accountId!==accountId || money(existing.priceCny) !== charge || money(existing.costCny) !== upstream ||
        providerCharges&&JSON.stringify(existing.providerCharges)!==JSON.stringify(providerCharges))) {
      return { state: "conflict" };
    }
    if (existing?.state === "committed") return { state: "committed", replayed: true };
    let budgetRelease=0;
    if(meta.imageBudgetId)budgetRelease=await require('./image-cost-budget').releaseInTransaction({tx,accountId,key:meta.imageBudgetId,account,reason:'settled',now:new Date(now).getTime()});
    let reservation,reservationRef;
    if(meta.nativeReservationId){
      reservationRef=tx.collection('bf_quota_reservations').doc(meta.nativeReservationId);reservation=one(await reservationRef.get());
      if(!reservation||reservation.accountId!==accountId||reservation.kind!=='native_copy'||reservation.state!=='active'||reservation.amountCny+1e-6<charge)return{state:'reservation_conflict'};
    }

    if (!existing) {
      await eventRef.set({
        accountId, costCny: upstream, priceCny: charge,
        marginCny: Number((charge - upstream).toFixed(4)), model: meta.model || "", kind: meta.kind || "image",
        jobId: String(meta.jobKey || meta.jobId || ""), parentJobId: meta.parentJobId || "",
        index: Number.isFinite(Number(meta.index)) ? Number(meta.index) : null,
        state: "pending", accountApplied: false, usageApplied: false, ts: now,
        ...(providerCharges?{providerCharges,costBasis:'configured_provider_usage_estimate_not_invoice'}:{}),
      });
    }

    // Compatibility with an in-flight event written by the previous CAS
    // implementation. Its true flag means the account increment was already
    // attempted; do not charge it a second time during migration.
    const accountAlreadyApplied = existing?.accountApplied === true;
    if (!accountAlreadyApplied || reservation) {
      const reserved=Number(account.nativeCopyReservedCny||0);
      if(reservation&&(!Number.isFinite(reserved)||reserved+1e-6<reservation.amountCny))return{state:'reservation_conflict'};
      const {dayKey,weekKey}=require('./shared/usage-settlement'),day=dayKey(now),week=weekKey(now);
      await accountRef.update({
        ...(!accountAlreadyApplied?{
        imageUsedCny: money(Number(account.imageUsedCny || 0) + charge),
        dayUsedCny: money((!account.dayKey||account.dayKey===day?Number(account.dayUsedCny||0):0)+charge),
        weekUsedCny: money((!account.weekKey||account.weekKey===week?Number(account.weekUsedCny||0):0)+charge),
        dayKey:day,weekKey:week,
        ...(budgetRelease?{imageBudgetReservedCny:Number((Number(account.imageBudgetReservedCny||0)-budgetRelease).toFixed(8))}:{}),
        }:{}),
        ...(reservation?{nativeCopyReservedCny:money(reserved-reservation.amountCny)}:{}),
      });
    }
    if(reservationRef)await reservationRef.update({state:'released',releasedAt:now.getTime(),releaseReason:'settled'});

    await tx.collection(COLLECTIONS.usage).doc(eventId).set({
      accountId, kind: "image", costCny: upstream, priceCny: charge,
      marginCny: Number((charge - upstream).toFixed(4)), ts: now,
      model: meta.model || "unknown", estimated: true, supplierBilledCny:null,
      costBasis:'configured_provider_usage_estimate_not_invoice', source: "bf-image",
      jobId: String(meta.jobKey || meta.jobId || ""), parentJobId: meta.parentJobId || "",
      ...(providerCharges?{providerCharges,estimated:true,costBasis:'configured_provider_usage_estimate_not_invoice'}:{}),
    });
    await eventRef.update({
      state: "committed", accountApplied: true, usageApplied: true, committedAt: now,
    });
    return { state: "committed", replayed: false, priceCny:charge };
  });
}

module.exports = { COLLECTIONS, settleImageCharge, money };
