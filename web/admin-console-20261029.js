/* Admin presentation only. Provider contracts and validation stay on the server. */
var CFG_VIEW='common', OVERVIEW_LOAD=0;
var ADMIN_CONFIG_VIEWS=[
  ['common','常用设置'],['models','模型与分流'],['experience','出图与记忆'],
  ['billing','额度与限流'],['advanced','技术与密钥'],['all','全部配置']
];
var ADMIN_COMMON_KEYS=['IMAGE_ROUTING_MODE','IMAGE_SIZE','CAP_CHAT_ENABLED','CAP_IMAGE_ENABLED','USAGE_COST_MULTIPLIER','APP_IMAGE_TIMEOUT'];
function adminEnumLabel(key,value){
  var labels=key==='IMAGE_ROUTING_MODE'?{auto:'自动分流 · 按任务选择',flash_only:'全部快速档 · Flash',pro_only:'全部高质量 · Pro'}:
    key==='USAGE_BILLING_MODE'?{supplier_cost:'成本 × 倍数',legacy:'旧计费 · 仅回滚'}:{};
  return labels[value]||value;
}
function adminFieldDescription(s){
  var copy={
    IMAGE_ROUTING_MODE:'日常使用请选择自动分流。系统按任务要求选择 Flash 或 Pro；需要临时比较效果时，再切换为全部高质量。',
    IMAGE_SIZE:'默认图片清晰度。更大的图片通常需要更久，费用也可能更高。',
    USAGE_COST_MULTIPLIER:'聊天调用成本乘以这个倍数，扣减用户额度。图片倍数由图片服务配置单独管理。',
    APP_IMAGE_TIMEOUT:'用户最多等待图片生成的秒数。它要与服务器超时配合，通常无需调整。',
    CAP_CHAT_ENABLED:'允许用户使用对话。关闭后会暂停对话能力。',
    CAP_IMAGE_ENABLED:'允许用户生成和编辑图片。关闭后会暂停作图能力。'
  };return CFG_VIEW==='common'&&copy[s.key]?copy[s.key]:s.description;
}
function configMatches(s){
  if(CFG_VIEW==='common')return ADMIN_COMMON_KEYS.indexOf(s.key)>=0;
  if(CFG_VIEW==='models')return s.section==='model_provider';
  if(CFG_VIEW==='experience')return ['generation','context_rules'].indexOf(s.section)>=0;
  if(CFG_VIEW==='billing')return ['membership_cost','security_limits'].indexOf(s.section)>=0;
  if(CFG_VIEW==='advanced')return ['storage_credentials','version_compat'].indexOf(s.section)>=0;
  return true;
}
function setConfigView(view){CFG_VIEW=view;renderSettings();}
function renderFocusedSettings(){
  var wrap=q('cfgSections');if(!wrap)return;
  var kw=q('cfgSearch').value.trim().toLowerCase();
  q('configViews').innerHTML=ADMIN_CONFIG_VIEWS.map(function(v){return '<button type="button" data-config-view="'+v[0]+'" aria-pressed="'+(CFG_VIEW===v[0])+'">'+v[1]+'</button>';}).join('');
  q('configViews').querySelectorAll('button').forEach(function(b){b.onclick=function(){setConfigView(b.dataset.configView);};});
  var opened=false,count=0,h='';
  CFG_SECTIONS.forEach(function(sec){
    var rows=CFG_DATA.filter(function(s){return s.section===sec.id&&(kw?(s.title+' '+s.key+' '+(s.description||'')).toLowerCase().indexOf(kw)>=0:configMatches(s));});
    if(!rows.length)return;count+=rows.length;
    var dirty=rows.filter(function(s){return CFG_DIRTY[s.key]!==undefined;}).length;
    h+='<details class="cfgwrap"'+((kw||!opened)?' open':'')+'><summary>'+esc(sec.title)+'<span class="section-count">'+rows.length+'项'+(dirty?' · '+dirty+'项未保存':'')+'</span></summary><p class="section-help">'+esc(sec.desc)+'</p>'+rows.map(fieldHtml).join('')+'<div class="section-save"><button class="btnNew" data-save="'+esc(sec.id)+'">保存本组修改</button></div></details>';opened=true;
  });
  var totalDirty=Object.keys(CFG_DIRTY).filter(function(k){var s=cfgByKey(k);return s&&(String(s.value??'')!==String(CFG_DIRTY[k]))&&(!s.secret||CFG_DIRTY[k]);}).length;
  q('configStatus').textContent=(kw?'搜索全部配置，共找到 ': '当前显示 ')+count+' 项'+(totalDirty?'；另有 '+totalDirty+' 项草稿未保存':'');
  wrap.innerHTML=h||'<div class="empty">没有匹配的设置。可以换一个词搜索。</div>';
  wrap.querySelectorAll('[data-save]').forEach(function(b){b.onclick=function(){saveSection(b.dataset.save);};});
  Object.keys(CFG_DIRTY).forEach(function(k){var el=Array.from(wrap.querySelectorAll('[data-k]')).find(function(e){return e.dataset.k===k;});if(!el)return;
    if(el.type==='checkbox'){el.checked=CFG_DIRTY[k]==='1';var label=el.parentNode.querySelector('span');if(label)label.textContent=el.checked?'已开启':'已关闭';}else el.value=CFG_DIRTY[k];
  });renderHistory();
}
function adminIcon(name){return '<svg class="nav-icon" aria-hidden="true" focusable="false" viewBox="0 0 24 24"><use href="admin-icons-20261029.svg#'+name+'"></use></svg>';}
function quotaVisual(a){
  var cap=Number(a.quota?.monthCap),used=Number(a.quota?.monthUsed),pct=Number(a.poolPct);
  var hasMoney=a.quota?.monthCap!=null&&a.quota?.monthUsed!=null&&Number.isFinite(cap)&&cap>0&&Number.isFinite(used);
  if(hasMoney)pct=(1-used/cap)*100;
  if((!hasMoney&&a.poolPct==null)||!Number.isFinite(pct))return '<span class="quiet">暂无额度数据</span>';
  var band=pct<=20?'critical':pct<=50?'caution':'healthy',width=Math.max(0,Math.min(100,pct));
  var label=pct<=0?'额度已用完':pct<=20?'额度偏低':pct<=50?'留意用量':'额度充足';
  var amount=hasMoney?'¥'+Math.max(0,cap-used).toFixed(2):width.toFixed(1)+'%';
  return '<div class="quota-visual '+band+'"><div class="quota-top"><strong>'+amount+'</strong><span>'+label+'</span></div><div class="quota-track" role="progressbar" aria-label="月额度剩余" aria-valuemin="0" aria-valuemax="100" aria-valuenow="'+width.toFixed(1)+'"><i style="width:'+width+'%"></i></div><div class="quota-caption">剩余 '+width.toFixed(1)+'%'+(hasMoney?' · 总额 ¥'+cap.toFixed(2):'')+'</div></div>';
}
function renderAdminOverview(){
  var load=++OVERVIEW_LOAD,box=q('overviewData');box.innerHTML='<div class="empty" role="status">正在读取工作台…</div>';
  Promise.allSettled([api('/admin/requests'),api('/admin/accounts'),api('/admin/finance?days=30')]).then(function(results){
    if(load!==OVERVIEW_LOAD)return;
    var requestOk=results[0].status==='fulfilled',accountOk=results[1].status==='fulfilled',financeOk=results[2].status==='fulfilled';
    var accounts=accountOk?(results[1].value.list||[]):[],pending=requestOk?(results[0].value.list||[]).filter(function(x){return x.status==='pending';}).length:null;
    var active=accounts.filter(function(x){return x.status==='active';}).length;
    var expiring=accounts.filter(function(x){return x.status==='active'&&x.daysLeft!=null&&x.daysLeft>=0&&x.daysLeft<=7;}).length;
    var low=accounts.filter(function(x){return x.status==='active'&&((x.quota&&Number(x.quota.monthCap)>0&&Number(x.quota.monthUsed)/Number(x.quota.monthCap)>=.8)||(x.poolPct!=null&&Number(x.poolPct)<=20));}).length;
    var bill=financeOk?results[2].value:null;
    var cards=[['当前可用会员',accountOk?active+' 位':'读取失败','users-round',1,'mint'],['待审核申请',requestOk?pending+' 件':'读取失败','clipboard-check',0,pending?'amber':'sky'],['额度偏低客户',accountOk?low+' 位':'读取失败','wallet',1,low?'amber':'mint'],['近30天平台应付',bill?'¥'+Number(bill.officialPayableCny).toFixed(2):'读取失败','credit-card',7,'sky']];
    var h='<div class="overview-metrics">';cards.forEach(function(c){h+='<button class="overview-metric tone-'+c[4]+'" onclick="tab('+c[3]+')"><span class="metric-label">'+c[0]+adminIcon(c[2])+'</span><strong>'+esc(c[1])+'</strong><small>查看'+(c[3]===7?'支出明细':c[3]===0?'待处理申请':'客户列表')+' →</small></button>';});h+='</div>';
    h+='<div class="overview-detail-grid"><section class="overview-chart"><div class="overview-section-head"><h4>平台支出趋势</h4><span>最近7天 · 官方应付</span></div>';
    if(bill){
      var end=Date.parse(bill.window.end+'T00:00:00Z'),days=Array.from({length:7},function(_,i){var day=new Date(end-(6-i)*86400000).toISOString().slice(0,10);return{day:day,value:Number(bill.byDay[day]||0),known:bill.coverage.complete||Object.hasOwn(bill.byDay,day)};}),max=Math.max(1,...days.map(function(d){return d.value;}));
      h+='<div class="spend-chart">';days.forEach(function(d){h+='<div class="chart-day" aria-label="'+esc(d.day)+' '+(d.known?'应付'+d.value.toFixed(2)+'元':'未完成同步')+'"><span class="chart-amount">'+(d.known?'¥'+d.value.toFixed(2):'待同步')+'</span><div class="chart-track"><i class="'+(d.value>0?'has-spend':'')+'" style="height:'+(d.known?Math.max(3,Math.max(0,d.value)/max*100):0)+'%"></i></div><span class="chart-date">'+esc(d.day.slice(5).replace('-','/'))+'</span></div>';});h+='</div><div class="chart-foot"><span>火山 ¥'+Number(bill.byProvider.volcengine||0).toFixed(2)+'</span><span>百炼 ¥'+Number(bill.byProvider['aliyun-bailian']||0).toFixed(2)+'</span><small>30天合计；本日账单仍会补齐</small></div>';
    }else h+='<p class="quiet">账单暂时无法读取，客户管理仍可正常使用。</p>';
    h+='</section><section class="overview-health"><div class="overview-section-head"><h4>需要留意</h4><span>客户与额度</span></div><div class="health-row"><span>7天内到期</span><strong class="'+(expiring?'text-amber':'')+'">'+(accountOk?expiring+' 位':'未读取')+'</strong></div><div class="health-row"><span>剩余额度≤20%</span><strong class="'+(low?'text-amber':'')+'">'+(accountOk?low+' 位':'未读取')+'</strong></div><div class="health-row"><span>账单日期同步</span><strong class="'+(bill?.coverage.complete?'text-mint':'text-amber')+'">'+(bill?(bill.coverage.complete?'已覆盖':'待补齐'):'未读取')+'</strong></div><button class="health-action" onclick="tab(1)">检查客户状态 →</button></section></div><p class="quiet">客户统计基于当前列表（最多200人）。金额为平台应付，与用户额度分开核算。</p>';
    box.innerHTML=h;
  });
}
function decorateAdminNavigation(){
  var icons={8:'layout-dashboard',1:'users-round',7:'wallet',4:'sliders-horizontal',6:'credit-card',0:'clipboard-check',2:'file-clock',3:'user-cog',5:'sparkles'};
  Object.keys(icons).forEach(function(i){var b=q('tabBtn'+i);if(b&&!b.querySelector('svg'))b.insertAdjacentHTML('afterbegin',adminIcon(icons[i]));});
}
function filterAccountRows(){var query=q('accountSearch').value.trim().toLowerCase(),count=0;
  q('accBox').querySelectorAll('tbody tr').forEach(function(row){var show=!query||row.textContent.toLowerCase().indexOf(query)>=0;row.hidden=!show;if(show)count++;});
  q('accountCount').textContent='当前列表显示 '+count+' 位';
}
function applyReadingPreferences(){
  var pref={};try{pref=JSON.parse(localStorage.getItem('bf_admin_reading')||'{}');}catch{}
  if(!pref||typeof pref!=='object'||Array.isArray(pref))pref={};
  var size=Number(pref.size);if(pref.version!==2)size=Number.isFinite(size)?Math.max(16,size-2):16;if([16,18,20].indexOf(size)<0)size=16;
  var spacing=pref.spacing==='relaxed'?'relaxed':'normal';
  document.documentElement.style.setProperty('--reading-size',size+'px');
  document.documentElement.style.setProperty('--reading-line',spacing==='relaxed'?'1.85':'1.65');
  document.documentElement.dataset.readingSize=String(size);
  if(q('readingSize'))q('readingSize').value=String(size);if(q('readingSpacing'))q('readingSpacing').value=spacing;
}
function saveReadingPreferences(){
  try{localStorage.setItem('bf_admin_reading',JSON.stringify({version:2,size:Number(q('readingSize').value),spacing:q('readingSpacing').value}));}catch{}
  applyReadingPreferences();
}
document.addEventListener('DOMContentLoaded',function(){applyReadingPreferences();decorateAdminNavigation();});
document.addEventListener('keydown',function(e){
  if(e.key!=='Tab')return;var modal=document.querySelector('.modal.show');if(!modal)return;
  var focusable=Array.from(modal.querySelectorAll('button,input,select,textarea,a[href]')).filter(function(el){return !el.disabled&&el.getClientRects().length;});
  if(!focusable.length)return;var first=focusable[0],last=focusable[focusable.length-1];
  if(e.shiftKey&&document.activeElement===first){e.preventDefault();last.focus();}
  else if(!e.shiftKey&&document.activeElement===last){e.preventDefault();first.focus();}
});
