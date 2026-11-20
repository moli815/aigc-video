#!/usr/bin/env node
/**
 * 用本机 Chrome headless + CDP 验证管理端「失败筛选」在真实浏览器里能渲染。
 * 不依赖 puppeteer：Node 22 自带 WebSocket。
 *
 * 流程：建临时 admin → 启动 Chrome → 注入 localStorage token → 打开账单页 →
 *       检查状态下拉 → 切到「仅失败」→ 检查表格行 → 截图 → 清理
 */
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { spawn } = require("child_process");

const ROOT = path.resolve(__dirname, "..");
const OUT = path.join(ROOT, "outputs/admin-filter-20261120");
const DOMAIN = "https://xmy-test-d5g8c0xcifcefcfd5-1449098021.tcloudbaseapp.com";
const API = "https://xmy-test-d5g8c0xcifcefcfd5-1449098021.ap-shanghai.app.tcloudbase.com";
const CHROME = "C:/Program Files/Google/Chrome/Application/chrome.exe";
const PORT = 9333;

const hashPwd = (p) => {
  const s = crypto.randomBytes(16).toString("hex");
  return "scrypt$" + s + "$" + crypto.scryptSync(p, s, 64).toString("hex");
};

class CDP {
  constructor(ws) {
    this.ws = ws;
    this.id = 0;
    this.pending = new Map();
    ws.onmessage = (e) => {
      const m = JSON.parse(e.data);
      if (m.id && this.pending.has(m.id)) {
        const { resolve, reject } = this.pending.get(m.id);
        this.pending.delete(m.id);
        m.error ? reject(new Error(JSON.stringify(m.error))) : resolve(m.result);
      }
    };
  }
  send(method, params = {}) {
    const id = ++this.id;
    return new Promise((res, rej) => {
      this.pending.set(id, { resolve: res, reject: rej });
      this.ws.send(JSON.stringify({ id, method, params }));
    });
  }
  async eval(expr) {
    const r = await this.send("Runtime.evaluate", { expression: expr, returnByValue: true, awaitPromise: true });
    if (r.exceptionDetails) throw new Error("页面异常: " + JSON.stringify(r.exceptionDetails).slice(0, 200));
    return r.result.value;
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  fs.mkdirSync(OUT, { recursive: true });
  const cred = JSON.parse(fs.readFileSync(path.join(process.env.USERPROFILE, ".config/.cloudbase/auth.json"), "utf8")).credential;
  const app = require(path.join(ROOT, "cloudfunctions/bf-api/node_modules/@cloudbase/node-sdk")).init({
    env: "xmy-test-d5g8c0xcifcefcfd5", region: "ap-shanghai",
    secretId: cred.tmpSecretId, secretKey: cred.tmpSecretKey, sessionToken: cred.tmpToken,
  });
  const db = app.database();

  const PWD = crypto.randomBytes(10).toString("hex");
  const staff = {
    username: "qa_" + crypto.randomBytes(3).toString("hex"),
    passwordHash: hashPwd(PWD), displayName: "临时UI质检", role: "admin", status: "active",
    createdAt: new Date(), failedAttempts: 0,
  };
  const ins = await db.collection("bf_staff").add(staff);
  console.log("临时 admin", staff.username);

  const lr = await fetch(API + "/api/admin/login", {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ username: staff.username, password: PWD }),
  });
  const lj = await lr.json().catch(() => ({}));
  if (!lj.token) throw new Error("登录失败 " + JSON.stringify(lj).slice(0, 150));
  console.log("token 已获取");

  const profile = path.join(OUT, ".chrome-profile");
  fs.rmSync(profile, { recursive: true, force: true });
  const chrome = spawn(CHROME, [
    "--headless=new", "--disable-gpu", "--hide-scrollbars",
    "--remote-debugging-port=" + PORT,
    "--user-data-dir=" + profile,
    "--window-size=1440,1100",
    "about:blank",
  ], { stdio: "ignore" });

  let wsUrl = null;
  for (let i = 0; i < 40; i++) {
    await sleep(300);
    try {
      const r = await fetch(`http://127.0.0.1:${PORT}/json/list`);
      const list = await r.json();
      const page = list.find((t) => t.type === "page");
      if (page && page.webSocketDebuggerUrl) { wsUrl = page.webSocketDebuggerUrl; break; }
    } catch {}
  }
  if (!wsUrl) throw new Error("Chrome CDP 未就绪");

  const ws = new WebSocket(wsUrl);
  await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
  const cdp = new CDP(ws);
  await cdp.send("Page.enable");
  await cdp.send("Runtime.enable");

  // 每次导航前注入登录态
  await cdp.send("Page.addScriptToEvaluateOnNewDocument", {
    source: `try{localStorage.setItem('bf_token',${JSON.stringify(lj.token)});localStorage.setItem('bf_role','admin');localStorage.setItem('bf_name','临时UI质检');}catch(e){}`,
  });

  const url = DOMAIN + "/admin.html?nc=" + Date.now();
  const nav = cdp.send("Page.navigate", { url });
  await nav;
  await sleep(3500);

  const meta = await cdp.eval(`JSON.stringify({
    title: document.title,
    hasTab7: !!document.getElementById('tab7'),
    token: !!localStorage.getItem('bf_token'),
    scriptSrc: [...document.querySelectorAll('script[src]')].map(s=>s.getAttribute('src')).filter(x=>x&&x.includes('finance')),
    scriptLoaded: typeof loadCostReport === 'function',
    hasSelect: !!document.getElementById('financeStatusFilter')
  })`);
  console.log("页面元信息", meta);

  // 切到账单页（会触发 loadCostReport(30)）
  await cdp.eval("tab(7)");
  await sleep(5000);

  const afterLoad = await cdp.eval(`JSON.stringify({
    hasSelect: !!document.getElementById('financeStatusFilter'),
    selectOptions: [...(document.querySelectorAll('#financeStatusFilter option')||[])].map(o=>o.value),
    costLen: document.getElementById('costReport').innerHTML.length,
    costText: document.getElementById('costReport').textContent.slice(0,120),
    err: document.querySelector('#costReport .err') ? document.querySelector('#costReport .err').textContent.slice(0,120) : ''
  })`);
  console.log("账单页", afterLoad);

  // 打开「用户调用与扣费明细」折叠面板并切到「仅失败」
  const detail = await cdp.eval(`(function(){
    var ds=[...document.querySelectorAll('#costReport details')];
    var d=ds.find(x=>x.textContent.indexOf('用户调用与扣费明细')>=0);
    if(!d) return 'no-details|' + ds.length;
    d.querySelector('summary').click();
    return 'clicked|open=' + d.open + '|total=' + ds.length;
  })()`);
  console.log("明细面板", detail);
  await sleep(2500);

  const setFail = await cdp.eval(`(function(){
    var s=document.getElementById('financeStatusFilter'); if(!s) return 'no-select';
    s.value='failed'; s.dispatchEvent(new Event('change'));
    return 'set-failed';
  })()`);
  console.log("切换失败筛选", setFail);
  await sleep(4000);

  const rows = await cdp.eval(`(function(){
    var box=document.getElementById('financeCalls'); if(!box) return JSON.stringify({err:'no-box'});
    var trs=[...box.querySelectorAll('tbody tr')];
    return JSON.stringify({
      rowCount: trs.length,
      firstRow: trs.length? trs[0].textContent.slice(0,150).replace(/\\s+/g,' ') : '',
      hasEmpty: box.textContent.includes('该条件下没有记录'),
      pager: (box.querySelector('.bill-pages')||{}).textContent ? box.querySelector('.bill-pages').textContent.replace(/\\s+/g,' ').slice(0,60) : ''
    });
  })()`);
  console.log("失败筛选结果", rows);

  // 截图：确保明细面板展开并滚动到位，只截视口
  const shotState = await cdp.eval(`(function(){
    var ds=[...document.querySelectorAll('#costReport details')];
    var d=ds.find(x=>x.textContent.indexOf('用户调用与扣费明细')>=0);
    if(!d) return 'no-d';
    if(!d.open) d.querySelector('summary').click();
    d.scrollIntoView({block:'start'});
    return 'open=' + d.open + '|rows=' + (document.querySelectorAll('#financeCalls tbody tr').length);
  })()`);
  console.log("截图前状态", shotState);
  await sleep(1200);
  const shot = await cdp.send("Page.captureScreenshot", { format: "png" });
  fs.writeFileSync(path.join(OUT, "admin-failure-filter-live.png"), Buffer.from(shot.data, "base64"));
  console.log("截图已保存 admin-failure-filter-live.png");

  ws.close();
  chrome.kill();
  await sleep(500);
  await db.collection("bf_staff").doc(ins.id).remove();
  console.log("临时 admin 已删除");
})().catch(async (e) => {
  console.error("ERR", e.message);
  process.exitCode = 1;
  try { const { execSync } = require("child_process"); execSync("taskkill /F /IM chrome.exe /T", { stdio: "ignore" }); } catch {}
});
