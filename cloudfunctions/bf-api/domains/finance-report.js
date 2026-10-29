"use strict";
const {tsMsOf}=require("../cost-report");
const round=n=>Number(n.toFixed(8)),number=n=>n!=null&&n!==""&&Number.isFinite(Number(n))?Number(n):null;
function windowOf(days,now=Date.now()) {
  if(!Number.isInteger(days)||days<1||days>31)throw Object.assign(new Error("请选择1至31天"),{code:"BAD_QUERY"});
  const endDay=new Date(now+8*3600000).toISOString().slice(0,10),startMs=Date.parse(endDay+'T00:00:00+08:00')-(days-1)*86400000;
  return{days,startMs,endMs:now,start:new Date(startMs+8*3600000).toISOString().slice(0,10),end:endDay};
}
function aggregateFinance({bills,calls,usage,window,truncated=false}) {
  const byProvider={},byProduct={},byDay={},details=[],coverage={};let official=0,estimate=0,unknownCalls=0,debited=0,legacyUnknown=0;
  for(const s of bills){
    if(!s.complete||s.day<window.start||s.day>window.end)continue;
    coverage[s.provider] ||= new Set();coverage[s.provider].add(s.day);
    for(const r of s.rows||[]){
      const amount=number(r.payableAmount);if(r.currency!=="CNY"||amount==null)continue;
      official+=amount;byProvider[s.provider]=(byProvider[s.provider]||0)+amount;byProduct[r.product||'其他']=(byProduct[r.product||'其他']||0)+amount;byDay[s.day]=(byDay[s.day]||0)+amount;
      const part=String(r.instanceId||'').split(';'),kind=part.find(x=>/^(input_token|output_token)/.test(x));
      const model=kind?part[part.indexOf(kind)-1]:'';
      details.push({day:s.day,provider:s.provider,product:r.product,item:kind||r.item||'图片/服务用量',model,usage:r.usage,unit:r.usageUnit,amount,currency:r.currency});
    }
  }
  for(const c of calls){const at=tsMsOf(c.startedAt);if(at==null||at<window.startMs||at>window.endMs)continue;
    const n=number(c.supplierCostEstimateCny);if(n==null)unknownCalls++;else estimate+=n;
  }
  for(const u of usage){const at=tsMsOf(u.ts);if(at==null||at<window.startMs||at>window.endMs)continue;
    const n=number(u.priceCny);if(n!=null)debited+=n;
    if(u.kind==='chat'&&!u.costBasis)legacyUnknown++;
  }
  const missing=[];for(const p of ['volcengine','aliyun-bailian'])for(let t=window.startMs;t<=window.endMs;t+=86400000){const day=new Date(t+8*3600000).toISOString().slice(0,10);if(!coverage[p]?.has(day))missing.push({provider:p,day});}
  const rounded=map=>Object.fromEntries(Object.entries(map).map(([k,v])=>[k,round(v)]));
  return{ok:true,window,officialPayableCny:round(official),trackedCallEstimateCny:round(estimate),userQuotaDebitedCny:round(debited),
    differenceCny:round(official-estimate),unknownCostCalls:unknownCalls,legacyUnknownCostRows:legacyUnknown,
    byProvider:rounded(byProvider),byProduct:rounded(byProduct),byDay:rounded(byDay),details:details.sort((a,b)=>b.day.localeCompare(a.day)),
    coverage:{expectedDays:window.days,daysByProvider:Object.fromEntries(Object.entries(coverage).map(([p,v])=>[p,v.size])),missing,complete:!missing.length},
    dataStatus:truncated?'truncated':'complete',billingLagExpected:true,finalSettlement:false,
    notes:['官方应付金额不是充值金额，也不一定是已扣现金；当日账单尚未完全出账。','调用台账最近才启用，历史记录不完整；差额不等于错误扣款或利润。','旧聊天流水曾把会员计价当作成本；不再用它冒充供应商真实支出。','额度扣减是会员额度消耗，不代表本期现金收入。'],generatedAt:new Date().toISOString()};
}
async function queryFinance(db,params,now=Date.now()) {
  const window=windowOf(Number(params.get('days')||30),now);let truncated=false;
  async function read(col,filter,limit=20000){let rows=[];for(let offset=0;offset<limit;offset+=500){const r=await db.collection(col).where(filter).skip(offset).limit(500).get();rows.push(...(r.data||[]));if((r.data||[]).length<500)return rows;}truncated=true;return rows;}
  const [bills,calls,usage,status]=await Promise.all([
    read('bf_vendor_bills',{day:db.command.gte(window.start).and(db.command.lte(window.end))},500),
    read('bf_model_calls',{startedAt:db.command.gte(new Date(window.startMs))}),
    read('bf_usage_logs',db.command.or([{ts:db.command.gte(new Date(window.startMs))},{ts:db.command.gte(window.startMs)}])),
    db.collection('bf_config').doc('billing_import_status').get(),
  ]);
  const report=aggregateFinance({bills,calls,usage,window,truncated});const s=(status.data||[])[0];
  report.syncStatus={providers:s?.providers||{},lastSync:s?.endedAt||null};return report;
}
module.exports={windowOf,aggregateFinance,queryFinance};
