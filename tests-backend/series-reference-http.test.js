"use strict";
const test=require("node:test"),assert=require("node:assert/strict");
const {harness,U}=require("./reference-http-fixture.cjs");
const {syncRecordKey}=require("../cloudfunctions/shared/sync-identifiers");
const contract=()=>({version:1,mode:"replace",items:U.map((id,i)=>({kind:"library",id,role:i?"人物":"底图"}))});
const start=(rid,extra={})=>({requestId:rid,prompt:"把人物素材合成到提供的底图，做两张不同构图。",requested_count:2,size:"1536x1536",structured:{image_references:contract()},...extra});
test("real HTTP start/step/retry sends both owned inputs in order and re-signs retry without duplicate charge",async()=>{
 const h=await harness(),s=await h.request("/series/start",start("refs-flow"));assert.equal(s.status,200);assert.equal(h.calls.length,0);assert.equal(h.reservations.length,1);assert.equal(h.reservations[0].cost,1.28);
 const stored=(await h.db.collection("bf_image_series").doc(s.body.taskId).get()).data[0];assert.equal(stored.referenceManifest.references.length,2);assert.doesNotMatch(JSON.stringify(stored.referenceManifest),/https:|base64/);
 h.failNext();const failed=await h.request("/series/step",{taskId:s.body.taskId,index:1});assert.equal(failed.status,200);assert.equal(failed.body.failed,1);assert.equal(h.charges.length,0);
 await h.request("/series/step",{taskId:s.body.taskId,index:2});assert.equal(h.charges.length,1);
 const retry=await h.request("/series/retry",{requestId:"refs-flow",indices:[1,2]});assert.equal(retry.status,200);assert.equal(retry.body.succeeded,2);assert.deepEqual(retry.body.retriedIndices,[1]);assert.equal(h.charges.length,2);
 for(const call of h.calls){assert.equal(call.image.length,2);assert.match(call.image[0],/image-0/);assert.match(call.image[1],/image-1/);assert.match(call.prompt,/底图/);assert.match(call.prompt,/人物/);}
 assert.notEqual(h.calls[0].image[0],h.calls[2].image[0]);
 await h.request("/series/retry",{requestId:"refs-flow",indices:[1,2]});await h.request("/series/step",{taskId:s.body.taskId,index:1});assert.equal(h.calls.length,3);assert.equal(h.charges.length,2);
});
test("missing/foreign memory is rejected before reservation or provider calls",async()=>{
 for(const owner of ["A","B"]){const h=await harness();if(owner==="A")await h.db.collection("bf_sync_v2").doc(syncRecordKey("A","file",U[1])).update({deleted:true});const r=await h.request("/series/start",start("missing"),owner);assert.equal(r.status,422);assert.match(r.body.msg,/原图/);assert.equal(h.calls.length,0);assert.equal(h.reservations.length,0);assert.equal(h.charges.length,0);}
});
test("same request selection replay is stable; changed roles or IDs conflict without new charges",async()=>{
 const h=await harness(),s=await h.request("/series/start",start("same")),again=await h.request("/series/start",start("same"));assert.equal(again.body.taskId,s.body.taskId);assert.equal(h.reservations.length,1);
 const changed=start("same");changed.structured.image_references.items.reverse();const conflict=await h.request("/series/start",changed);assert.equal(conflict.status,409);assert.equal(h.reservations.length,1);assert.equal(h.calls.length,0);
});
test("deletion after start fails closed without supplier call; restoring original permits targeted retry",async()=>{
 const h=await harness(),s=await h.request("/series/start",start("delete-later"));const file=h.db.collection("bf_sync_v2").doc(syncRecordKey("A","file",U[1]));await file.update({deleted:true});
 const failed=await h.request("/series/step",{taskId:s.body.taskId,index:1});assert.equal(failed.body.items[0].errorCategory,"reference_unavailable");assert.equal(h.calls.length,0);assert.equal(h.charges.length,0);
 await file.update({deleted:false});const retry=await h.request("/series/retry",{requestId:"delete-later",indices:[1]});assert.equal(retry.body.succeeded,1);assert.equal(h.calls.length,1);
});
test("foreign task step and cancelled retry cannot generate",async()=>{
 const h=await harness(),s=await h.request("/series/start",start("guard"));assert.equal((await h.request("/series/step",{taskId:s.body.taskId,index:1},"B")).status,403);
 await h.request("/series/cancel",{taskId:s.body.taskId});assert.equal((await h.request("/series/retry",{requestId:"guard",indices:[1]})).status,409);assert.equal(h.calls.length,0);
});
test("old text-only series still works and unresolved raw start images are never silently discarded",async()=>{
 const h=await harness(),s=await h.request("/series/start",start("legacy",{structured:undefined}));assert.equal(s.status,200);await h.request("/series/step",{taskId:s.body.taskId,index:1});assert.equal(h.calls[0].image,undefined);
 const before=h.calls.length,r=await h.request("/series/start",start("raw",{structured:undefined,image:"data:image/png;base64,AA=="}));assert.equal(r.status,422);assert.equal(h.calls.length,before);
});
test("failed-item retry checks complete remaining budget before any new provider attempt",async()=>{
 const h=await harness(),s=await h.request("/series/start",start("retry-budget"));h.failNext();await h.request("/series/step",{taskId:s.body.taskId,index:1});
 h.setRemaining(0.1);const attempts=h.calls.length,r=await h.request("/series/retry",{requestId:"retry-budget",indices:[1]});
 assert.equal(r.status,402);assert.equal(r.body.needCny,0.64);assert.equal(h.calls.length,attempts);assert.equal(h.charges.length,0);
});
