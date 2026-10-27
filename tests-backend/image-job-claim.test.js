"use strict";
const test = require("node:test"), assert = require("node:assert/strict");
const { memoryDatabase } = require("./foundation-fixture");
const { claimImageJob } = require("../cloudfunctions/shared/image-job-claim");
const args = db => ({db,key:"owned-key",rid:"stable-request",accountId:"A",now:1e9});
test("concurrent identical requests acquire exactly one model execution", async()=>{
  const db=memoryDatabase(); const claims=await Promise.all(Array.from({length:6},()=>claimImageJob(args(db))));
  assert.equal(claims.filter(x=>x.state==="new").length,1);
  assert.equal(claims.filter(x=>x.state==="busy").length,5);
});
test("94-second Pro generation cannot be taken over by a retry",async()=>{
  const db=memoryDatabase();await claimImageJob(args(db));
  assert.equal((await claimImageJob({...args(db),now:1e9+94000})).state,"busy");
  assert.equal((await claimImageJob({...args(db),now:1e9+3600000})).state,"busy");
});
test("successful result older than five minutes remains reusable",async()=>{
  const db=memoryDatabase();await db.collection("bf_image_jobs").doc("owned-key").set({accountId:"A",state:"done",ts:1,url:"https://existing",asset:{id:"asset"}});
  const result=await claimImageJob(args(db));assert.equal(result.state,"done");assert.equal(result.url,"https://existing");assert.equal(result.asset.id,"asset");
});
test("uncertain upstream outcome never grants another generation",async()=>{
  const db=memoryDatabase();await db.collection("bf_image_jobs").doc("owned-key").set({accountId:"A",state:"uncertain",ts:1});
  assert.deepEqual(await claimImageJob(args(db)),{state:"busy",confirming:true});
});
test("definitive rejected request can be claimed once under concurrent retries",async()=>{
  const db=memoryDatabase();await db.collection("bf_image_jobs").doc("owned-key").set({accountId:"A",state:"failed"});
  const result=await Promise.all([claimImageJob(args(db)),claimImageJob(args(db))]);
  assert.equal(result.filter(x=>x.state==="new").length,1);
});
test("ledger failure and wrong ownership fail closed without overwriting",async()=>{
  assert.equal((await claimImageJob({...args({}),db:{runTransaction:async()=>{throw Error("offline");}}})).state,"unavailable");
  const db=memoryDatabase();await db.collection("bf_image_jobs").doc("owned-key").set({accountId:"B",state:"done",url:"private"});
  assert.equal((await claimImageJob(args(db))).state,"unavailable");
  assert.equal((await db.collection("bf_image_jobs").doc("owned-key").get()).data[0].accountId,"B");
});
