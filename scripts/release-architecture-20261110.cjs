"use strict";
// Reproducible, rollback-capable release for the 2026-11-10 architecture candidate.
// Uses current online ZIPs as base, so live dependency trees and later patches survive.
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const cp = require("child_process");
const ROOT = path.resolve(__dirname, "..");
const OUT = path.join(ROOT, "outputs/release-20261110");
const NS = "xmy-test-d5g8c0xcifcefcfd5";
const API_BASE = "https://xmy-test-d5g8c0xcifcefcfd5-1449098021.ap-shanghai.app.tcloudbase.com";
const STATIC_BASE = "https://xmy-test-d5g8c0xcifcefcfd5-1449098021.tcloudbaseapp.com";
const TCB_CLI = "C:/Users/24072/AppData/Roaming/npm/node_modules/@cloudbase/cli/bin/tcb";
function runTcb(args) {
  const result = cp.spawnSync(process.execPath, [TCB_CLI, ...args], { cwd: ROOT, encoding: "utf8", timeout: 240000 });
  const output = (result.stdout || "") + (result.stderr || "");
  writeOut("tcb-last-output.txt", output);
  if (result.status !== 0) throw new Error("TCB_FAILED_" + result.status + ":" + output.slice(-1000));
  return result.stdout;
}
const COMMIT = "1f5ccf1fa81fa0832bb45e0ebd73e67b1175569c";
const one = r => Array.isArray(r?.data) ? r.data[0] : r?.data;
const sha = bytes => crypto.createHash("sha256").update(bytes).digest("hex");
const read = rel => fs.readFileSync(path.join(ROOT, rel));
const json = rel => JSON.parse(fs.readFileSync(path.join(ROOT, rel), "utf8"));
const writeOut = (name, value) => fs.writeFileSync(path.join(OUT, name), typeof value === "string" ? value : JSON.stringify(value, null, 2) + "\n");
const credentials = JSON.parse(fs.readFileSync(path.join(process.env.USERPROFILE, ".config/.cloudbase/auth.json"), "utf8")).credential;
const scfSdk = require("../outputs/commercial-text-repair-20261104/ops-tools/node_modules/tencentcloud-sdk-nodejs-scf");
const scf = new scfSdk.scf.v20180416.Client({
  credential: { secretId: credentials.tmpSecretId, secretKey: credentials.tmpSecretKey, token: credentials.tmpToken },
  region: "ap-shanghai", profile: { httpProfile: { reqTimeout: 180 } },
});
const app = require("../cloudfunctions/bf-api/node_modules/@cloudbase/node-sdk").init({
  env: NS, region: "ap-shanghai", secretId: credentials.tmpSecretId,
  secretKey: credentials.tmpSecretKey, sessionToken: credentials.tmpToken,
});
const db = app.database();
const REPLACEMENTS = {
  "bf-api": [
    "approval-fulfillment.js", "commercial-chat-review.js", "expert-catalog.js",
    "experts.json", "index.js", "settings-schema.js",
  ],
  "bf-image": ["image-billing.js", "image-execution-gate.js", "index.js"],
};
const STATIC_FILES = ["admin.html", "staff.html"];

async function waitFunctionReady(name) {
  let fn;
  for (let i = 0; i < 45; i++) {
    fn = await scf.GetFunction({ FunctionName: name, Namespace: NS });
    if (fn.Status === "UpdateFailed") throw new Error("UPDATE_FAILED:" + name);
    if (fn.Status === "Active" && fn.InstallDependency === "FALSE") return fn;
    await new Promise(r => setTimeout(r, 2000));
  }
  throw new Error("FUNCTION_NOT_READY:" + name);
}
async function codeZip(name) {
  await waitFunctionReady(name);
  const address = await scf.GetFunctionAddress({ FunctionName: name, Namespace: NS });
  const response = await fetch(address.Url, { signal: AbortSignal.timeout(120000) });
  if (!response.ok) throw new Error("CODE_DOWNLOAD_FAILED:" + name);
  const bytes = Buffer.from(await response.arrayBuffer());
  if (bytes.subarray(0, 2).toString("hex") !== "504b") throw new Error("CODE_NOT_ZIP:" + name);
  return { bytes, codeSha256: address.CodeSha256 || "" };
}
function artifactCheck(before, candidate, output, allowed = []) {
  const args = ["scripts/check-function-artifact.py", before, candidate, "--output", output];
  for (const p of allowed) args.push("--allow", p);
  cp.execFileSync("python", args, { cwd: ROOT, stdio: "pipe" });
  return json(path.relative(ROOT, output).replace(/\\/g, "/"));
}
function buildCandidate(name, beforePath, candidatePath, changesPath) {
  const mapping = Object.fromEntries(REPLACEMENTS[name].map(file => [file, `cloudfunctions/${name}/${file}`]));
  writeOut(changesPath, mapping);
  const helper = "scripts/replace-function-zip-entries.py";
  cp.execFileSync("python", [helper, beforePath, candidatePath, path.join(OUT, changesPath)], { cwd: ROOT, stdio: "pipe" });
}
async function waitActive(name, expectedChange = true, baselineModTime = "") {
  let fn;
  for (let i = 0; i < 45; i++) {
    fn = await scf.GetFunction({ FunctionName: name, Namespace: NS });
    if (fn.Status === "UpdateFailed") throw new Error("UPDATE_FAILED:" + name);
    const changed = !expectedChange || !baselineModTime || fn.ModTime !== baselineModTime;
    if (fn.Status === "Active" && fn.InstallDependency === "FALSE" && changed) return fn;
    await new Promise(r => setTimeout(r, 2000));
  }
  throw new Error("FUNCTION_NOT_READY:" + name);
}
async function uploadCode(name, zipPath) {
  await scf.UpdateFunctionCode({ FunctionName: name, Namespace: NS,
    ZipFile: fs.readFileSync(zipPath).toString("base64"), InstallDependency: "FALSE", CodeSource: "ZipFile" });
}

async function prepare() {
  fs.mkdirSync(OUT, { recursive: true });
  const functions = {};
  for (const name of Object.keys(REPLACEMENTS)) {
    const fn = await scf.GetFunction({ FunctionName: name, Namespace: NS });
    if (fn.Status !== "Active" || fn.InstallDependency !== "FALSE") throw new Error("BASELINE_NOT_READY:" + name);
    const downloaded = await codeZip(name);
    const before = path.join(OUT, `before-${name}.zip`);
    const candidate = path.join(OUT, `candidate-${name}.zip`);
    const changes = `changes-${name}.json`;
    fs.writeFileSync(before, downloaded.bytes);
    buildCandidate(name, before, candidate, changes);
    const gatePath = path.join(OUT, `gate-${name}.json`);
    const gate = artifactCheck(before, candidate, gatePath, REPLACEMENTS[name]);
    if (!gate.ok || gate.dependencyChanges.length || gate.unexpected.length) throw new Error("ARTIFACT_GATE_FAILED:" + name);
    functions[name] = { status: fn.Status, modTime: fn.ModTime, installDependency: fn.InstallDependency,
      codeSha256: downloaded.codeSha256, beforeSha256: sha(downloaded.bytes), candidateSha256: sha(fs.readFileSync(candidate)),
      changed: gate.changed, fileCount: gate.candidateFileCount };
  }
  const experts = one(await db.collection("bf_config").doc("experts").get());
  const runtime = one(await db.collection("bf_config").doc("runtime").get());
  writeOut("config-before.json", { at: new Date(), experts,
    runtime: { version: runtime.version, revision: runtime.revision, updatedAt: runtime.updatedAt,
      CHAT_STYLE_POLICY: runtime.data?.CHAT_STYLE_POLICY || null,
      CHAT_GROUNDED_REVIEW: runtime.data?.CHAT_GROUNDED_REVIEW || null,
      CAP_IMAGE_ENABLED: runtime.data?.CAP_IMAGE_ENABLED || null } });
  const oldSeed = JSON.parse(cp.execFileSync("git", ["-C", ROOT, "show", "e73d5e2:cloudfunctions/bf-api/experts.json"], { encoding: "utf8" }));
  writeOut("old-expert-seed.json", oldSeed);
  const staticBefore = {};
  for (const file of STATIC_FILES) {
    const response = await fetch(`${STATIC_BASE}/${file}?release=${Date.now()}`, { cache: "no-store", signal: AbortSignal.timeout(60000) });
    if (!response.ok) throw new Error("STATIC_BACKUP_FAILED:" + file);
    const bytes = Buffer.from(await response.arrayBuffer());
    fs.writeFileSync(path.join(OUT, `before-${file}`), bytes);
    staticBefore[file] = sha(bytes);
  }
  const report = { at: new Date(), commit: COMMIT, namespace: NS, functions, staticBefore,
    expertVersion: experts.version, runtimeRevision: runtime.revision || null };
  writeOut("prepare.json", report);
  console.log(JSON.stringify({ mode: "prepare", functions: Object.keys(functions), expertVersion: experts.version, staticFiles: STATIC_FILES }, null, 2));
}

async function verifyRemoteStatic() {
  const result = {};
  for (const file of STATIC_FILES) {
    const expected = sha(read(`web/${file}`));
    let actual = "";
    for (let i = 0; i < 2 && actual !== expected; i++) {
      const response = await fetch(`${STATIC_BASE}/${file}?v=${Date.now()}-${i}`, { cache: "no-store", signal: AbortSignal.timeout(60000) });
      if (!response.ok) throw new Error("STATIC_VERIFY_HTTP:" + file);
      actual = sha(Buffer.from(await response.arrayBuffer()));
    }
    if (actual !== expected) throw new Error("STATIC_HASH_MISMATCH:" + file);
    result[file] = actual;
  }
  return result;
}

async function updateConfig() {
  const backup = json("outputs/release-20261110/config-before.json");
  const oldSeed = json("outputs/release-20261110/old-expert-seed.json");
  const newSeed = json("cloudfunctions/bf-api/experts.json");
  const oldById = new Map(oldSeed.experts.map(e => [e.id, e]));
  const newById = new Map(newSeed.experts.map(e => [e.id, e]));
  const result = await db.runTransaction(async tx => {
    const expertsRef = tx.collection("bf_config").doc("experts");
    const runtimeRef = tx.collection("bf_config").doc("runtime");
    const live = one(await expertsRef.get());
    const rt = one(await runtimeRef.get());
    if (!live || !rt || live.version !== backup.experts.version) throw new Error("CONFIG_CHANGED");
    let changed = 0, skipped = 0;
    const experts = live.experts.map(expert => {
      const before = oldById.get(expert.id), after = newById.get(expert.id);
      if (!before || !after) { skipped++; return expert; }
      const oldSteps = JSON.stringify(expert.steps || []) === JSON.stringify(before.steps || []);
      const oldChecklist = JSON.stringify(expert.checklist || []) === JSON.stringify(before.checklist || []);
      if (!oldSteps || !oldChecklist) { skipped++; return expert; }
      changed++;
      return { ...expert, steps: after.steps, checklist: after.checklist };
    });
    const at = new Date();
    const version = Number(live.version || 0) + 1;
    const patch = { experts, version, catalogRevision: version, seedVersion: 5,
      baseSeedHash: live.seedHash || backup.experts.seedHash || "", origin: "admin",
      updatedAt: at, updatedBy: "release-architecture-20261110" };
    await expertsRef.update(patch);
    const runtimePatch = { "data.CHAT_GROUNDED_REVIEW": '{"enabled":false,"audience":"all"}',
      updatedAt: at, revision: String(at.getTime()) };
    await runtimeRef.update(runtimePatch);
    return { version, catalogRevision: version, changed, skipped, at };
  });
  writeOut("config-release.json", result);
  return result;
}

async function deployStatic() {
  const staging = path.join(OUT, "hosting");
  const rollback = path.join(OUT, "rollback-hosting");
  fs.mkdirSync(staging, { recursive: true });
  fs.mkdirSync(rollback, { recursive: true });
  for (const file of STATIC_FILES) {
    fs.copyFileSync(path.join(ROOT, "web", file), path.join(staging, file));
    fs.copyFileSync(path.join(OUT, `before-${file}`), path.join(rollback, file));
  }
  const stdout = runTcb(["hosting", "deploy", staging, ".", "-e", NS,
    "--concurrency", "1", "--entry", STATIC_FILES.join(","), "--json"]);
  writeOut("hosting-deploy.json", stdout);
  const hashes = await verifyRemoteStatic();
  writeOut("hosting-hashes.json", hashes);
  return hashes;
}

async function httpVerification() {
  const id = "release_http_" + crypto.randomBytes(6).toString("hex");
  const password = crypto.randomBytes(24).toString("hex");
  const salt = crypto.randomBytes(16).toString("hex");
  const now = new Date();
  let created = false, token = "";
  const report = { at: new Date(), checks: [], paidChatCalls: 0, paidImageCalls: 0, customerQuotaChanged: false, temporaryAccountDeleted: false };
  async function request(route, body) {
    const response = await fetch(API_BASE + route, { method: body ? "POST" : "GET",
      headers: { "Content-Type": "application/json", ...(token ? { Authorization: "Bearer " + token } : {}) },
      body: body ? JSON.stringify(body) : undefined, signal: AbortSignal.timeout(90000) });
    const text = await response.text();
    let value; try { value = JSON.parse(text); } catch {}
    return { status: response.status, text, value };
  }
  try {
    const health = await request("/api/health"); if (health.status !== 200) throw new Error("HEALTH_NOT_200"); report.checks.push("api health 200");
    const ping = await request("/img/ping"); if (ping.status !== 200 || ping.value?.ok !== true) throw new Error("IMAGE_PING_NOT_OK"); report.checks.push("image ping 200");
    const anonymous = await request("/api/experts"); if (anonymous.status !== 401) throw new Error("ANONYMOUS_CATALOG_NOT_401"); report.checks.push("anonymous catalog 401");
    const runtime = one(await db.collection("bf_config").doc("runtime").get());
    const grounded = JSON.parse(runtime.data?.CHAT_GROUNDED_REVIEW || '{"enabled":false}');
    const style = JSON.parse(runtime.data?.CHAT_STYLE_POLICY || '{"enabled":false}');
    if (grounded.enabled === true || style.enabled === true) throw new Error("UNACCEPTED_POLICY_ENABLED");
    report.checks.push("grounded review and candidate style disabled");
    await db.collection("bf_accounts").doc(id).set({ username: id, displayName: "发布验证临时账号", status: "active",
      tier: "ultra", expiresAt: new Date(Date.now() + 1800000), createdAt: now, cycleAnchorAt: now,
      quotaOverrideCny: 5, pwv: 0, sv: 0, chatUsedCny: 0, imageUsedCny: 0,
      passwordHash: "scrypt$" + salt + "$" + crypto.scryptSync(password, salt, 64).toString("hex") });
    created = true;
    const login = await request("/api/login", { username: id, password });
    if (login.status !== 200 || !login.value?.token) throw new Error("LOGIN_FAILED");
    token = login.value.token; report.checks.push("temporary login 200");
    const catalog = await request("/api/experts");
    if (catalog.status !== 200 || catalog.value?.experts?.length !== 16) throw new Error("CATALOG_INVALID");
    if (catalog.value.experts.find(e => e.id === "short_video").steps.some(s => s.startsWith("给 3 个"))) throw new Error("OLD_TEMPLATE_LIVE");
    report.expertVersion = catalog.value.version; report.catalogRevision = catalog.value.catalogRevision;
    report.checks.push("authorized 16-expert catalog 200");
    const streamed = await request("/api/chat", { chatMode: "standard", stream: true, max_tokens: 24,
      messages: [{ role: "user", content: "只回复OK，不要解释。" }] });
    report.paidChatCalls++;
    if (streamed.status !== 200 || !streamed.text.includes("data: [DONE]")) throw new Error("SSE_CONTRACT_FAILED");
    let output = "";
    for (const line of streamed.text.split("\n")) {
      if (!line.startsWith("data: ") || line === "data: [DONE]") continue;
      const frame = JSON.parse(line.slice(6));
      if (frame.error) throw new Error("SSE_ERROR_FRAME");
      output += frame.choices?.[0]?.delta?.content || "";
    }
    if (!output.trim()) throw new Error("SSE_EMPTY_CONTENT");
    report.checks.push("real SSE JSON frames and DONE");
    await db.collection("bf_accounts").doc(id).update({ expiresAt: new Date(Date.now() - 1000) });
    const expired = await request("/api/chat", { stream: false, messages: [{ role: "user", content: "测试" }] });
    if (expired.status !== 403) throw new Error("EXPIRED_NOT_403"); report.checks.push("expired membership 403");
    await db.collection("bf_accounts").doc(id).update({ expiresAt: new Date(Date.now() + 1800000), quotaOverrideCny: 0.01, chatUsedCny: 1 });
    const quota = await request("/api/chat", { stream: false, messages: [{ role: "user", content: "测试" }] });
    if (quota.status !== 429) throw new Error("QUOTA_NOT_429"); report.checks.push("exhausted quota 429");
    report.ok = true;
  } finally {
    if (created) { await db.collection("bf_accounts").doc(id).remove(); report.temporaryAccountDeleted = true; }
    writeOut("http-verification.json", report);
  }
  return report;
}

async function rollback(state) {
  const report = { at: new Date(), functions: [], config: false, staticPages: false };
  for (const name of [...state.deployedFunctions].reverse()) {
    try {
      await uploadCode(name, path.join(OUT, `before-${name}.zip`));
      const fn = await waitActive(name, false);
      report.functions.push({ name, status: fn.Status, modTime: fn.ModTime, installDependency: fn.InstallDependency });
    } catch (error) { report.functions.push({ name, error: String(error.message || error) }); }
  }
  if (state.configWritten) {
    const backup = json("outputs/release-20261110/config-before.json");
    const previousExperts = { ...backup.experts };
    delete previousExperts._id;
    await db.collection("bf_config").doc("experts").set(previousExperts);
    await db.collection("bf_config").doc("runtime").update({
      "data.CHAT_GROUNDED_REVIEW": backup.runtime.CHAT_GROUNDED_REVIEW || "",
      updatedAt: backup.runtime.updatedAt, revision: backup.runtime.revision || "",
    });
    report.config = true;
  }
  if (state.staticUploaded) {
    runTcb(["hosting", "deploy", path.join(OUT, "rollback-hosting"), ".", "-e", NS,
      "--concurrency", "1", "--entry", STATIC_FILES.join(","), "--json"]);
    report.staticPages = true;
  }
  writeOut("rollback.json", report);
  return report;
}

async function waitCode(name, previousModTime) {
  let fn;
  for (let i = 0; i < 45; i++) {
    fn = await scf.GetFunction({ FunctionName: name, Namespace: NS });
    if (fn.Status === "UpdateFailed") throw new Error("UPDATE_FAILED:" + name);
    if (fn.Status === "Active" && fn.InstallDependency === "FALSE" &&
        (!previousModTime || fn.ModTime !== previousModTime)) return fn;
    await new Promise(r => setTimeout(r, 2000));
  }
  throw new Error("CODE_UPDATE_NOT_READY:" + name);
}

async function resume() {
  const prepared = json("outputs/release-20261110/prepare.json");
  const backup = json("outputs/release-20261110/config-before.json");
  const state = { deployedFunctions: Object.keys(REPLACEMENTS), configWritten: true, staticUploaded: false };
  const functionResults = {};
  try {
    const liveExperts = one(await db.collection("bf_config").doc("experts").get());
    const liveRuntime = one(await db.collection("bf_config").doc("runtime").get());
    const grounded = JSON.parse(liveRuntime.data?.CHAT_GROUNDED_REVIEW || '{"enabled":false}');
    let config;
    if (liveExperts.version === backup.experts.version) {
      config = await updateConfig();
    } else {
      config = json("outputs/release-20261110/config-release.json");
      if (liveExperts.version !== config.version || liveExperts.catalogRevision !== config.catalogRevision ||
          liveExperts.origin !== "admin" || liveExperts.experts.length !== 16 || grounded.enabled === true) {
        throw new Error("RESUME_CONFIG_STATE_INVALID");
      }
    }
    for (const name of Object.keys(REPLACEMENTS)) {
      const baseline = prepared.functions[name];
      const fn = await waitFunctionReady(name);
      const current = await codeZip(name);
      const currentPath = path.join(OUT, `resume-current-${name}.zip`);
      fs.writeFileSync(currentPath, current.bytes);
      const currentCheck = artifactCheck(path.join(OUT, `candidate-${name}.zip`), currentPath,
        path.join(OUT, `resume-current-check-${name}.json`), REPLACEMENTS[name]);
      if (currentCheck.changed.length || currentCheck.unexpected.length || currentCheck.dependencyChanges.length) {
        await uploadCode(name, path.join(OUT, `candidate-${name}.zip`));
        await waitCode(name, fn.ModTime);
      }
      const online = await codeZip(name);
      const onlinePath = path.join(OUT, `online-${name}.zip`);
      fs.writeFileSync(onlinePath, online.bytes);
      const check = artifactCheck(path.join(OUT, `candidate-${name}.zip`), onlinePath, path.join(OUT, `online-check-${name}.json`));
      if (!check.ok || check.changed.length || check.unexpected.length || check.dependencyChanges.length) throw new Error("ONLINE_ARTIFACT_MISMATCH:" + name);
      const active = await waitFunctionReady(name);
      functionResults[name] = { status: active.Status, modTime: active.ModTime, installDependency: active.InstallDependency,
        onlineSha256: sha(online.bytes), exactArtifactMatch: true, fileCount: check.candidateFileCount };
    }
    state.staticUploaded = true;
    const staticHashes = await deployStatic();
    const http = await httpVerification();
    const release = { at: new Date(), commit: COMMIT, namespace: NS, status: "ACTIVE", resumed: true,
      functions: functionResults, config, staticHashes, http,
      paidImageCalls: 0, ipaBuildTriggered: false, customerQuotaChanged: false,
      rollbackArtifacts: ["before-bf-api.zip", "before-bf-image.zip", "config-before.json", "before-admin.html", "before-staff.html"] };
    writeOut("release.json", release);
    console.log(JSON.stringify({ mode: "resume", status: "ACTIVE", functions: Object.keys(functionResults),
      expertVersion: config.version, checks: http.checks, paidChatCalls: http.paidChatCalls }, null, 2));
  } catch (error) {
    let rollbackReport = null;
    try { rollbackReport = await rollback(state); } catch (rollbackError) { rollbackReport = { error: String(rollbackError.message || rollbackError) }; }
    writeOut("release-failed-resume.json", { at: new Date(), error: String(error.message || error), state, rollback: rollbackReport });
    throw error;
  }
}

async function apply() {
  const prepared = json("outputs/release-20261110/prepare.json");
  const state = { deployedFunctions: [], configWritten: false, staticUploaded: false };
  const functionResults = {};
  try {
    for (const name of Object.keys(REPLACEMENTS)) {
      const baseline = prepared.functions[name];
      const fn = await scf.GetFunction({ FunctionName: name, Namespace: NS });
      if (fn.Status !== "Active" || fn.InstallDependency !== "FALSE" || fn.ModTime !== baseline.modTime) throw new Error("BASELINE_CHANGED:" + name);
      await uploadCode(name, path.join(OUT, `candidate-${name}.zip`));
      const active = await waitActive(name, true, baseline.modTime);
      const online = await codeZip(name);
      const onlinePath = path.join(OUT, `online-${name}.zip`);
      fs.writeFileSync(onlinePath, online.bytes);
      const check = artifactCheck(path.join(OUT, `candidate-${name}.zip`), onlinePath, path.join(OUT, `online-check-${name}.json`));
      if (!check.ok || check.changed.length || check.unexpected.length || check.dependencyChanges.length) throw new Error("ONLINE_ARTIFACT_MISMATCH:" + name);
      state.deployedFunctions.push(name);
      functionResults[name] = { status: active.Status, modTime: active.ModTime, installDependency: active.InstallDependency,
        onlineSha256: sha(online.bytes), exactArtifactMatch: true, fileCount: check.candidateFileCount };
    }
    const config = await updateConfig(); state.configWritten = true;
    const staticHashes = await deployStatic(); state.staticUploaded = true;
    const http = await httpVerification();
    const release = { at: new Date(), commit: COMMIT, namespace: NS, status: "ACTIVE",
      functions: functionResults, config, staticHashes, http,
      paidImageCalls: 0, ipaBuildTriggered: false, customerQuotaChanged: false,
      rollbackArtifacts: ["before-bf-api.zip", "before-bf-image.zip", "config-before.json", "before-admin.html", "before-staff.html"] };
    writeOut("release.json", release);
    console.log(JSON.stringify({ mode: "release", status: "ACTIVE", functions: Object.keys(functionResults),
      expertVersion: config.version, checks: http.checks, paidChatCalls: http.paidChatCalls }, null, 2));
  } catch (error) {
    let rollbackReport = null;
    try { rollbackReport = await rollback(state); } catch (rollbackError) { rollbackReport = { error: String(rollbackError.message || rollbackError) }; }
    writeOut("release-failed.json", { at: new Date(), error: String(error.message || error), state, rollback: rollbackReport });
    throw error;
  }
}

const mode = process.argv.includes("--resume") ? "resume" : process.argv.includes("--apply") ? "apply" : "prepare";
const task = mode === "resume" ? resume() : mode === "apply" ? apply() : prepare();
task.catch(error => { console.error(error.code || error.message || error.name); process.exitCode = 1; });
