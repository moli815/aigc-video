"use strict";
// One bounded retry of a read-only membership snapshot. No paid calls occur
// before this succeeds, and explicit membership denials are never retried.
async function readQuotaResponse(url,headers,fetcher=fetch){
 let last;
 for(let attempt=0;attempt<2;attempt++){
  const ctrl=new AbortController(),timer=setTimeout(()=>ctrl.abort(),5000);
  try{const response=await fetcher(url,{headers,signal:ctrl.signal});
   if(attempt===0&&response.status>=500){await response.body?.cancel?.().catch(()=>{});continue;}
   return response;
  }catch(e){last=e;if(attempt===1)throw e;}finally{clearTimeout(timer);}
 }
 throw last||Error("QUOTA_READ_UNAVAILABLE");
}
module.exports={readQuotaResponse};
