"use strict";
const crypto=require('node:crypto');
const CONFIG='admin_review_notifications',STATE='admin_review_push_state';
const REVIEW_URL='https://xmy-test-d5g8c0xcifcefcfd5-1449098021.tcloudbaseapp.com/admin.html?review=1';
const one=r=>Array.isArray(r.data)?r.data[0]:r.data;
const ms=v=>v?new Date(v).getTime():0;
const dayOf=n=>new Date(n+8*3600000).toISOString().slice(0,10);
const validKey=k=>typeof k==='string'&&/^SCT[A-Za-z0-9_-]{12,200}$/.test(k);
function message(count,test=false){return{title:test?'中防AI · 手机审批测试':`中防AI · ${count}笔申请待核款`,desp:(test?'这是手机审批提醒测试。确认微信收到后，再启用人工核款模式。':`当前有${count}笔会员申请待审核。请先核对支付宝真实到账，再批准开通。`)+`\n\n[打开手机审核页](${REVIEW_URL})\n\n需要管理员登录；本提醒不包含客户姓名、账号或付款凭证。`};}
async function status(db){const [c,s,r]=await Promise.all([db.collection('bf_config').doc(CONFIG).get(),db.collection('bf_config').doc(STATE).get(),db.collection('bf_config').doc('runtime').get()]);const config=one(c)||{},state=one(s)||{};return{configured:validKey(config.sendKey),enabled:config.enabled===true,lastTestAcceptedAt:config.lastTestAcceptedAt||null,lastState:state.lastState||'not_sent',lastSentAt:state.lastSentAt||null,autoApproveHours:Number(one(r)?.data?.AUTO_APPROVE_HOURS||0),reviewUrl:REVIEW_URL};}
async function save(db,body,actor){
  if(body.sendKey!==undefined&&!validKey(body.sendKey))throw Object.assign(new Error('请填写SCT开头的Server酱Turbo SendKey'),{code:'BAD_INPUT'});
  return db.runTransaction(async tx=>{const ref=tx.collection('bf_config').doc(CONFIG),old=one(await ref.get())||{};
    if(!old.sendKey&&!body.sendKey)throw Object.assign(new Error('请先配置SendKey'),{code:'BAD_INPUT'});
    const patch={...old,updatedAt:new Date(),updatedBy:actor};
    if(body.sendKey&&body.sendKey!==old.sendKey){patch.sendKey=body.sendKey;patch.lastTestAcceptedAt=null;patch.enabled=false;}
    if(body.enabled===false)patch.enabled=false;
    await ref.set(patch);return{configured:true,needsTest:!patch.lastTestAcceptedAt};
  });
}
async function enableManual(db,received,actor,now=Date.now()){
  if(received!==true)throw Object.assign(new Error('请先确认微信已收到测试提醒'),{code:'NOT_CONFIRMED'});
  await db.runTransaction(async tx=>{
    const c=tx.collection('bf_config').doc(CONFIG),config=one(await c.get())||{};
    if(!validKey(config.sendKey)||!config.lastTestAcceptedAt||now-ms(config.lastTestAcceptedAt)>86400000)throw Object.assign(new Error('请先发送并收到微信测试提醒，再启用手机核款'),{code:'TEST_REQUIRED'});
    const r=tx.collection('bf_config').doc('runtime'),runtime=one(await r.get())||{data:{}};
    await r.set({...runtime,data:{...(runtime.data||{}),AUTO_APPROVE_HOURS:0},updatedAt:new Date(now),revision:String(now)});
    await c.set({...config,enabled:true,manualEnabledAt:new Date(now),manualEnabledBy:actor});
  });return{autoApproveHours:0};
}
async function sweep({db,test=false,fetchImpl=globalThis.fetch,now=Date.now()}){
  const config=one(await db.collection('bf_config').doc(CONFIG).get())||{};
  if(!validKey(config.sendKey)||(!test&&config.enabled!==true))return{state:'not_configured_or_disabled'};
  const pending=db.collection('bf_requests').where({status:'pending'});
  const [total,latest]=test?[{total:0},{data:[]}]:await Promise.all([pending.count(),pending.orderBy('createdAt','desc').limit(1).get()]);
  if(!test&&!total.total)return{state:'no_pending'};
  const fingerprint=crypto.createHash('sha256').update(total.total+'|'+(latest.data?.[0]?._id||'')).digest('hex');
  const lease=crypto.randomUUID(),day=dayOf(now),ref=db.collection('bf_config').doc(STATE);
  const claim=await db.runTransaction(async tx=>{const r=tx.collection('bf_config').doc(STATE),s=one(await r.get())||{};
    if(ms(s.leaseUntil)>now)return'busy';
    // Reserve attempts before the network request, so concurrent invocations and
    // uncertain provider outcomes cannot exceed the configured free-tier budget.
    if(s.day===day&&s.attempts>=5)return'daily_limit';
    if(test&&now-ms(s.lastAttemptAt)<60000)return'too_soon';
    if(!test&&now-ms(s.lastAttemptAt)<600000)return'too_soon';
    if(!test&&s.lastFingerprint===fingerprint&&now-ms(s.lastSentAt)<6*3600000)return'unchanged';
    await r.set({...s,day,attempts:s.day===day?Number(s.attempts||0)+1:1,lease,leaseUntil:new Date(now+60000),lastAttemptAt:new Date(now),lastState:'sending'});return'claimed';
  });
  if(claim!=='claimed')return{state:claim};
  let accepted=false;
  try{const response=await fetchImpl('https://sctapi.ftqq.com/'+config.sendKey+'.send',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams(message(total.total,test)).toString(),signal:AbortSignal.timeout(8000),redirect:'error'});const result=await response.json();accepted=response.ok&&result.code===0;}
  catch{/* Never return/log exceptions containing the credential-bearing URL. */}
  const state=accepted?'provider_accepted':'send_failed';
  await db.runTransaction(async tx=>{const r=tx.collection('bf_config').doc(STATE),s=one(await r.get())||{};if(s.lease!==lease)return;
    await r.set({...s,leaseUntil:null,lastState:state,...(accepted?{lastSentAt:new Date(now),...(test?{}:{lastFingerprint:fingerprint})}:{})});
    if(test&&accepted){const c=tx.collection('bf_config').doc(CONFIG),current=one(await c.get())||{};if(current.sendKey===config.sendKey)await c.set({...current,lastTestAcceptedAt:new Date(now),enabled:true});}
  });
  return{state,providerAccepted:accepted,deliveredToPhone:false};
}
module.exports={status,save,enableManual,sweep,message,validKey,REVIEW_URL};
