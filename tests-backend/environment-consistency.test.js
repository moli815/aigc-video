// ============================================================================
// environment-consistency.test.js —— 环境地址一致性（只在仓库布局下运行）
//
// 审计 P0-1 / P1-9 的整改契约：App、管理端、员工端、云函数必须指向**同一个**环境。
// 这个测试不判断环境叫什么名字（用户已说明 `xmy-test` 是自行命名），只判断四者是否一致，
// 以及"是否有未被使用的备用地址假装容灾"。
//
// 仅在 aigc-video 仓库布局下有效（需要同时看到 BossAI/ 与 cloudfunctions/），
// 在 bf-backend 目录下运行时不适用 —— 所以文件里自带可用性守卫。
// ============================================================================

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.join(__dirname, "..");
const APP = path.join(ROOT, "BossAI/Config/AppConfig.swift");
const IMG = path.join(ROOT, "cloudfunctions/bf-image/index.js");
const WEB = ["web/admin.html", "web/staff.html", "web/index.html"].map((p) => path.join(ROOT, p));

const available = fs.existsSync(APP) && WEB.every((p) => fs.existsSync(p));
const read = (p) => fs.readFileSync(p, "utf8");
const hostOf = (url) => {
  const m = String(url).match(/https?:\/\/([^/"']+)/);
  return m ? m[1] : "";
};

test("ENV-01 App / 管理端 / 员工端 / 落地页必须指向同一环境", { skip: !available && "非仓库布局" }, () => {
  const appSrc = read(APP);
  // AppConfig 里第一个 https 默认值就是生效的默认 API base
  const appUrl = (appSrc.match(/return "(https:\/\/[^"]+)"/) || [])[1];
  assert.ok(appUrl, "AppConfig 里找不到默认 API 地址");
  const hosts = [hostOf(appUrl)];

  for (const p of WEB) {
    const src = read(p);
    // 前端最后一个兜底 return 里的地址
    const m = src.match(/return "(https:\/\/[^"]+\/api)";/);
    assert.ok(m, `${path.basename(p)} 找不到兜底 API 地址`);
    hosts.push(hostOf(m[1]));
  }
  const uniq = [...new Set(hosts)];
  assert.equal(uniq.length, 1, "四个入口指向了不同环境：" + JSON.stringify(hosts));
});

test("ENV-02 不再保留「未使用的备用地址」假装容灾", { skip: !available && "非仓库布局" }, () => {
  const appSrc = read(APP);
  assert.doesNotMatch(appSrc, /hostedAPIBaseFallback/, "备用地址常量仍在（只有定义、没有调用点）");
  assert.doesNotMatch(appSrc, /service\.tcloudbase\.com/, "仍存在另一套 CloudBase 域名兜底");
});

test("ENV-03 App 支持构建注入，前端支持 window 覆盖 + 同源优先", { skip: !available && "非仓库布局" }, () => {
  const appSrc = read(APP);
  assert.match(appSrc, /object\(forInfoDictionaryKey: "BossAIAPIBase"\)/, "App 未支持 Info.plist 注入");
  for (const p of WEB) {
    const src = read(p);
    assert.match(src, /window\.BOSSAI_API_BASE/, `${path.basename(p)} 未支持注入`);
    assert.match(src, /location\.origin \+ "\/api"/, `${path.basename(p)} 未支持同源优先`);
  }
});

test("ENV-04 bf-image 回查额度的 BF_API_BASE 默认值也必须是同一环境", { skip: !available && "非仓库布局" }, () => {
  const appSrc = read(APP);
  const appHost = hostOf((appSrc.match(/return "(https:\/\/[^"]+)"/) || [])[1]);
  const imgSrc = read(IMG);
  const m = imgSrc.match(/BF_API_BASE \|\| "([^"]+)"/);
  assert.ok(m, "bf-image 找不到 BF_API_BASE 默认值");
  assert.equal(hostOf(m[1]), appHost, `bf-image 额度回查指向了另一个环境：${m[1]}`);
});

test("ENV-05 管理端/员工端内嵌脚本语法可解析（防止拼接注入把 JS 写坏）", { skip: !available && "非仓库布局" }, () => {
  const vm = require("node:vm");
  for (const p of WEB) {
    const src = read(p);
    const blocks = [...src.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)].map((m) => m[1]).filter((s) => s.trim());
    assert.ok(blocks.length > 0, `${path.basename(p)} 没有内嵌脚本`);
    for (const code of blocks) {
      assert.doesNotThrow(() => new vm.Script(code), `${path.basename(p)} 的内嵌脚本语法错误`);
    }
  }
});
