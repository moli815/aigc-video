"use strict";
// 2026-11-22 上线后全量回归（接口级）
// 覆盖：健康检查 / 未登录拒绝 / 素材超限提示 / 正常素材上传 / 普通对话不被海报契约污染
const path = require("path");
const crypto = require("crypto");

const ROOT = path.join(__dirname, "..");
const API = "https://xmy-test-d5g8c0xcifcefcfd5-1449098021.ap-shanghai.app.tcloudbase.com";

async function login() {
  const c = await require(path.join(ROOT, "scripts/image-workflow-eval-lib-20261111.cjs")).connect();
  const PWD = crypto.randomBytes(10).toString("hex");
  const salt = crypto.randomBytes(16).toString("hex");
  const acc = {
    username: "rf_" + crypto.randomBytes(3).toString("hex"),
    passwordHash: "scrypt$" + salt + "$" + crypto.scryptSync(PWD, salt, 64).toString("hex"),
    displayName: "回归", status: "active", tier: "plus", planPriceCny: 166,
    expiresAt: new Date(Date.now() + 30 * 86400000), cycleAnchorAt: new Date(Date.now() - 5 * 86400000),
    periodKey: "smoke", chatUsedCny: 0, imageUsedCny: 0, dayUsedCny: 0, weekUsedCny: 0, proUsedCny: 0,
    createdAt: new Date(Date.now() - 5 * 86400000), note: "temp-refguard", failedAttempts: 0, sv: 0,
    costBudgetPolicy: { version: 1, capCny: 60 },
  };
  const ins = await c.db.collection("bf_accounts").add(acc);
  const id = ins && (ins.id || (ins.ids && ins.ids[0]));
  const lr = await fetch(API + "/api/login", {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ username: acc.username, password: PWD }),
  });
  const token = (await lr.json()).token;
  return { token, id, db: c.db, username: acc.username };
}

(async () => {
  const out = [];
  const acc = await login();
  const auth = { "Content-Type": "application/json", Authorization: "Bearer " + acc.token };

  // 1) 健康检查
  for (const p of ["/api/health", "/img/ping"]) {
    const r = await fetch(API + p, { signal: AbortSignal.timeout(20000) });
    out.push({ case: "健康检查 " + p, status: r.status, ok: r.status === 200 });
  }

  // 2) 未登录必须 401
  {
    const r = await fetch(API + "/api/chat/completions", {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ messages: [] }),
    });
    out.push({ case: "未登录拒绝", status: r.status, ok: r.status === 401 });
  }

  // 3) 超限素材：应给出带 MB 数字的明确文案
  {
    const r = await fetch(API + "/api/assets/prepare", {
      method: "POST", headers: auth,
      body: JSON.stringify({ sha256: "b".repeat(64), byteCount: 30 * 1024 * 1024, mime: "image/jpeg" }),
    });
    const j = await r.json().catch(() => ({}));
    const msg = String(j.message || j.msg || "");
    out.push({
      case: "超限素材提示", status: r.status, code: j.error || "",
      message: msg, ok: r.status === 422 && /30MB/.test(msg) && /24MB/.test(msg) && /压缩/.test(msg),
    });
  }

  // 4) 正常体积素材：应签发上传凭证（回归）
  {
    const r = await fetch(API + "/api/assets/prepare", {
      method: "POST", headers: auth,
      body: JSON.stringify({ sha256: "c".repeat(64), byteCount: 2 * 1024 * 1024, mime: "image/jpeg" }),
    });
    const j = await r.json().catch(() => ({}));
    out.push({ case: "正常素材签发", status: r.status, ok: r.status === 200 && !!j.upload });
  }

  // 5) 普通配图：prompt 不得被追加海报排版契约
  {
    const body = {
      messages: [{ role: "user", content: "画一只橘猫趴在窗台上晒太阳" }],
      tools: [{ type: "function", function: { name: "image_generate", parameters: { type: "object", properties: { prompt: { type: "string" } } } } }],
      stream: true,
    };
    const r = await fetch(API + "/api/chat/completions", {
      method: "POST", headers: auth, body: JSON.stringify(body), signal: AbortSignal.timeout(90000),
    });
    const text = await r.text();
    const polluted = /以下文字必须逐字照写|风格：信息密集/.test(text);
    const called = /image_generate/.test(text);
    out.push({ case: "普通配图不被污染", status: r.status, toolCalled: called, polluted, ok: r.status === 200 && !polluted });
  }

  try { if (acc.id) await acc.db.collection("bf_accounts").doc(String(acc.id)).remove(); } catch {}
  console.log(JSON.stringify(out, null, 1));
  const failed = out.filter((x) => !x.ok);
  console.log(failed.length ? "FAILED: " + failed.map((f) => f.case).join(", ") : "ALL PASS");
})().catch((e) => { console.error("ERR", e.message); process.exit(1); });
