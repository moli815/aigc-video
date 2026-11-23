"use strict";
const test=require("node:test"),assert=require("node:assert/strict"),http=require("node:http");
const {createReviewedSseSession}=require("../cloudfunctions/bf-api/commercial-chat-review");
const completion={choices:[{message:{content:"reviewed answer"},finish_reason:"stop"}]};
test("actual HTTP completed POST body cannot abort a pending reviewed SSE response",async t=>{
 let aborted=0;
 const server=http.createServer(async(req,res)=>{
  for await(const chunk of req){};
  const session=createReviewedSseSession(res,req,{onClose(){aborted++;}});
  setTimeout(()=>session.complete(completion,"masked"),30);
 });
 await new Promise(r=>server.listen(0,"127.0.0.1",r));t.after(()=>new Promise(r=>server.close(r)));
 const r=await fetch(`http://127.0.0.1:${server.address().port}`,{method:"POST",body:"{}",signal:AbortSignal.timeout(2000)});
 const text=await r.text();assert.equal(r.status,200);assert.match(text,/reviewed answer/);assert.match(text,/data: \[DONE\]/);assert.equal(aborted,0);
});
test("actual HTTP client disconnect cancels a pending reviewed SSE response",async t=>{
 let resolveAbort;
 const aborted=new Promise(r=>{resolveAbort=r;});
 const server=http.createServer(async(req,res)=>{
  for await(const chunk of req){};
  createReviewedSseSession(res,req,{onClose(){resolveAbort(true);}});
 });
 await new Promise(r=>server.listen(0,"127.0.0.1",r));t.after(()=>new Promise(r=>server.close(r)));
 const controller=new AbortController();
 const response=await fetch(`http://127.0.0.1:${server.address().port}`,{method:"POST",body:"{}",signal:controller.signal});
 const reader=response.body.getReader();await reader.read();controller.abort();
 let timer;try{assert.equal(await Promise.race([aborted,new Promise(r=>{timer=setTimeout(()=>r(false),2000);})]),true);}finally{clearTimeout(timer);}
});
