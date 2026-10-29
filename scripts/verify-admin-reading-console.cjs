// Browser regression uses isolated fixtures, never saves settings to the live API.
const fs=require('node:fs'),path=require('node:path'),http=require('node:http'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'..'),web=path.join(root,'web');
let playwright;try{playwright=require('playwright');}catch{playwright=require(path.join(process.env.USERPROFILE,'.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright'));}
const {describeSettings,SECTIONS}=require('../cloudfunctions/bf-api/settings-schema');
const runtime={IMAGE_ROUTING_MODE:'auto',IMAGE_SIZE:'2K',CAP_CHAT_ENABLED:'1',CAP_IMAGE_ENABLED:'1',USAGE_COST_MULTIPLIER:2,APP_IMAGE_TIMEOUT:315,CHAT_MODEL:'test-chat',CHAT_API_KEY:'not-a-real-secret-for-qa',META_RULE:'测试规则',CHAT_PRICE_IN:0.1};
const specs=Object.fromEntries(Object.entries(runtime).map(([key,value])=>[key,{type:key==='CHAT_API_KEY'?'secret':typeof value==='number'?'num':'str',label:key,def:()=>value}]));
const accounts=[{id:'qa-one',username:'qa_first',displayName:'测试客户甲',status:'active',tier:'pro',daysLeft:6,quota:{monthCap:100,monthUsed:12,dayUsed:1,dayCap:10,weekUsed:3,weekCap:30}},
 {id:'qa-two',username:'qa_second',displayName:'测试客户乙',status:'expired',tier:'plus',daysLeft:-2,quota:{monthCap:50,monthUsed:45}}];
const fixture={ok:true,window:{days:30,start:'2026-09-30',end:'2026-10-29',startMs:Date.parse('2026-09-30T00:00:00+08:00'),endMs:Date.parse('2026-10-29T20:00:00+08:00')},officialPayableCny:97.7436204,
 trackedCallEstimateCny:1.56,userQuotaDebitedCny:15.7252134,differenceCny:96.1836204,unknownCostCalls:2,legacyUnknownCostRows:453,
 byProvider:{volcengine:92.27,'aliyun-bailian':5.4736204},byProduct:{'Doubao-Seedream':92.27,sfm:5.4736204},byDay:{'2026-10-29':97.7436204},
 details:Array.from({length:25},(_,i)=>({day:'2026-10-29',provider:'volcengine',product:'Doubao-Seedream',model:'test-model',item:'图片生成',usage:1,unit:'张',amount:i===0?.1236204:.12})),
 coverage:{complete:true,missing:[],daysByProvider:{volcengine:30,'aliyun-bailian':30}},dataStatus:'complete',notes:['隔离验收数据，不用于生产账目。'],syncStatus:{lastSync:'2026-10-29T10:00:00Z'}};
const saved=[],queries=[],errors=[];let failSettings=false,browser;
const server=http.createServer((req,res)=>{let p=path.resolve(web,'.'+new URL(req.url,'http://localhost').pathname);if(!p.startsWith(web+path.sep)){res.writeHead(403).end();return;}fs.readFile(p,(err,data)=>{if(err){res.writeHead(404).end();return;}res.setHeader('Content-Type',p.endsWith('.css')?'text/css':p.endsWith('.js')?'text/javascript':p.endsWith('.svg')?'image/svg+xml':'text/html');res.end(data);});});
function contrast(a,b){const luminance=rgb=>rgb.match(/[\d.]+/g).slice(0,3).map(Number).map(n=>n/255).map(n=>n<=.04045?n/12.92:((n+.055)/1.055)**2.4).reduce((v,n,i)=>v+n*[.2126,.7152,.0722][i],0);let x=luminance(a),y=luminance(b);return(Math.max(x,y)+.05)/(Math.min(x,y)+.05);}
(async()=>{fs.mkdirSync(path.join(root,'outputs'),{recursive:true});await new Promise(r=>server.listen(0,'127.0.0.1',r));try{
 const executablePath=process.env.LOCALAPPDATA+'/ms-playwright/chromium-1234/chrome-win64/chrome.exe';browser=await playwright.chromium.launch({headless:true,...(fs.existsSync(executablePath)?{executablePath}:{})});
 const ctx=await browser.newContext({viewport:{width:1440,height:1000}});await ctx.addInitScript(()=>{localStorage.setItem('bf_token','isolated-qa-token');localStorage.setItem('bf_role','admin');});
 await ctx.route('**/api/**',async route=>{const url=new URL(route.request().url()),p=url.pathname,method=route.request().method();let data={ok:true,list:[]},status=200;
   if(p.endsWith('/admin/finance'))data=fixture;
   else if(p.endsWith('/admin/accounts'))data={ok:true,list:accounts};
   else if(p.endsWith('/admin/requests'))data={ok:true,list:[]};
   else if(p.endsWith('/admin/model-calls')){queries.push(url.search);data={ok:true,rows:[],hasMore:false};}
   else if(p.endsWith('/admin/experts-config'))data={ok:true,experts:[],starters:{},ui:{}};
   else if(p.endsWith('/admin/settings')){
     if(failSettings){status=503;data={message:'验收：配置读取暂不可用'};}
     else{if(method==='POST'){const b=route.request().postDataJSON();saved.push(b.updates);Object.assign(runtime,b.updates);}data={ok:true,settings:describeSettings(specs,runtime,{}),sections:SECTIONS,tiers:[],snapshots:[],updatedAt:'2026-10-29T00:00:00Z',applied:Object.keys(saved.at(-1)||{})};}
   }
   await route.fulfill({status,contentType:'application/json',body:JSON.stringify(data)});
 });
 const p=await ctx.newPage();p.on('pageerror',e=>errors.push(e.message));p.on('dialog',d=>d.accept());const url='http://127.0.0.1:'+server.address().port+'/admin.html';
 await p.goto(url,{waitUntil:'networkidle'});await p.waitForSelector('.overview-metric');assert.equal(await p.locator('.overview-metric').count(),4);assert.equal(await p.locator('.chart-day').count(),7);assert.equal(await p.locator('.tabs .nav-icon').count(),9);assert.equal(await p.evaluate(()=>getComputedStyle(document.body).fontSize),'16px');assert.equal(await p.locator('#tab8').isVisible(),true);
 await p.screenshot({path:path.join(root,'outputs/admin-dark-home-20261029.png'),fullPage:true});
 await p.locator('#tabBtn1').click();await p.waitForSelector('#accBox tbody tr');assert.equal(await p.locator('#accBox th').count(),5);assert.equal(await p.locator('.quota-track').count(),2);assert.equal(await p.locator('.quota-visual.critical').count(),1);const badgeGap=await p.locator('.member-state').first().evaluate(e=>{let a=e.children[0].getBoundingClientRect(),b=e.children[1].getBoundingClientRect();return b.top-a.bottom;});assert.ok(badgeGap>=7,'membership badges must not overlap');await p.screenshot({path:path.join(root,'outputs/admin-compact-members-20261029.png'),fullPage:true});
 assert.equal(await p.locator('#accBox [data-act=reset]').first().isVisible(),false);await p.locator('#accBox .row-more summary').first().click();assert.equal(await p.locator('#accBox [data-act=reset]').first().isVisible(),true);
 await p.locator('#accountSearch').fill('qa_second');assert.equal(await p.locator('#accBox tbody tr:visible').count(),1);await p.locator('#accountSearch').fill('');
 await p.locator('#accBox [data-act=edit]').first().click();assert.equal(await p.locator('.modal.show').getAttribute('aria-modal'),'true');await p.keyboard.press('Escape');assert.equal(await p.locator('.modal.show').count(),0);
 await p.locator('#tabBtn4').click();await p.waitForSelector('[data-k=IMAGE_ROUTING_MODE]');assert.equal(await p.locator('#cfgSections [data-k]').count(),6);
 assert.match(await p.locator('[data-k=IMAGE_ROUTING_MODE]').innerText(),/自动分流/);
 await p.locator('details:has(> .crow [data-k=APP_IMAGE_TIMEOUT])').evaluate(e=>e.open=true);await p.locator('[data-k=APP_IMAGE_TIMEOUT]').fill('350');
 await p.locator('[data-config-view=billing]').click();await p.locator('[data-k=USAGE_COST_MULTIPLIER]').fill('3');await p.locator('[data-save=membership_cost]').click();await p.waitForFunction(()=>Object.keys(CFG_DIRTY).length===1);
 assert.deepEqual(saved,[{USAGE_COST_MULTIPLIER:'3'}]);await p.locator('[data-config-view=common]').click();assert.equal(await p.locator('[data-k=APP_IMAGE_TIMEOUT]').inputValue(),'350');
 await p.locator('#cfgSearch').fill('CHAT_API_KEY');assert.equal(await p.locator('#cfgSections [data-k]').count(),1);assert.equal(await p.locator('[data-k=CHAT_API_KEY]').inputValue(),'');await p.locator('#cfgSearch').fill('');
 await p.screenshot({path:path.join(root,'outputs/admin-dark-settings-20261029.png'),fullPage:true});
 await p.locator('#tabBtn7').click();await p.waitForSelector('.finance-hero');assert.match(await p.locator('.amount').innerText(),/¥\d[\d,]*\.\d{2}$/);await p.screenshot({path:path.join(root,'outputs/admin-dark-finance-20261029.png'),fullPage:true});
 await p.getByText(/官方账单明细 ·/).click();await p.locator('#billRows').getByRole('button',{name:'下一页'}).click();assert.match(await p.locator('#billRows').innerText(),/第 2/);
 await p.getByText('用户调用与扣费明细',{exact:true}).click();await p.waitForSelector('#financeAccountFilter option[value=qa-one]',{state:'attached'});await p.locator('#financeAccountFilter').selectOption('qa-one');await p.waitForSelector('#financeCalls table');assert.ok(queries.at(-1).includes('accountId=qa-one'));
 await p.locator('#financeOrderFilter').fill('wrong-order');await p.getByRole('button',{name:'查询调用',exact:true}).click();assert.match(await p.locator('#financeCalls').innerText(),/完整的订单号/);
 for(const i of [0,2,3,5,6,8]){if([0,2,3,5].includes(i))await p.locator('#moreNavigation').evaluate(e=>e.open=true);await p.locator('#tabBtn'+i).click();assert.equal(await p.locator('#tab'+i).isVisible(),true);}
 await p.locator('.reading-panel summary').click();await p.locator('#readingSize').selectOption('20');await p.locator('#readingSpacing').selectOption('relaxed');await p.reload({waitUntil:'networkidle'});assert.equal(await p.evaluate(()=>getComputedStyle(document.body).fontSize),'20px');
 const colors=await p.evaluate(()=>({body:getComputedStyle(document.body).color,bg:getComputedStyle(document.body).backgroundColor,secondary:getComputedStyle(document.querySelector('.quiet')).color,surface:getComputedStyle(document.querySelector('.blk')).backgroundColor}));assert.ok(contrast(colors.body,colors.bg)>=7);assert.ok(contrast(colors.secondary,colors.surface)>=4.5);
 await p.setViewportSize({width:390,height:844});await p.locator('#tabBtn7').click();await p.waitForSelector('.finance-hero');assert.equal(await p.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);await p.screenshot({path:path.join(root,'outputs/admin-dark-mobile-20261029.png'),fullPage:true});
 failSettings=true;await p.locator('#tabBtn4').click();await p.waitForFunction(()=>document.getElementById('cfgSections').textContent.includes('配置读取暂不可用'));assert.equal(await p.locator('#cfgSections [data-k]').count(),0);assert.deepEqual(errors,[]);
 const report={ok:true,at:new Date(),checks:['nine navigation views, four dashboard metrics and seven-day chart','five-column customer table, separated badges, quota highlights, search and collapsed actions','modal keyboard escape','six common settings, global search and hidden secrets','saving one section preserves another draft','official money summary and bill pagination','account-filtered call ledger and order validation','persistent 20px reading preference','390px no overflow','text contrast >=7, secondary >=4.5','HTTP failure is not treated as empty success'],pageErrors:errors,productionWrites:false};fs.writeFileSync(path.join(root,'outputs/admin-reading-console-verification.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report));
 }finally{if(browser)await browser.close();await new Promise(r=>server.close(r));}})().catch(e=>{console.error(e.stack);process.exitCode=1;});
