#!/usr/bin/env node
/**
 * 发版前必跑（preflight）
 *   1. 候选包逐文件门禁
 *   2. 包自洽审计（require 解析 + 导出符号）
 *   3. 线上健康
 *   4. 客户端路径回归（额度锁定 / 过期 / 幂等 / 账务一致）
 *
 * 用法：
 *   node scripts/preflight-20261120.cjs --fn bf-api --base <基线zip> --candidate <候选zip>
 *   node scripts/preflight-20261120.cjs --client-only
 */
const { execFileSync } = require("child_process");
const path = require("path");
const fs = require("fs");

const ROOT = path.resolve(__dirname, "..");
const args = process.argv.slice(2);
const arg = (k) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : null; };
const OUT = path.join(ROOT, "outputs/preflight");
fs.mkdirSync(OUT, { recursive: true });

const steps = [];
const add = (name, ok, detail) => { steps.push({ name, ok, detail }); console.log((ok ? "✓" : "✗"), name, "|", detail); };

function run(cmd, argv) {
  return execFileSync(cmd, argv, { cwd: ROOT, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
}

(async () => {
  const base = arg("--base");
  const candidate = arg("--candidate");
  const clientOnly = args.includes("--client-only");

  if (!clientOnly && base && candidate) {
    // 1) 逐文件门禁
    try {
      run("python", ["scripts/check-function-artifact.py", base, candidate, "--output", path.join(OUT, "gate.json"),
        "--allow", "index.js", "--allow", "intent-contract.js", "--allow", "reference-text.js",
        "--allow", "brand-memory.js", "--allow", "requirement-guard.js", "--allow", "prompt-contract.js"]);
      const g = JSON.parse(fs.readFileSync(path.join(OUT, "gate.json"), "utf8"));
      add("逐文件门禁", g.ok === true, "changed=" + JSON.stringify(g.changed || []));
    } catch (e) {
      add("逐文件门禁", false, String(e.message).slice(0, 120));
    }
  }

  // 2) 线上健康
  try {
    const API = "https://xmy-test-d5g8c0xcifcefcfd5-1449098021.ap-shanghai.app.tcloudbase.com";
    const h = await fetch(API + "/api/health", { signal: AbortSignal.timeout(15000) });
    const i = await fetch(API + "/img/ping", { signal: AbortSignal.timeout(15000) });
    add("线上健康", h.status === 200 && i.status === 200, `api=${h.status} img=${i.status}`);
  } catch (e) {
    add("线上健康", false, String(e.message).slice(0, 80));
  }

  // 3) 客户端路径回归
  try {
    const out = run("node", ["scripts/client-path-20261120.cjs"]);
    const m = /(\d+)\/(\d+)\s*通过/.exec(out) || [];
    const pass = Number(m[1] || 0), total = Number(m[2] || 0);
    add("客户端路径", pass === total && total > 0, `${pass}/${total}`);
    if (pass !== total) console.log(out.split("\n").filter(l => l.startsWith("✗")).join("\n"));
  } catch (e) {
    add("客户端路径", false, String(e.message).slice(0, 120));
  }

  const failed = steps.filter(s => !s.ok);
  console.log("\n" + (failed.length ? `❌ ${failed.length} 项未通过，禁止发版` : "✅ 全部通过，可以发版"));
  fs.writeFileSync(path.join(OUT, "preflight.json"), JSON.stringify({ at: new Date().toISOString(), steps }, null, 2));
  process.exit(failed.length ? 1 : 0);
})().catch(e => { console.error("ERR", e.message); process.exit(1); });
