#!/usr/bin/env node
/**
 * 健壮性测试（robustness）
 * 目标：用户异常操作或弱网时，不出现 5xx、不误扣费、不产生挂起账。
 * 原则：能靠参数校验失败的用例不花钱；只在必要处真出图。
 */
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const ROOT = path.resolve(__dirname, "..");
const OUT = path.join(ROOT, "outputs/robustness-20261120");
const API = "https://xmy-test-d5g8c0xcifcefcfd5-1449098021.ap-shanghai.app.tcloudbase.com";
const PHOTO = path.join(ROOT, "outputs/p0-2-hard-20261120/assets/brand-photo.jpg");

const hashPwd = (p) => { const s = crypto.randomBytes(16).toString("hex"); return "scrypt$" + s + "$" + crypto.scryptSync(p, s, 64).toString("hex"); };
const results = [];
const rec = (id, name, ok, detail) => { results.push({ id, name, ok, detail: String(detail) }); console.log((ok ? "✓" : "✗"), id, name.padEnd(26), "|", detail); };

async function main() {
  fs.mkdirSync(OUT, { recursive: true });
  const cred = JSON.parse(fs.readFileSync(path.join(process.env.USERPROFILE, ".config/.cloudbase/auth.json"), "utf8")).credential;
  const app = require(path.join(ROOT, "cloudfunctions/bf-api/node_modules/@cloudbase/node-sdk")).init({
    env: "xmy-test-d5g8c0xcifcefcfd5", region: "ap-shanghai",
    secretId: cred.tmpSecretId, secretKey: cred.tmpSecretKey, sessionToken: cred.tmpToken,
  });
  const db = app.database();
  const made = [];

  const mkAcc = async (over = {}) => {
    const PWD = crypto.randomBytes(10).toString("hex");
    const acc = {
      username: "rb_" + crypto.randomBytes(3).toString("hex"), passwordHash: hashPwd(PWD), displayName: "健壮性",
      status: "active", tier: "plus", planPriceCny: 166,
      expiresAt: new Date(Date.now() + 30 * 86400000), cycleAnchorAt: new Date(Date.now() - 5 * 86400000),
      periodKey: "smoke", chatUsedCny: 0, imageUsedCny: 0, dayUsedCny: 0, weekUsedCny: 0, proUsedCny: 0,
      createdAt: new Date(Date.now() - 5 * 86400000), note: "temp-rb", failedAttempts: 0, sv: 0,
      costBudgetPolicy: { version: 1, capCny: 50 }, ...over,
    };
    const ins = await db.collection("bf_accounts").add(acc);
    made.push(ins.id);
    return { id: ins.id, username: acc.username, password: PWD };
  };
  const login = async (a) => {
    const r = await fetch(API + "/api/login", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ username: a.username, password: a.password }) });
    const j = await r.json().catch(() => ({}));
    return j.token;
  };
  const usedImg = async (id) => Number(((await db.collection("bf_accounts").doc(id).get()).data[0] || {}).imageUsedCny || 0);
  const P = (t) => fetch(API + "/api/chat", { method: "POST", headers: { "Content-Type": "application/json", Authorization: "Bearer " + t }, body: JSON.stringify({ stream: false, messages: [{ role: "user", content: "hi" }] }) });

  try {
    const a = await mkAcc();
    const token = await login(a);
    const H = { "Content-Type": "application/json", Authorization: "Bearer " + token };
    const not5xx = (s) => s < 500;

    // R1 空 body
    { const r = await fetch(API + "/api/chat", { method: "POST", headers: H, body: "{}" }); rec("R1", "空请求体", not5xx(r.status), "HTTP " + r.status); }

    // R2 非法 JSON
    { const r = await fetch(API + "/api/chat", { method: "POST", headers: H, body: "{oops" }); rec("R2", "非法 JSON", not5xx(r.status), "HTTP " + r.status); }

    // R3 无 token
    { const r = await fetch(API + "/api/chat", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ messages: [] }) }); rec("R3", "缺 token", r.status === 401, "HTTP " + r.status); }

    // R4 伪造 token
    { const r = await fetch(API + "/api/chat", { method: "POST", headers: { "Content-Type": "application/json", Authorization: "Bearer forged.token.value" }, body: JSON.stringify({ messages: [] }) }); rec("R4", "伪造 token", r.status === 401 || r.status === 403, "HTTP " + r.status); }

    // R5 非法比例
    { const r = await fetch(API + "/img/image", { method: "POST", headers: H, body: JSON.stringify({ prompt: "测试", aspect_ratio: "7:13", size: "1K" }) }); const j = await r.json().catch(() => ({})); rec("R5", "非法比例 7:13", not5xx(r.status), "HTTP " + r.status + " " + (j.code || j.error || "")); }

    // R6 非法 size
    { const r = await fetch(API + "/img/image", { method: "POST", headers: H, body: JSON.stringify({ prompt: "测试", size: "abc" }) }); rec("R6", "非法 size", not5xx(r.status), "HTTP " + r.status); }

    // R7 空 prompt
    { const r = await fetch(API + "/img/image", { method: "POST", headers: H, body: JSON.stringify({ prompt: "", size: "1K" }) }); rec("R7", "空 prompt", not5xx(r.status), "HTTP " + r.status); }

    // R8 超长 prompt（6000 字）
    { const r = await fetch(API + "/img/image", { method: "POST", headers: H, body: JSON.stringify({ prompt: "海报".repeat(3000), size: "1K" }) }); const j = await r.json().catch(() => ({})); rec("R8", "超长 prompt", not5xx(r.status), "HTTP " + r.status + " " + (j.code || j.error || "")); }

    // R9 超大附件（≈3MB base64）
    {
      const big = "data:image/jpeg;base64," + fs.readFileSync(PHOTO).toString("base64");
      const r = await fetch(API + "/api/chat", { method: "POST", headers: H, body: JSON.stringify({ stream: false, messages: [{ role: "user", content: [{ type: "text", text: "看图" }, { type: "image_url", image_url: { url: big } }, { type: "image_url", image_url: { url: big } }] }] }) });
      rec("R9", "多图 2 张", not5xx(r.status), "HTTP " + r.status);
    }

    // R10 并发同 requestId：只扣一次
    {
      const b = await mkAcc(); const t = await login(b); const H2 = { "Content-Type": "application/json", Authorization: "Bearer " + t };
      const rid = "rb-" + Date.now();
      const body = JSON.stringify({ prompt: "纯色背景的极简测试图", aspect_ratio: "1:1", size: "1K", requestId: rid });
      const rs = await Promise.all([1, 2, 3].map(() => fetch(API + "/img/image", { method: "POST", headers: H2, body })));
      await new Promise(x => setTimeout(x, 4000));
      const c = await usedImg(b.id);
      const one = 0.24; // 1K 档估值，只判"是否重复扣"
      rec("R10", "并发同 requestId", c < one * 2.2, "3 次并发，扣费合计 " + c.toFixed(4));
    }

    // R11 管理端接口越权
    {
      const r = await fetch(API + "/api/admin/accounts", { headers: H });
      rec("R11", "普通用户访问管理端", r.status === 401 || r.status === 403 || r.status === 404, "HTTP " + r.status);
    }

    // R12 流式对话中途断开：不产生挂起账
    {
      const ac = new AbortController();
      const r = await fetch(API + "/api/chat", { method: "POST", headers: { ...H, Accept: "text/event-stream" }, body: JSON.stringify({ stream: true, messages: [{ role: "user", content: "讲个长一点的故事" }] }), signal: ac.signal });
      const reader = r.body.getReader();
      await reader.read();
      ac.abort();
      // 断流后服务端仍会把上游读完并结算，通常 30s 内 pending → committed；
      // 这里轮询到 45s，只判定「是否留下长期挂起」。
      let pending = -1, calls = [];
      for (const wait of [2, 8, 15, 20]) {
        await new Promise(x => setTimeout(x, wait * 1000));
        calls = (await db.collection("bf_model_calls").where({ accountId: a.id }).limit(20).get()).data || [];
        pending = calls.filter(c => c.status === "pending").length;
        if (pending === 0) break;
      }
      rec("R12", "流式中途断开", pending === 0, "挂起 " + pending + " 笔，总记录 " + calls.length + "（轮询至 45s）");
    }

    const pass = results.filter(r => r.ok).length;
    console.log("\n" + pass + "/" + results.length + " 通过");
    fs.writeFileSync(path.join(OUT, "results.json"), JSON.stringify({ at: new Date().toISOString(), pass, total: results.length, results }, null, 2));
  } finally {
    for (const id of made) { try { await db.collection("bf_accounts").doc(id).remove(); } catch {} }
    console.log("临时账号已清理", made.length, "个");
  }
}
main().catch(e => console.error("ERR", e.message));
