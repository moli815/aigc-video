"use strict";
const crypto=require("node:crypto");
const {ratesFor,quoteCall,money,multiplierOf}=require("./supplier-pricing");
const one=r=>Array.isArray(r.data)?r.data[0]:r.data;
function dayKey(at) {const d=new Date(new Date(at).getTime()+8*3600000);return `${d.getUTCFullYear()}-${d.getUTCMonth()+1}-${d.getUTCDate()}`;}
function weekKey(at) {const d=new Date(new Date(at).getTime()+8*3600000);d.setUTCDate(d.getUTCDate()-((d.getUTCDay()||7)-1));return `${d.getUTCFullYear()}-${d.getUTCMonth()+1}-${d.getUTCDate()}`;}
async function settleUsage({db,accountId,callId,catalog,runtime,meta={},now=new Date(),imageQuote}) {
  if (!callId) return {state:"missing_call_id"};
  // One transaction includes the account, usage row and call state. Retries and
  // parallel settlement workers cannot increment a customer twice.
  return db.runTransaction(async tx=>{
    const ref=tx.collection("bf_model_calls").doc(callId),call=one(await ref.get());
    if (!call || call.accountId !== accountId) return {state:"call_missing_or_wrong_owner"};
    if (call.chargeState === "committed") return {state:"committed",priceCny:call.priceCny,replayed:true};
    let snapshot=call.rateSnapshot || ratesFor(catalog,runtime,call.provider,call.model,call.startedAt);
    if (snapshot && call.settlementMultiplier != null) snapshot={...snapshot,multiplier:call.settlementMultiplier};
    const quote=imageQuote || quoteCall(call,snapshot);
    if (!quote) {
      await ref.update({chargeState:"pending_cost",settlementRequested:true,settlementTier:meta.tier||call.settlementTier||"",settlementMultiplier:call.settlementMultiplier ?? snapshot?.multiplier ?? multiplierOf(runtime)});
      return {state:"pending_cost"};
    }
    const accountRef=tx.collection("bf_accounts").doc(accountId),account=one(await accountRef.get());
    if (!account) return {state:"account_missing"};
    // Never debit today's allowance for a previous paid membership cycle.
    if (account.cycleAnchorAt && new Date(call.startedAt) < new Date(account.cycleAnchorAt)) {
      await ref.update({chargeState:"closed_cycle_review",settlementRequested:true});
      return {state:"closed_cycle_review"};
    }
    const eventId="charge_"+crypto.createHash("sha256").update(accountId+"\0"+callId).digest("hex");
    const kind=call.kind==="image"?"image":"chat",counter=kind==="image"?"imageUsedCny":"chatUsedCny";
    const patch={[counter]:money(Number(account[counter]||0)+quote.priceCny)};
    if (dayKey(call.startedAt)===dayKey(now)) {patch.dayKey=dayKey(now);patch.dayUsedCny=money((account.dayKey===patch.dayKey?Number(account.dayUsedCny||0):0)+quote.priceCny);}
    if (weekKey(call.startedAt)===weekKey(now)) {patch.weekKey=weekKey(now);patch.weekUsedCny=money((account.weekKey===patch.weekKey?Number(account.weekUsedCny||0):0)+quote.priceCny);}
    const tier=meta.tier||call.settlementTier||"flash";
    if(tier==="pro") patch.proUsedCny=money(Number(account.proUsedCny||0)+quote.priceCny);
    const row={accountId,kind,requestId:call.requestId||"",orderId:call.orderId,modelCallId:callId,
      costCny:quote.supplierCostCny,priceCny:quote.priceCny,marginCny:money(quote.priceCny-quote.supplierCostCny),
      multiplier:quote.multiplier,costBasis:quote.costBasis,supplierBilledCny:null,estimated:true,
      model:call.model,tier,promptTokens:call.inputTokens??0,completionTokens:call.outputTokens??0,cachedInputTokens:call.cachedInputTokens??0,ts:now,usageAt:call.startedAt};
    await accountRef.update(patch);
    await tx.collection("bf_usage_logs").doc(eventId).set(row);
    await ref.update({priceCny:quote.priceCny,supplierCostEstimateCny:quote.supplierCostCny,costBasis:quote.costBasis,
      billingEventId:eventId,chargeState:"committed",chargedAt:now,settlementRequested:true,rateSnapshot:snapshot||null,multiplier:quote.multiplier});
    return {state:"committed",priceCny:quote.priceCny,supplierCostCny:quote.supplierCostCny,eventId};
  });
}
module.exports={settleUsage,dayKey,weekKey};
