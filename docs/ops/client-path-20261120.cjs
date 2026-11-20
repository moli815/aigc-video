#!/usr/bin/env node
/**
 * 客户端路径回归（用户视角）
 *   额度锁定、失败不退费/不扣费、幂等、过期拦截、管理端账务一致性
 * 目标：不出现 5xx，不出现"扣了钱没出图"，不出现"额度明明有却说没有"
 */
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const ROOT = path.resolve(__dirname, "..");
const OUT = path.join(ROOT, "outputs/client-path-20261120");
const API = "https://xmy-test-d5g8c0xcifcefcfd5-1449098021.ap-shanghai.app.tcloudbase.com";

const hashPwd = (p) => { const s = crypto.randomBytes(16).toString("hex"); return "scrypt$" + s + "$" + crypto.scryptSync(p, s, 64).toString("hex"); };
const results = [];
const rec = (id, name, ok, detail) => { results.push({ id, name, ok, detail }); console.log((ok ? "✓" : "✗"), id, name.padEnd(24), "|", detail); };

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
      username: "cp_" + crypto.randomBytes(3).toString("hex"), passwordHash: hashPwd(PWD), displayName: "路径回归",
      status: "active", tier: "plus", planPriceCny: 166,
      expiresAt: new Date(Date.now() + 30 * 86400000), cycleAnchorAt: new Date(Date.now() - 5 * 86400000),
      periodKey: "smoke", chatUsedCny: 0, imageUsedCny: 0, dayUsedCny: 0, weekUsedCny: 0, proUsedCny: 0,
      createdAt: new Date(Date.now() - 5 * 86400000), note: "temp-cp", failedAttempts: 0, sv: 0,
      costBudgetPolicy: { version: 1, capCny: 50 }, ...over,
    };
    const ins = await db.collection("bf_accounts").add(acc);
    made.push(ins.id);
    return { id: ins.id, username: acc.username, password: PWD, acc };
  };
  const login = async (a) => {
    const r = await fetch(API + "/api/login", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ username: a.username, password: a.password }) });
    const j = await r.json().catch(() => ({}));
    return { status: r.status, token: j.token, body: j };
  };
  const used = async (id) => {
    const a = (await db.collection("bf_accounts").doc(id).get()).data[0];
    return { chat: Number(a.chatUsedCny || 0), image: Number(a.imageUsedCny || 0) };
  };

  try {
    // A 正常对话
    {
      const a = await mkAcc();
      const l = await login(a);
      const r = await fetch(API + "/api/chat", { method: "POST", headers: { "Content-Type": "application/json", Authorization: "Bearer " + l.token }, body: JSON.stringify({ stream: false, messages: [{ role: "user", content: "你好" }] }) });
      rec("A", "正常对话", r.status === 200, "HTTP " + r.status);
    }

    // B 额度耗尽后对话：必须是 4xx 且带可读错误，不能 5xx
    {
      const a = await mkAcc({ chatUsedCny: 9999, imageUsedCny: 9999, dayUsedCny: 9999, weekUsedCny: 9999 });
      const l = await login(a);
      const r = await fetch(API + "/api/chat", { method: "POST", headers: { "Content-Type": "application/json", Authorization: "Bearer " + l.token }, body: JSON.stringify({ stream: false, messages: [{ role: "user", content: "你好" }] }) });
      const j = await r.json().catch(() => ({}));
      const ok = r.status >= 400 && r.status < 500;
      rec("B", "额度耗尽对话", ok, "HTTP " + r.status + " code=" + (j.code || j.error || "-") + " msg=" + String(j.msg || "").slice(0, 24));
    }

    // C 额度耗尽后生图：4xx，且不产生扣费
    {
      const a = await mkAcc({ chatUsedCny: 9999, imageUsedCny: 9999, dayUsedCny: 9999, weekUsedCny: 9999 });
      const l = await login(a);
      const before = await used(a.id);
      const r = await fetch(API + "/img/image", { method: "POST", headers: { "Content-Type": "application/json", Authorization: "Bearer " + l.token }, body: JSON.stringify({ prompt: "测试海报", aspect_ratio: "3:4", size: "1K" }) });
      const j = await r.json().catch(() => ({}));
      const after = await used(a.id);
      const ok = r.status >= 400 && r.status < 500 && Math.abs(after.image - before.image) < 0.001;
      rec("C", "额度耗尽生图", ok, "HTTP " + r.status + " 扣费 " + (after.image - before.image).toFixed(4));
    }

    // D 过期会员：403 且提示可读
    {
      const a = await mkAcc({ expiresAt: new Date(Date.now() - 86400000) });
      const l = await login(a);
      const r = await fetch(API + "/api/chat", { method: "POST", headers: { "Content-Type": "application/json", Authorization: "Bearer " + (l.token || "") }, body: JSON.stringify({ stream: false, messages: [{ role: "user", content: "你好" }] }) });
      const j = await r.json().catch(() => ({}));
      rec("D", "过期会员拦截", r.status === 403, "HTTP " + r.status + " code=" + (j.code || "-"));
    }

    // E 幂等：同一 requestId 连发生图两次，只扣一次
    {
      const a = await mkAcc();
      const l = await login(a);
      const rid = "idem-" + Date.now();
      const body = JSON.stringify({ prompt: "一张简洁的测试海报，纯色背景", aspect_ratio: "1:1", size: "1K", requestId: rid });
      const r1 = await fetch(API + "/img/image", { method: "POST", headers: { "Content-Type": "application/json", Authorization: "Bearer " + l.token }, body });
      await r1.json().catch(() => ({}));
      const u1 = await used(a.id);
      const r2 = await fetch(API + "/img/image", { method: "POST", headers: { "Content-Type": "application/json", Authorization: "Bearer " + l.token }, body });
      const j2 = await r2.json().catch(() => ({}));
      await new Promise(x => setTimeout(x, 2500));
      const u2 = await used(a.id);
      const delta = u2.image - u1.image;
      rec("E", "幂等不重复扣费", Math.abs(delta) < 0.001, "第二次 HTTP " + r2.status + " 增量 " + delta.toFixed(4) + " cached=" + String(j2.cached || j2.code || "-"));
    }

    // F 管理端账务：能查到该账号今日消费
    {
      const a = await mkAcc();
      const l = await login(a);
      await fetch(API + "/api/chat", { method: "POST", headers: { "Content-Type": "application/json", Authorization: "Bearer " + l.token }, body: JSON.stringify({ stream: false, messages: [{ role: "user", content: "你好" }] }) });
      await new Promise(x => setTimeout(x, 2000));
      const u = await used(a.id);
      const rows = (await db.collection("bf_model_calls").where({ accountId: a.id }).limit(20).get()).data || [];
      const sum = rows.reduce((n, r) => n + Number(r.supplierCostEstimateCny || 0), 0);
      const ok = rows.length > 0 && Math.abs(u.chat - sum) < 0.01;
      rec("F", "账务一致性", ok, "账号记 " + u.chat.toFixed(4) + " / 台账合计 " + sum.toFixed(4) + "（" + rows.length + " 笔）");
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
