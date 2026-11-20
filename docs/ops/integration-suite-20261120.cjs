#!/usr/bin/env node
/**
 * 集成层用例（部署后执行，一键跑完出报告）
 *   E1 三附件重绘 · E2 餐厅 17 字段 · E3 纯文生图 · E4 两轮改稿
 * 预算闸门：累计超过 MAX_COST 元立即停止。
 * 用法：node scripts/integration-suite-20261120.cjs [--max 2.0]
 */
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { PNG } = require("../cloudfunctions/bf-image/node_modules/pngjs");

const ROOT = path.resolve(__dirname, "..");
const OUT = path.join(ROOT, "outputs/integration-20261120");
const API = "https://xmy-test-d5g8c0xcifcefcfd5-1449098021.ap-shanghai.app.tcloudbase.com";
const ASSETS = path.join(ROOT, "outputs/p0-2-hard-20261120/assets");
const OLD_POSTER = path.join(ROOT, "outputs/replay-intent-20261120/r2.png");
const PHOTO = path.join(ASSETS, "brand-photo.jpg");
const LOGO = path.join(ROOT, "outputs/poster-model-direct-20261112/assets/logo-transparent.png");

const argv = process.argv.slice(2);
const MAX_COST = Number((argv.includes("--max") ? argv[argv.indexOf("--max") + 1] : "2.0")) || 2.0;

const COMPANY = "中防保全（苏州）科技有限公司";
const HOTLINE = "400-7758-119";
const RESTAURANT = {
  brand: "禾味轩", slogan: "秋日暖食，一碗入魂", hotline: "400-826-7719",
  address: "苏州工业园区星湖街128号",
  items: [["藤椒鸡腿饭", "22"], ["酸汤肥牛面", "26"], ["板栗烧肉饭", "24"], ["桂花酒酿圆子", "12"], ["菌菇鸡汤", "18"], ["陈皮红豆沙", "10"]],
};

const TOOLS = [{
  type: "function",
  function: {
    name: "image_generate",
    description: "生成新图；可基于上传图重新设计。把需准确呈现的原文逐条放入 structured.text。",
    parameters: {
      type: "object",
      properties: {
        prompt: { type: "string" },
        aspect_ratio: { type: "string" },
        source: { type: "string", enum: ["none", "attached"] },
        source_index: { type: "integer", minimum: 1, maximum: 6 },
        structured: { type: "object", properties: { text: { type: "array", items: { type: "object", properties: { key: { type: "string" }, role: { type: "string", enum: ["title", "subtitle", "body", "label", "contact", "footer"] }, text: { type: "string" } }, required: ["text"] } } }, required: ["text"] },
      },
      required: ["prompt"],
    },
  },
}];

const hashPwd = (p) => { const s = crypto.randomBytes(16).toString("hex"); return "scrypt$" + s + "$" + crypto.scryptSync(p, s, 64).toString("hex"); };
const results = [];
const rec = (id, name, ok, detail) => { results.push({ id, name, ok, detail }); console.log((ok ? "✓" : "✗"), id, name, "|", detail); };

function downscale(file, width) {
  const p = PNG.sync.read(fs.readFileSync(file));
  const w = Math.min(width, p.width), h = Math.round(p.height * w / p.width);
  const o = new PNG({ width: w, height: h });
  for (let y = 0; y < h; y++) {
    const sy = Math.min(p.height - 1, Math.floor(y * p.height / h));
    for (let x = 0; x < w; x++) {
      const sx = Math.min(p.width - 1, Math.floor(x * p.width / w));
      const a = (sy * p.width + sx) * 4, b = (y * w + x) * 4;
      o.data[b] = p.data[a]; o.data[b + 1] = p.data[a + 1]; o.data[b + 2] = p.data[a + 2]; o.data[b + 3] = 255;
    }
  }
  const dst = path.join(OUT, path.basename(file, path.extname(file)) + "-" + width + ".png");
  fs.writeFileSync(dst, PNG.sync.write(o));
  return dst;
}

async function main() {
  fs.mkdirSync(OUT, { recursive: true });
  const cred = JSON.parse(fs.readFileSync(path.join(process.env.USERPROFILE, ".config/.cloudbase/auth.json"), "utf8")).credential;
  const app = require(path.join(ROOT, "cloudfunctions/bf-api/node_modules/@cloudbase/node-sdk")).init({
    env: "xmy-test-d5g8c0xcifcefcfd5", region: "ap-shanghai",
    secretId: cred.tmpSecretId, secretKey: cred.tmpSecretKey, sessionToken: cred.tmpToken,
  });
  const db = app.database();
  const PWD = crypto.randomBytes(10).toString("hex");
  const acc = {
    username: "itg_" + crypto.randomBytes(3).toString("hex"), passwordHash: hashPwd(PWD), displayName: "集成测试",
    status: "active", tier: "plus", planPriceCny: 166,
    expiresAt: new Date(Date.now() + 30 * 86400000), cycleAnchorAt: new Date(Date.now() - 5 * 86400000),
    periodKey: "smoke", chatUsedCny: 0, imageUsedCny: 0, dayUsedCny: 0, weekUsedCny: 0, proUsedCny: 0,
    createdAt: new Date(Date.now() - 5 * 86400000), note: "temp-itg", failedAttempts: 0, sv: 0,
    costBudgetPolicy: { version: 1, capCny: 50 },
  };
  let accId = null;
  const memIds = [];
  const spent = async () => {
    const a = (await db.collection("bf_accounts").doc(accId).get()).data[0];
    return Number(a.chatUsedCny || 0) + Number(a.imageUsedCny || 0);
  };

  try {
    const ins = await db.collection("bf_accounts").add(acc); accId = ins.id;
    for (const text of [
      "海报等设计输出偏好：用户明确要求竖版（不要横版），图文并茂、高清。",
      `公司全称：${COMPANY}；全国服务热线 ${HOTLINE}。任何宣传物料都要写全称与这个号码。`,
    ]) {
      const r = await db.collection("bf_sync_v2").add({
        accountId: accId, kind: "memory", refId: crypto.randomUUID(),
        payload: JSON.stringify({ id: crypto.randomUUID(), text }), parentId: "", hash: crypto.randomBytes(16).toString("hex"),
        deleted: false, version: 1, revision: 1, committedAt: Date.now(),
      });
      memIds.push(r.id);
    }
    const lj = await (await fetch(API + "/api/login", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ username: acc.username, password: PWD }) })).json();
    const H = { "Content-Type": "application/json", Authorization: "Bearer " + lj.token };

    const chat = async (text, imgs) => {
      const content = [{ type: "text", text }];
      for (const u of imgs) content.push({ type: "image_url", image_url: { url: u } });
      const r = await fetch(API + "/api/chat", {
        method: "POST", headers: { ...H, Accept: "text/event-stream" },
        body: JSON.stringify({ stream: true, tools: TOOLS, messages: [{ role: "user", content }] }),
      });
      let args = "", done = false;
      const dec = new TextDecoder(); let buf = "";
      for await (const ch of r.body) {
        buf += dec.decode(ch, { stream: true });
        const ls = buf.split("\n"); buf = ls.pop() || "";
        for (const l of ls) {
          const t = l.trim(); if (!t.startsWith("data:")) continue;
          const p = t.slice(5).trim();
          if (p === "[DONE]") { done = true; continue; }
          try { const j = JSON.parse(p); const d = j.choices?.[0]?.delta; if (Array.isArray(d?.tool_calls)) for (const c of d.tool_calls) if (c?.function?.arguments) args += c.function.arguments; } catch {}
        }
      }
      if (!done || !args) return null;
      return JSON.parse(args);
    };

    const gen = async (a, imgs, rid) => {
      const body = { ...a, image: imgs, source: "attached", requestId: rid };
      if (body.source_index == null && body.source_indexes == null) body.source_index = 1;
      const r = await fetch(API + "/img/image", { method: "POST", headers: H, body: JSON.stringify(body) });
      const j = await r.json().catch(() => ({}));
      if (!j.url) return null;
      const png = Buffer.from(await (await fetch(j.url, { signal: AbortSignal.timeout(240000) })).arrayBuffer());
      const file = path.join(OUT, rid + ".png");
      fs.writeFileSync(file, png);
      return { file, w: j.width, h: j.height };
    };

    const oldSmall = "data:image/png;base64," + fs.readFileSync(downscale(OLD_POSTER, 700)).toString("base64");
    const photoB64 = "data:image/jpeg;base64," + fs.readFileSync(PHOTO).toString("base64");
    const logoB64 = "data:image/png;base64," + fs.readFileSync(LOGO).toString("base64");

    // ── E1 三附件重绘 ──
    {
      const text = "这是我们上一版的海报，做秋季改版重绘。所有栏目和功能说明全部保留；主视觉换成我发的门店实拍照片；Logo 用附件这张新的；配色改暖色。";
      const a = await chat(text, [oldSmall, photoB64, logoB64]);
      if (!a) { rec("E1", "三附件重绘", false, "未拿到生图参数"); }
      else {
        const all = (a.structured?.text || []).map(b => b.text).join("\n");
        const dup = (a.structured?.text || []).filter((b, i, arr) => arr.findIndex(x => x.text === b.text) !== i).length;
        const out = await gen(a, [oldSmall, photoB64, logoB64], "E1");
        const ratioOk = out && a.aspect_ratio ? Math.abs((out.w / out.h) - (() => { const m = /^(\d+):(\d+)$/.exec(a.aspect_ratio); return m ? m[1] / m[2] : 1; })()) < 0.08 : false;
        rec("E1", "三附件重绘", !!(out && ratioOk && all.includes(COMPANY) && all.includes(HOTLINE) && dup === 0 && !/品牌名称|待补充/.test(all)),
          `比例=${a.aspect_ratio} 实际=${out ? out.w + "x" + out.h : "-"} 公司名=${all.includes(COMPANY)} 热线=${all.includes(HOTLINE)} 重复=${dup} 占位=${/品牌名称|待补充/.test(all)}`);
      }
      if (await spent() > MAX_COST) throw new Error("BUDGET_EXCEEDED");
    }

    // ── E2 餐厅 17 字段 ──
    {
      const text = `做成秋季新品海报，竖版。六款新品与价格：${RESTAURANT.items.map(([n, p]) => `${n} ${p} 元`).join("、")}。品牌名${RESTAURANT.brand}，一句话「${RESTAURANT.slogan}」，订餐热线 ${RESTAURANT.hotline}，地址${RESTAURANT.address}。`;
      const a = await chat(text, [photoB64, logoB64]);
      if (!a) { rec("E2", "餐厅 17 字段", false, "未拿到参数"); }
      else {
        const all = (a.structured?.text || []).map(b => b.text).join("\n");
        const names = RESTAURANT.items.filter(([n]) => all.includes(n)).length;
        const prices = RESTAURANT.items.filter(([n, p]) => new RegExp(n + "[^\\d]{0,6}" + p).test(all)).length;
        const out = await gen(a, [photoB64, logoB64], "E2");
        rec("E2", "餐厅 17 字段", !!(out && names === 6 && prices === 6 && all.includes(RESTAURANT.brand) && all.includes(RESTAURANT.hotline) && all.includes(RESTAURANT.address)),
          `产品名=${names}/6 价格=${prices}/6 品牌=${all.includes(RESTAURANT.brand)} 热线=${all.includes(RESTAURANT.hotline)}`);
      }
      if (await spent() > MAX_COST) throw new Error("BUDGET_EXCEEDED");
    }

    // ── E3 纯文生图 ──
    {
      const a = await chat("做一张秋季促销海报，竖版，主标题「秋日上新」，副标题「全场 8 折」", []);
      if (!a) { rec("E3", "纯文生图", false, "未拿到参数"); }
      else {
        const all = (a.structured?.text || []).map(b => b.text).join("\n");
        const out = await gen(a, [], "E3");
        rec("E3", "纯文生图", !!(out && !/品牌名称|待补充/.test(all)), `比例=${a.aspect_ratio} 实际=${out ? out.w + "x" + out.h : "-"} 占位=${/品牌名称|待补充/.test(all)}`);
      }
      if (await spent() > MAX_COST) throw new Error("BUDGET_EXCEEDED");
    }

    // ── E4 两轮改稿：只改一处，其余应基本不变 ──
    {
      const a1 = await chat("做一张门店海报，竖版，标题「秋季新品」，底部写全国服务热线 " + HOTLINE, [photoB64]);
      if (!a1) { rec("E4", "两轮改稿", false, "第一轮未拿到参数"); }
      else {
        const r1 = await gen(a1, [photoB64], "E4-round1");
        if (!r1) rec("E4", "两轮改稿", false, "第一轮未出图");
        else {
          const prev = "data:image/png;base64," + fs.readFileSync(downscale(r1.file, 700)).toString("base64");
          const a2 = await chat("在上一张基础上，把标题改成「秋季上新」，其他都不要动", [prev]);
          const r2 = a2 ? await gen(a2, [prev], "E4-round2") : null;
          if (!r2) rec("E4", "两轮改稿", false, "第二轮未出图");
          else {
            // 粗粒度结构相似度：缩到 64x64 比像素差
            const norm = f => { const p = PNG.sync.read(fs.readFileSync(f)); const o = new PNG({ width: 64, height: 64 });
              for (let y = 0; y < 64; y++) for (let x = 0; x < 64; x++) { const sy = Math.floor(y * p.height / 64), sx = Math.floor(x * p.width / 64); const a = (sy * p.width + sx) * 4, b = (y * 64 + x) * 4; o.data[b] = p.data[a]; o.data[b + 1] = p.data[a + 1]; o.data[b + 2] = p.data[a + 2]; o.data[b + 3] = 255; }
              return o; };
            const A = norm(r1.file), B = norm(r2.file);
            let diff = 0; for (let i = 0; i < A.data.length; i += 4) diff += Math.abs(A.data[i] - B.data[i]) + Math.abs(A.data[i + 1] - B.data[i + 1]) + Math.abs(A.data[i + 2] - B.data[i + 2]);
            const sim = 1 - diff / (64 * 64 * 3 * 255);
            rec("E4", "两轮改稿", sim >= 0.9, `结构相似度 ${(sim * 100).toFixed(1)}%（阈值 90%）`);
          }
        }
      }
    }

    const total = +(await spent()).toFixed(4);
    console.log("\n累计花费 " + total + " 元（上限 " + MAX_COST + "）");
    const pass = results.filter(r => r.ok).length;
    console.log("集成层：" + pass + "/" + results.length + " 通过");
    fs.writeFileSync(path.join(OUT, "results.json"), JSON.stringify({ at: new Date().toISOString(), pass, total: results.length, results, cost: total }, null, 2));
  } finally {
    for (const m of memIds) { try { await db.collection("bf_sync_v2").doc(m).remove(); } catch {} }
    if (accId) { try { await db.collection("bf_accounts").doc(accId).remove(); } catch {} }
    console.log("临时数据已清理");
  }
}
main().catch(e => console.error("ERR", e.message));
