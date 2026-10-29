"use strict";
const tcb = require("@cloudbase/node-sdk");
const { collect } = require("./collector");
const {refreshCatalog,settlePending}=require("./rate-catalog");
exports.main = async (event = {}) => {
  const db = tcb.init({ env: process.env.TCB_ENV }).database();
  // Return only non-secret import status. No client-accessible HTTP route is created.
  const result=await collect({ db, days:event.days ?? 3, offsetDays:event.offsetDays ?? 0, log: event => console.log(JSON.stringify(event)) });
  try {result.rateCatalog=await refreshCatalog(db,result);result.pendingSettlement=await settlePending(db);}
  catch {result.settlementError="RATE_OR_SETTLEMENT_STORAGE_ERROR";}
  return result;
};
