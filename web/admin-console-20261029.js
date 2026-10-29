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
function renderAdminOverview(){
  var load=++OVERVIEW_LOAD,box=q('overviewData');box.innerHTML='<div class="empty" role="status">正在读取工作台…</div>';
  // Isolate failures: a billing issue must not erase the membership/review cards.
  Promise.allSettled([api('/admin/requests'),api('/admin/accounts'),api('/admin/finance?days=30')]).then(function(results){
    if(load!==OVERVIEW_LOAD)return;
    var cards=[['待审核申请',0],['即将到期 · 7天内',1],['近30天平台应付',7]];
    var h='<div class="overview-metrics">';
    cards.forEach(function(card,i){var r=results[i],value='暂时无法读取',sub='点击查看详情';
      if(r.status==='fulfilled'){
        if(i===0){value=String((r.value.list||[]).filter(function(x){return x.status==='pending';}).length)+' 件';sub='开通与续费申请';}
        if(i===1){value=String((r.value.list||[]).filter(function(x){return x.status==='active'&&x.daysLeft!=null&&x.daysLeft>=0&&x.daysLeft<=7;}).length)+' 位';sub='当前客户列表 · 最多200人';}
        if(i===2){value='¥'+Number(r.value.officialPayableCny).toFixed(2);sub=r.value.coverage?.complete?'两平台日期已覆盖 · 当日仍会补账':'部分日期尚待同步';}
      }
      h+='<button class="overview-metric" onclick="tab('+card[1]+')"><span>'+card[0]+'</span><strong>'+esc(value)+'</strong><small>'+esc(sub)+'</small></button>';
    });
    box.innerHTML=h+'</div><p class="quiet">数据来自当前服务器记录。进入各页可查看明细。</p>';
  });
}
function filterAccountRows(){var query=q('accountSearch').value.trim().toLowerCase(),count=0;
  q('accBox').querySelectorAll('tbody tr').forEach(function(row){var show=!query||row.textContent.toLowerCase().indexOf(query)>=0;row.hidden=!show;if(show)count++;});
  q('accountCount').textContent='当前列表显示 '+count+' 位';
}
function applyReadingPreferences(){
  var pref={};try{pref=JSON.parse(localStorage.getItem('bf_admin_reading')||'{}');}catch{}
  var size=[18,20,22].indexOf(Number(pref.size))>=0?Number(pref.size):18;
  var spacing=pref.spacing==='relaxed'?'relaxed':'normal';
  document.documentElement.style.setProperty('--reading-size',size+'px');
  document.documentElement.style.setProperty('--reading-line',spacing==='relaxed'?'1.95':'1.75');
  document.documentElement.dataset.readingSize=String(size);
  if(q('readingSize'))q('readingSize').value=String(size);if(q('readingSpacing'))q('readingSpacing').value=spacing;
}
function saveReadingPreferences(){
  try{localStorage.setItem('bf_admin_reading',JSON.stringify({size:Number(q('readingSize').value),spacing:q('readingSpacing').value}));}catch{}
  applyReadingPreferences();
}
document.addEventListener('DOMContentLoaded',applyReadingPreferences);
document.addEventListener('keydown',function(e){
  if(e.key!=='Tab')return;var modal=document.querySelector('.modal.show');if(!modal)return;
  var focusable=Array.from(modal.querySelectorAll('button,input,select,textarea,a[href]')).filter(function(el){return !el.disabled&&el.getClientRects().length;});
  if(!focusable.length)return;var first=focusable[0],last=focusable[focusable.length-1];
  if(e.shiftKey&&document.activeElement===first){e.preventDefault();last.focus();}
  else if(!e.shiftKey&&document.activeElement===last){e.preventDefault();first.focus();}
});
