"use strict";
const {catalogFromBills}=require("./shared/supplier-pricing");
const {settleUsage}=require("./shared/usage-settlement");
const one=r=>Array.isArray(r.data)?r.data[0]:r.data;
async function refreshCatalog(db,importResult) {
  // An authentication/network failure cannot clear the last verified prices.
  if (importResult.providers?.["aliyun-bailian"]?.status !== "read_verified") return {state:"unchanged_import_failed"};
  const snapshots=(await db.collection("bf_vendor_bills").where({provider:"aliyun-bailian"}).orderBy("day","desc").limit(10).get()).data||[];
  const next=catalogFromBills(snapshots);
  if (!Object.keys(next.models).length) return {state:"unchanged_no_usable_rates"};
  const result=await db.runTransaction(async tx=>{
    const ref=tx.collection("bf_config").doc("supplier_cost_catalog"),previous=one(await ref.get());
    if (previous && new Date(previous.importStartedAt) > new Date(importResult.startedAt)) return {state:"newer_catalog_exists"};
    await ref.set({...next,revision:String(new Date(importResult.startedAt).getTime()),importStartedAt:importResult.startedAt,updatedAt:new Date()});
    return {state:"updated",models:Object.keys(next.models),issues:next.issues};
  });
  return result;
}
async function settlePending(db) {
  const runtime=one(await db.collection("bf_config").doc("runtime").get())?.data||{};
  if(runtime.USAGE_BILLING_MODE !== "supplier_cost") return {state:"disabled"};
  const catalog=one(await db.collection("bf_config").doc("supplier_cost_catalog").get())||{};
  const rows=(await db.collection("bf_model_calls").where({chargeState:"pending_cost",settlementRequested:true}).limit(100).get()).data||[];
  const result={examined:rows.length,committed:0,pending:0,failed:0};
  for(const call of rows) {
    try {
      const r=await settleUsage({db,accountId:call.accountId,callId:call._id,catalog,runtime});
      if(r.state==="committed")result.committed++;else result.pending++;
    } catch {result.failed++;}
  }
  return result;
}
module.exports={refreshCatalog,settlePending};
