/* Uses the existing admin token and API. Never embeds credentials or bill instance IDs. */
var FINANCE=null,FINANCE_PAGE=0,FINANCE_LOAD=0;
function financeMoney(n){return n==null?'未核定':'¥'+Number(n).toLocaleString('zh-CN',{minimumFractionDigits:2,maximumFractionDigits:6});}
function financeProvider(p){return p==='volcengine'?'火山引擎':p==='aliyun-bailian'?'阿里云百炼':p;}
function financeProduct(p){return {'sfm':'百炼模型与搜索','Doubao-Seedream':'Seedream 图片生成','ark_bd':'方舟服务 · ark_bd','ark_open_source_llm':'方舟开源模型服务'}[p]||p;}
function loadCostReport(days){
  var load=++FINANCE_LOAD;days=days||30;
  [7,14,30].forEach(function(d){var b=q('cr'+d);if(b){b.classList.toggle('on',d===days);b.setAttribute('aria-pressed',d===days?'true':'false');}});
  q('costReport').innerHTML='<div class="empty" role="status">正在读取官方账单与调用台账…</div>';
  api('/admin/finance?days='+days).then(function(j){if(load!==FINANCE_LOAD)return;FINANCE=j;FINANCE_PAGE=0;renderFinance();})
    .catch(function(e){if(load===FINANCE_LOAD)q('costReport').innerHTML='<div class="err" role="alert">'+esc(e.message)+'。未读取成功，不代表费用为零。</div><button class="btnNew" onclick="loadCostReport('+days+')">重新读取</button>';});
}
function financeSummary(n){return n==null?'未核定':'¥'+Number(n).toLocaleString('zh-CN',{minimumFractionDigits:2,maximumFractionDigits:2});}
function renderFinance(){
  var j=FINANCE;if(!j)return;
  var h='<div class="finance-hero"><div>近'+j.window.days+'天 · 官方平台应付</div><div class="amount">'+financeSummary(j.officialPayableCny)+'</div><div>'+esc(j.window.start)+' 至 '+esc(j.window.end)+' · 北京时间</div></div>';
  if(j.dataStatus!=='complete'||!j.coverage.complete)h+='<div class="warn" role="alert">当前数据不完整，暂不用于结算。缺少 '+j.coverage.missing.length+' 个平台日期。</div>';
  h+='<p class="finance-summary-note">当日账单会延迟补齐。充值、平台消费和用户额度分别计算。</p><div class="finance-grid">';
  ['volcengine','aliyun-bailian'].forEach(function(p){var days=j.coverage.daysByProvider[p]||0;h+='<div class="finance-card"><div>'+financeProvider(p)+'</div><strong>'+financeSummary(j.byProvider[p]||0)+'</strong><small>日期已同步 '+days+' / '+j.window.days+' 天</small></div>';});h+='</div>';
  h+='<div class="finance-grid"><div class="finance-card"><div>App 调用成本估算</div><strong>'+financeSummary(j.trackedCallEstimateCny)+'</strong><small>实际用量 × 已核验单价</small></div><div class="finance-card"><div>用户额度已扣减</div><strong>'+financeSummary(j.userQuotaDebitedCny)+'</strong><small>会员消耗的额度，与收款分开看</small></div></div>';
  h+='<details class="cfgwrap"><summary>按产品查看支出</summary><div class="finance-grid">';
  Object.keys(j.byProduct).filter(function(p){return j.byProduct[p]!==0;}).sort(function(a,b){return j.byProduct[b]-j.byProduct[a];}).forEach(function(p){h+='<div class="finance-card"><div>'+esc(financeProduct(p))+'</div><strong>'+financeSummary(j.byProduct[p])+'</strong></div>';});h+='</div></details>';
  h+='<details class="cfgwrap"><summary>按日期查看支出</summary><div class="bill-scroll"><table><thead><tr><th scope="col">日期</th><th scope="col">官方应付</th></tr></thead><tbody>';
  Object.keys(j.byDay).sort().reverse().forEach(function(d){h+='<tr><td>'+esc(d)+'</td><td>'+financeMoney(j.byDay[d])+'</td></tr>';});h+='</tbody></table></div></details>';
  h+='<details class="cfgwrap"><summary>官方账单明细 · '+j.details.length+' 条</summary><p>核对平台消费，或导出精确金额。</p><button class="btnNew" onclick="exportFinance()">导出账单 CSV</button><div id="billRows"></div></details>';
  h+='<details class="cfgwrap" ontoggle="if(this.open)loadFinanceAccounts()"><summary>用户调用与扣费明细</summary><p>按用户或订单核对每次调用。</p><div class="account-toolbar"><label>用户<select id="financeAccountFilter" onchange="loadFinanceCalls(0)"><option value="">全部用户</option></select></label><label>订单号<input id="financeOrderFilter" type="search" placeholder="可选，ord_开头" onsearch="loadFinanceCalls(0)"></label><button class="btnNew" onclick="loadFinanceCalls(0)">查询调用</button></div><div id="financeCalls"></div></details>';
  h+='<details class="cfgwrap"><summary>金额口径与历史差异</summary><p>官方应付精确值：'+financeMoney(j.officialPayableCny)+'。</p><p>调用估算精确值：'+financeMoney(j.trackedCallEstimateCny)+'；额度扣减：'+financeMoney(j.userQuotaDebitedCny)+'。</p><p>尚未核价 '+j.unknownCostCalls+' 笔；旧口径聊天流水 '+j.legacyUnknownCostRows+' 笔。</p><p>平台应付与调用估算差额为 '+financeMoney(j.differenceCny)+'。可能包含其他项目、内部辅助调用、历史缺失和出账时间差。</p>'+j.notes.map(function(n){return '<p>'+esc(n)+'</p>';}).join('')+'</details>';
  h+='<p class="quiet">最近同步 '+esc(fmtTime(j.syncStatus.lastSync))+' · 刷新页面可读取最新结果。摘要保留两位小数，明细保留精确金额。</p>';
  q('costReport').innerHTML=h;renderBillRows();
}
var FINANCE_ACCOUNTS={},FINANCE_CALL_LOAD=0;
function loadFinanceAccounts(){
  var el=q('financeAccountFilter');if(!el||el.dataset.loaded)return;el.dataset.loaded='loading';
  api('/admin/accounts').then(function(j){if(q('financeAccountFilter')!==el)return;
    FINANCE_ACCOUNTS={};(j.list||[]).forEach(function(a){FINANCE_ACCOUNTS[a.id]=a.displayName||a.username;});
    el.innerHTML='<option value="">全部用户</option>'+(j.list||[]).map(function(a){return '<option value="'+esc(a.id)+'">'+esc(a.displayName||a.username)+' · '+esc(a.username)+'</option>';}).join('');el.dataset.loaded='yes';
  }).catch(function(){delete el.dataset.loaded;toast('用户列表暂时无法读取，仍可按订单查询。');});
}
function renderBillRows(){var rows=FINANCE.details,start=FINANCE_PAGE*20,limit=Math.ceil(rows.length/20)||1;var h='<div class="bill-scroll"><table><thead><tr><th>日期 / 平台</th><th>产品 / 计费项</th><th>用量</th><th>应付金额</th></tr></thead><tbody>';
  rows.slice(start,start+20).forEach(function(r){h+='<tr><td>'+esc(r.day)+'<br>'+esc(financeProvider(r.provider))+'</td><td>'+esc(r.model||r.product)+'<br><span class="mono">'+esc(r.item)+'</span></td><td>'+esc(r.usage==null?'未提供':r.usage)+' '+esc(r.unit)+'</td><td>'+financeMoney(r.amount)+'</td></tr>';});
  h+='</tbody></table></div><div class="bill-pages"><button onclick="financePage(-1)" '+(FINANCE_PAGE===0?'disabled':'')+'>上一页</button><span>第 '+(FINANCE_PAGE+1)+' / '+limit+' 页</span><button onclick="financePage(1)" '+(FINANCE_PAGE+1>=limit?'disabled':'')+'>下一页</button></div>';q('billRows').innerHTML=h;
}
function financePage(n){FINANCE_PAGE=Math.max(0,Math.min(Math.ceil(FINANCE.details.length/20)-1,FINANCE_PAGE+n));renderBillRows();}
function exportFinance(){var safe=function(v){var s=String(v==null?'':v);if(/^[=+@\-\t\r]/.test(s))s="'"+s;return '"'+s.replace(/"/g,'""')+'"';};var rows=[['日期','平台','产品','模型','计费项','用量','单位','官方应付元']].concat(FINANCE.details.map(function(r){return[r.day,financeProvider(r.provider),r.product,r.model,r.item,r.usage,r.unit,r.amount];}));var url=URL.createObjectURL(new Blob(['\ufeff'+rows.map(function(r){return r.map(safe).join(',');}).join('\r\n')],{type:'text/csv;charset=utf-8'}));var a=document.createElement('a');a.href=url;a.download='中防AI-官方账单-'+FINANCE.window.start+'-'+FINANCE.window.end+'.csv';a.click();setTimeout(function(){URL.revokeObjectURL(url);},5000);}
function loadFinanceCalls(page){var load=++FINANCE_CALL_LOAD,target=q('financeCalls');var account=q('financeAccountFilter').value,order=q('financeOrderFilter').value.trim();if(order&&!/^ord_[a-f0-9]{32}$/.test(order)){target.textContent='请输入完整的订单号，或清空后查看全部。';return;}target.innerHTML='<div class="empty">正在读取…</div>';var w=FINANCE.window;api('/admin/model-calls?start='+encodeURIComponent(new Date(w.startMs).toISOString())+'&end='+encodeURIComponent(new Date(w.endMs).toISOString())+'&limit=20&page='+page+(account?'&accountId='+encodeURIComponent(account):'')+(order?'&orderId='+encodeURIComponent(order):'')).then(function(j){if(load!==FINANCE_CALL_LOAD||q('financeCalls')!==target)return;var h='<div class="bill-scroll"><table><thead><tr><th>时间 / 订单</th><th>用户 / 模型</th><th>输入 / 缓存 / 输出 Token</th><th>成本估算 / 扣额度</th><th>状态</th></tr></thead><tbody>';j.rows.forEach(function(r){h+='<tr><td>'+esc(fmtTime(r.startedAt))+'<br><span class="mono">'+esc(r.orderId)+'</span></td><td>'+esc(FINANCE_ACCOUNTS[r.accountId]||r.accountId)+'<br><span class="mono">'+esc(r.model)+'</span></td><td>'+esc(r.inputTokens??'—')+' / '+esc(r.cachedInputTokens??'—')+' / '+esc(r.outputTokens??'—')+'</td><td>'+financeMoney(r.supplierCostEstimateCny)+'<br>'+financeMoney(r.priceCny)+'</td><td>'+esc(r.chargeState==='committed'?'已扣额度':r.chargeState==='pending_cost'?'待核账':r.status==='cached'?'缓存免扣':'未结算')+'</td></tr>';});h+='</tbody></table></div><div class="bill-pages"><button onclick="loadFinanceCalls('+Math.max(0,page-1)+')" '+(page===0?'disabled':'')+'>上一页</button><span>第 '+(page+1)+' 页</span><button onclick="loadFinanceCalls('+(page+1)+')" '+(!j.hasMore?'disabled':'')+'>下一页</button></div>';target.innerHTML=h;}).catch(function(e){if(load===FINANCE_CALL_LOAD&&q('financeCalls')===target)target.textContent=e.message;});}
