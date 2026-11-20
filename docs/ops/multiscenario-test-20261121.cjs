#!/usr/bin/env node
/**
 * 多场景长上下文测试（2026-11-21）
 * 4 个行业 × 3 类能力：长上下文早期图片追溯 / 多附件引用 / 500+ 字海报重绘
 * 素材全部自造，不复用真实用户素材。
 */
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { PNG } = require("../cloudfunctions/bf-image/node_modules/pngjs");
const jpeg = require("../cloudfunctions/bf-image/node_modules/jpeg-js");

const ROOT = path.resolve(__dirname, "..");
const BASE = path.join(ROOT, "outputs/multiscenario-20261121");
const ASSETS = path.join(BASE, "assets");
const API = "https://xmy-test-d5g8c0xcifcefcfd5-1449098021.ap-shanghai.app.tcloudbase.com";

// ── 图片压缩 ──────────────────────────────────────────────
function loadJpegResized(file, targetW, quality = 84) {
  const raw = fs.readFileSync(file);
  let w, h, data;
  if (/\.png$/i.test(file)) {
    const p = PNG.sync.read(raw);
    w = p.width; h = p.height; data = p.data;
  } else {
    const j = jpeg.decode(raw, { useTArray: true });
    w = j.width; h = j.height; data = j.data;
  }
  const scale = Math.min(1, targetW / w);
  const ow = Math.round(w * scale), oh = Math.round(h * scale);
  const out = Buffer.alloc(ow * oh * 4);
  for (let y = 0; y < oh; y++) {
    const sy = Math.min(h - 1, Math.floor(y / scale));
    for (let x = 0; x < ow; x++) {
      const sx = Math.min(w - 1, Math.floor(x / scale));
      const a = (sy * w + sx) * 4, b = (y * ow + x) * 4;
      out[b] = data[a]; out[b + 1] = data[a + 1]; out[b + 2] = data[a + 2]; out[b + 3] = 255;
    }
  }
  const enc = jpeg.encode({ data: out, width: ow, height: oh }, quality);
  return "data:image/jpeg;base64," + enc.data.toString("base64");
}

// ── 4 组场景对话（每组 3000+ 字） ──────────────────────────
const SCENES = require("./multiscenario-dialogues-20261121.js");

const { parseAnyToolCall, flattenText: flattenAny } = require("./lib-toolparse-20261121");

async function main() {
  const only = process.argv.find((a) => a.startsWith("--only="));
  const target = only ? only.split("=")[1] : null;

  const cred = JSON.parse(fs.readFileSync(path.join(process.env.USERPROFILE, ".config/.cloudbase/auth.json"), "utf8")).credential;
  const app = require(path.join(ROOT, "cloudfunctions/bf-api/node_modules/@cloudbase/node-sdk")).init({
    env: "xmy-test-d5g8c0xcifcefcfd5", region: "ap-shanghai",
    secretId: cred.tmpSecretId, secretKey: cred.tmpSecretKey, sessionToken: cred.tmpToken,
  });
  const db = app.database();
  const hashPwd = (p) => {
    const s = crypto.randomBytes(16).toString("hex");
    return "scrypt$" + s + "$" + crypto.scryptSync(p, s, 64).toString("hex");
  };

  const results = [];

  for (const sc of SCENES) {
    if (target && sc.key !== target) continue;
    console.log("\n════ " + sc.name + " ════");

    const dir = path.join(sc.dir);
    const logo = loadJpegResized(path.join(ASSETS, sc.key, "logo.png"), 420);
    const dash = loadJpegResized(path.join(ASSETS, sc.key, "dashboard.png"), 900);
    const refPoster = loadJpegResized(path.join(ASSETS, sc.key, "ref-poster.png"), 640);
    const scene = loadJpegResized(path.join(ASSETS, sc.key, "scene.png"), 520);

    // 建临时账号
    const PWD = crypto.randomBytes(10).toString("hex");
    const acc = {
      username: "ms_" + crypto.randomBytes(3).toString("hex"), passwordHash: hashPwd(PWD),
      displayName: sc.name + "测试", status: "active", tier: "plus", planPriceCny: 166,
      expiresAt: new Date(Date.now() + 30 * 86400000), cycleAnchorAt: new Date(Date.now() - 5 * 86400000),
      periodKey: "smoke", chatUsedCny: 0, imageUsedCny: 0, dayUsedCny: 0, weekUsedCny: 0, proUsedCny: 0,
      createdAt: new Date(Date.now() - 5 * 86400000), note: "temp-multiscenario", failedAttempts: 0, sv: 0,
      costBudgetPolicy: { version: 1, capCny: 60 },
    };
    const ins = await db.collection("bf_accounts").add(acc);
    let token = "";
    try {
      const lr = await fetch(API + "/api/login", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ username: acc.username, password: PWD }) });
      token = (await lr.json()).token;
      if (!token) throw new Error("登录失败");

      // 组装 messages：早期带场景图，最后一条带四附件
      const msgs = [];
      for (const turn of sc.turns) {
        if (turn.role === "user") {
          const parts = [{ type: "text", text: turn.text }];
          if (turn.image === "scene") parts.push({ type: "image_url", image_url: { url: scene } });
          msgs.push({ role: "user", content: parts });
        } else {
          msgs.push({ role: "assistant", content: turn.text });
        }
      }
      // 最后一条：多附件 + 指令
      msgs.push({
        role: "user",
        content: [
          { type: "text", text: sc.finalAsk },
          { type: "image_url", image_url: { url: logo } },
          { type: "image_url", image_url: { url: dash } },
          { type: "image_url", image_url: { url: refPoster } },
        ],
      });

      const totalChars = msgs.map((m) => {
        const c = m.content;
        if (typeof c === "string") return c.length;
        return c.filter((p) => p.type === "text").map((p) => p.text).join("").length;
      }).reduce((a, b) => a + b, 0);
      console.log("上下文", totalChars, "字 |", msgs.length, "条消息");

      const H = { "Content-Type": "application/json", Authorization: "Bearer " + token };
      const t0 = Date.now();
      const r = await fetch(API + "/api/chat", {
        method: "POST",
        headers: { ...H, Accept: "text/event-stream" },
        body: JSON.stringify({ stream: true, requestId: "ms-" + Date.now(), messages: msgs }),
      });
      const chatSec = ((Date.now() - t0) / 1000).toFixed(1);
      if (!r.ok) {
        const t = await r.text();
        throw new Error("chat HTTP " + r.status + " " + t.slice(0, 200));
      }

      // 解析 SSE
      let args = "", textOut = "", frames = 0, done = false;
      const reader = r.body.getReader();
      const dec = new TextDecoder();
      let buf = "";
      while (true) {
        const n = await reader.read();
        if (n.done) break;
        buf += dec.decode(n.value, { stream: true });
        let pos;
        while ((pos = buf.indexOf("\n")) >= 0) {
          const line = buf.slice(0, pos).replace(/\r$/, "");
          buf = buf.slice(pos + 1);
          if (!line.startsWith("data:")) continue;
          const payload = line.slice(5).trim();
          if (payload === "[DONE]") { done = true; continue; }
          frames++;
          try {
            const j = JSON.parse(payload);
            const d = j.choices?.[0]?.delta;
            if (d?.content) textOut += d.content;
            if (Array.isArray(d?.tool_calls)) for (const c of d.tool_calls) if (c?.function?.arguments) args += c.function.arguments;
          } catch {}
        }
      }
      console.log("对话", chatSec + "s |", frames, "帧 | 文本", textOut.length, "字 | toolArgs", args.length);

      let tool = null;
      try { tool = JSON.parse(args); } catch {}
      let dsml = null;
      if (!tool) {
        const d = parseAnyToolCall(textOut);
        if (d) { dsml = d; tool = d.tool; console.log("命中非标准工具调用格式（" + d.name + "），已本地转换（线上未修）"); }
      }
      if (!tool) {
        results.push({
          key: sc.key, name: sc.name, industry: sc.industry,
          ctxChars: totalChars, msgCount: msgs.length, chatSec: +chatSec, frames, done,
          toolArgsRaw: args, textOut, noToolCall: true,
          messagesForReport: msgs.map((m) => ({
            role: m.role,
            text: typeof m.content === "string" ? m.content : m.content.filter((p) => p.type === "text").map((p) => p.text).join(""),
            images: typeof m.content === "string" ? 0 : m.content.filter((p) => p.type === "image_url").length,
          })),
        });
        console.log("未调用生图工具，回复正文", textOut.length, "字");
        console.log("回复前 300 字：", textOut.slice(0, 300));
        throw new Error("__NO_TOOL__");
      }

      // 出图
      // Ark 的 image 只认 URL / data URL，裸 base64 会被当成 URL 解析并报 invalid url
      const imgBody = { ...tool, image: [logo, dash, refPoster, scene], source: "attached", requestId: "ms-img-" + Date.now() };
      const ti = Date.now();
      const ir = await fetch(API + "/img/image", { method: "POST", headers: H, body: JSON.stringify(imgBody) });
      const ij = await ir.json().catch(() => ({}));
      const imgSec = ((Date.now() - ti) / 1000).toFixed(1);
      console.log("生图", imgSec + "s | HTTP", ir.status, "|", JSON.stringify(ij).slice(0, 160));

      let imgFile = null, dims = null;
      const url = ij.url || ij.imageUrl || (ij.data && ij.data[0] && ij.data[0].url);
      if (url) {
        const bin = await (await fetch(url)).arrayBuffer();
        imgFile = path.join(dir, "poster.png");
        fs.mkdirSync(dir, { recursive: true });
        fs.writeFileSync(imgFile, Buffer.from(bin));
        const p = PNG.sync.read(fs.readFileSync(imgFile));
        dims = { w: p.width, h: p.height, ratio: +(p.width / p.height).toFixed(3) };
      }

      // structured 可能是字符串、数组，也可能是对象（headline/product_items…），统一扁平化
      const stRaw = (tool.structured && (tool.structured.text != null ? tool.structured.text : tool.structured)) || "";
      const allText = flattenAny(stRaw);
      const blocks = allText.split("\n").map((x) => x.trim()).filter(Boolean).map((t) => ({ role: "body", text: t }));

      results.push({
        key: sc.key, name: sc.name, industry: sc.industry,
        ctxChars: totalChars, msgCount: msgs.length,
        chatSec: +chatSec, imgSec: +imgSec, frames, done,
        tool, blocks, allText, textOut,
        dsmlFormat: !!dsml,
        imgFile, dims, imgHttp: ir.status, imgResp: ij,
        checks: sc.checks(allText, tool, dims),
        messagesForReport: msgs.map((m) => ({
          role: m.role,
          text: typeof m.content === "string" ? m.content : m.content.filter((p) => p.type === "text").map((p) => p.text).join(""),
          images: typeof m.content === "string" ? 0 : m.content.filter((p) => p.type === "image_url").length,
        })),
      });
      console.log("物料", JSON.stringify(dims), "| 检查", sc.checks(allText, tool, dims).filter((c) => !c.ok).length, "项未过");
    } catch (e) {
      if (e.message !== "__NO_TOOL__") console.error("组失败：" + sc.name, e.message);
      results.push({ key: sc.key, name: sc.name, industry: sc.industry, error: e.message });
    } finally {
      await db.collection("bf_accounts").doc(ins.id).remove();
    }
  }

  fs.mkdirSync(BASE, { recursive: true });
  const outFile = path.join(BASE, "results.json");
  let merged = [];
  if (fs.existsSync(outFile)) {
    try {
      const prev = JSON.parse(fs.readFileSync(outFile, "utf8"));
      const keys = new Set(results.map((r) => r.key));
      merged = prev.filter((r) => !keys.has(r.key));
    } catch {}
  }
  merged = merged.concat(results);
  const order = ["bakery", "security", "coding", "dental"];
  merged.sort((a, b) => order.indexOf(a.key) - order.indexOf(b.key));
  fs.writeFileSync(outFile, JSON.stringify(merged, null, 2));
  console.log("\n结果写入 results.json（累计 " + merged.length + " 组）");
}

main().catch((e) => { console.error("ERR", e.message); process.exit(1); });
