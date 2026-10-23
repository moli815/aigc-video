#!/usr/bin/env node
/**
 * health-check.js —— 服务端关键链路健康检查（CI 用）
 *
 * 用法：
 *   node scripts/health-check.js <MEMBER_TOKEN> [ACCOUNT]
 *   或通过环境变量：WB_TEST_TOKEN / WB_TEST_ACCOUNT
 *
 * 检查项：
 *   1. bf-api  /api/me            登录态是否有效
 *   2. bf-image /ping             独立生图函数是否存活
 *   3. bf-image /image 无 token    鉴权是否生效（期望 401）
 *   4. bf-api  /api/image          旧路径是否已明确返回"请升级"（期望 503 PLEASE_UPDATE）
 *   5. bf-api  /api/chat           对话链路是否可用（期望返回非空文本）
 *
 * 退出码：0 全部通过；1 有失败项（CI 直接 red）
 * 依赖：Node >= 18（内置 fetch）
 */

const API_BASE = process.env.WB_API_BASE || "https://xmy-test-d5g8c0xcifcefcfd5-1449098021.ap-shanghai.app.tcloudbase.com/api";
const IMG_BASE = process.env.WB_IMG_BASE || "https://xmy-test-d5g8c0xcifcefcfd5-1449098021.ap-shanghai.app.tcloudbase.com/img";
const TIMEOUT_MS = Number(process.env.WB_HEALTH_TIMEOUT_MS || 120000);

// 10-22 P0 安全修复：移除内置默认凭证（此前缺失环境变量时会回退到真实账号密码，
// 而本文件在公开仓库里，等同明文泄露）。现在缺配置就直接失败，绝不使用默认账号。
const token = process.argv[2] || process.env.WB_TEST_TOKEN || "";
const account = process.argv[3] || process.env.WB_TEST_ACCOUNT || "";
const password = process.env.WB_TEST_PASSWORD || "";

if (!token && (!account || !password)) {
  console.error("[health-check] 缺少测试凭证：请设置 WB_TEST_TOKEN，或同时设置 WB_TEST_ACCOUNT / WB_TEST_PASSWORD。");
  console.error("[health-check] 出于安全考虑不再提供内置默认账号；CI 请使用 GitHub Actions Secrets 注入。");
  process.exit(2);
}

const results = [];

function record(name, ok, detail, ms) {
  results.push({ name, ok, detail, ms });
  console.log(`${ok ? "PASS" : "FAIL"} | ${name} | ${ms}ms | ${detail}`);
}

async function withTimeout(promise, ms) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), ms);
  try {
    return await promise(controller.signal);
  } finally {
    clearTimeout(timer);
  }
}

async function login() {
  const t0 = Date.now();
  const r = await fetch(API_BASE + "/login", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ username: account, password }),
  });
  const j = await r.json().catch(() => null);
  const ok = r.ok && j && j.token;
  record("登录 /api/login", !!ok, ok ? "拿到 token" : `status=${r.status}`, Date.now() - t0);
  return ok ? j.token : "";
}

async function checkMe(tok) {
  const t0 = Date.now();
  try {
    const r = await fetch(API_BASE + "/me", { headers: { Authorization: "Bearer " + tok } });
    const j = await r.json().catch(() => null);
    record("/api/me", r.ok && !!j, r.ok ? "账号信息可读" : `status=${r.status}`, Date.now() - t0);
  } catch (e) {
    record("/api/me", false, String(e.message || e).slice(0, 80), Date.now() - t0);
  }
}

async function checkPing() {
  const t0 = Date.now();
  try {
    const r = await fetch(IMG_BASE + "/ping");
    const j = await r.json().catch(() => null);
    record("bf-image /ping", r.ok && j && j.ok, r.ok ? "生图函数存活" : `status=${r.status}`, Date.now() - t0);
  } catch (e) {
    record("bf-image /ping", false, String(e.message || e).slice(0, 80), Date.now() - t0);
  }
}

async function checkImageAuth() {
  const t0 = Date.now();
  try {
    const r = await fetch(IMG_BASE + "/image", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ prompt: "health-check" }),
    });
    record("bf-image 鉴权（无 token）", r.status === 401, `status=${r.status}（期望 401）`, Date.now() - t0);
  } catch (e) {
    record("bf-image 鉴权（无 token）", false, String(e.message || e).slice(0, 80), Date.now() - t0);
  }
}

async function checkLegacyImage(tok) {
  const t0 = Date.now();
  try {
    const r = await fetch(API_BASE + "/image", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: "Bearer " + tok },
      body: JSON.stringify({ prompt: "health-check" }),
    });
    const j = await r.json().catch(() => null);
    const ok = r.status === 503 && j && j.error === "PLEASE_UPDATE";
    record("旧路径 /api/image 提示升级", !!ok, `status=${r.status} error=${j && j.error}`, Date.now() - t0);
  } catch (e) {
    record("旧路径 /api/image 提示升级", false, String(e.message || e).slice(0, 80), Date.now() - t0);
  }
}

async function checkChat(tok) {
  const t0 = Date.now();
  try {
    const r = await withTimeout((signal) => fetch(API_BASE + "/chat", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: "Bearer " + tok },
      body: JSON.stringify({
        messages: [{ role: "user", content: "用一句话说明什么是复利" }],
        chatMode: "standard",
        stream: false,
      }),
      signal,
    }), TIMEOUT_MS);
    const j = await r.json().catch(() => null);
    const text = (j && j.choices && j.choices[0] && j.choices[0].message && j.choices[0].message.content) || "";
    record("对话 /api/chat", r.ok && text.length > 5, text.slice(0, 40) || `status=${r.status}`, Date.now() - t0);
  } catch (e) {
    record("对话 /api/chat", false, String(e.message || e).slice(0, 80), Date.now() - t0);
  }
}

(async () => {
  console.log("=== WorkBuddy health-check 开始 ===");
  let tok = token;
  if (!tok) tok = await login();
  if (tok) {
    await checkMe(tok);
    await checkChat(tok);
    await checkLegacyImage(tok);
  }
  await checkPing();
  await checkImageAuth();

  const failed = results.filter((r) => !r.ok);
  console.log(`=== 完成：${results.length - failed.length}/${results.length} 通过 ===`);
  if (failed.length) {
    console.error("失败项：" + failed.map((f) => f.name).join(", "));
    process.exit(1);
  }
  process.exit(0);
})().catch((e) => {
  console.error("health-check 异常：", e);
  process.exit(1);
});
