// ============================================================================
// 行为级加固测试（10-24 第二批）
//
// 与 security-contract.test.js 的区别：
//   那些是「源码结构断言」——防止有人把防护删掉；
//   这里是**真正调用函数**验证行为——防止防护写错但结构还在。
//
// 纯函数被抽到 tiers.js / media-guards.js，正是因为 bf-api 有 tcb.init、
// bf-image 末尾有 server.listen，测试进程 require 原文件会挂住或报错。
// ============================================================================

const test = require("node:test");
const assert = require("node:assert");

const { computeTiers, applyTiersInto } = require("../cloudfunctions/bf-api/tiers");
const {
  safeFetchURL, isPrivateHost, clampExplicitSize, probeImageSize, decodedSizeAllowed,
} = require("../cloudfunctions/bf-image/media-guards");

// 与 bf-api 里的 TIERS 同构的最小基线
const ORDER = ["plus", "pro", "ultra"];
const BASE = {
  plus: { key: "plus", name: "Plus", priceCny: 166, poolCapCny: 135, qrFile: "q.png", visible: true,
          features: { memoryLimit: 20, exportDoc: false, schedules: 0 } },
  pro:  { key: "pro",  name: "Pro",  priceCny: 700, poolCapCny: 595, qrFile: "p.png", visible: false,
          features: { memoryLimit: 100, exportDoc: true, schedules: 3 } },
  ultra:{ key: "ultra",name: "Ultra",priceCny: 1400,poolCapCny: 1190,qrFile: "u.png", visible: false,
          features: { memoryLimit: -1, exportDoc: true, schedules: 10 } },
};

// ─────────────────────────────────────────────────────────────
// CFG-01：档位覆盖的四种序列
// ─────────────────────────────────────────────────────────────

test("CFG-01-a 无覆盖时完全等于默认", () => {
  const t = computeTiers(BASE, {}, ORDER);
  assert.strictEqual(t.plus.priceCny, 166);
  assert.strictEqual(t.pro.visible, false);
  assert.deepStrictEqual(t.ultra.features, BASE.ultra.features);
});

test("CFG-01-b A 覆盖只改指定字段", () => {
  const t = computeTiers(BASE, { plus: { priceCny: 199 } }, ORDER);
  assert.strictEqual(t.plus.priceCny, 199);
  assert.strictEqual(t.plus.poolCapCny, 135, "未覆盖的字段应保持默认");
  assert.strictEqual(t.pro.priceCny, 700, "其他档位不受影响");
});

test("CFG-01-c B 覆盖不与 A 残留叠加", () => {
  // 模拟：先应用 A（plus 价格 199），再单独应用 B（pro 价格 899）
  const first = computeTiers(BASE, { plus: { priceCny: 199 } }, ORDER);
  assert.strictEqual(first.plus.priceCny, 199);
  // B 的覆盖里没有 plus → plus 必须回到默认 166，而不是沿用 199
  const second = computeTiers(BASE, { pro: { priceCny: 899 } }, ORDER);
  assert.strictEqual(second.plus.priceCny, 166, "A 的覆盖残留到了 B");
  assert.strictEqual(second.pro.priceCny, 899);
});

test("CFG-01-d A → B → 删除覆盖 → 完全恢复默认", () => {
  const afterA = computeTiers(BASE, { plus: { priceCny: 199, visible: false, features: { schedules: 99 } } }, ORDER);
  assert.strictEqual(afterA.plus.priceCny, 199);
  assert.strictEqual(afterA.plus.features.schedules, 99);

  const afterB = computeTiers(BASE, { plus: { priceCny: 188 } }, ORDER);
  assert.strictEqual(afterB.plus.visible, true, "visible 应回到默认 true");
  assert.strictEqual(afterB.plus.features.schedules, 0, "features 应回到默认 0");

  // 删除全部覆盖
  const reset = computeTiers(BASE, {}, ORDER);
  assert.strictEqual(reset.plus.priceCny, 166);
  assert.strictEqual(reset.plus.visible, true);
  assert.strictEqual(reset.plus.features.schedules, 0);
});

test("CFG-01-e 非法覆盖值被忽略而不是写入", () => {
  const t = computeTiers(BASE, { plus: { priceCny: -1, poolCapCny: "abc", qrFile: "x y z" } }, ORDER);
  assert.strictEqual(t.plus.priceCny, 166, "负数价格应被忽略");
  assert.strictEqual(t.plus.poolCapCny, 135, "非数字额度应被忽略");
  assert.strictEqual(t.plus.qrFile, "q.png", "非法文件名应被忽略");
});

test("CFG-01-f features 深拷贝，改结果不污染基线", () => {
  const t = computeTiers(BASE, { plus: { features: { schedules: 5 } } }, ORDER);
  assert.strictEqual(t.plus.features.schedules, 5);
  assert.strictEqual(BASE.plus.features.schedules, 0, "基线被污染了");
  // 直接改结果对象的 features 也不能影响基线
  t.plus.features.memoryLimit = 999;
  assert.strictEqual(BASE.plus.features.memoryLimit, 20);
});

test("CFG-01-g override 为 null / 字符串 / 数组时不崩", () => {
  for (const bad of [null, undefined, "oops", [1, 2], 42]) {
    const t = computeTiers(BASE, bad, ORDER);
    assert.strictEqual(t.plus.priceCny, 166);
  }
});

test("CFG-01-h applyTiersInto 保持目标对象引用稳定", () => {
  const target = JSON.parse(JSON.stringify(BASE));
  const ref = target.plus;
  applyTiersInto(target, computeTiers(BASE, { plus: { priceCny: 177 } }, ORDER), ORDER);
  assert.strictEqual(target.plus, ref, "档位对象引用被替换（会导致别处缓存的引用失效）");
  assert.strictEqual(target.plus.priceCny, 177);
});

// ─────────────────────────────────────────────────────────────
// IMG-01：出站 URL 审核
// ─────────────────────────────────────────────────────────────

test("IMG-01 放行正常的云存储图片地址", () => {
  assert.ok(safeFetchURL("https://abc-1258.cos.ap-shanghai.myqcloud.com/a/b.png"));
  assert.ok(safeFetchURL("https://env-123.tcloudbaseapp.com/x.jpg"));
  assert.ok(safeFetchURL("https://ark-content.volces.com/img.png"));
  assert.ok(safeFetchURL("https://p3.byteimg.com/obj/x"));
});

test("IMG-01 拒绝非 https / 非标端口 / 内嵌凭据", () => {
  assert.strictEqual(safeFetchURL("http://abc.myqcloud.com/a.png"), null, "http 应拒绝");
  assert.strictEqual(safeFetchURL("https://abc.myqcloud.com:8443/a.png"), null, "非 443 端口应拒绝");
  assert.strictEqual(safeFetchURL("https://user:pw@abc.myqcloud.com/a.png"), null, "userinfo 应拒绝");
});

test("IMG-01 拒绝私网与 IP 字面量", () => {
  assert.strictEqual(safeFetchURL("https://127.0.0.1/a.png"), null);
  assert.strictEqual(safeFetchURL("https://169.254.169.254/latest/meta-data/"), null, "云元数据必须拒绝");
  assert.strictEqual(safeFetchURL("https://10.0.0.8/a.png"), null);
  assert.strictEqual(safeFetchURL("https://[::1]/a.png"), null);
  assert.strictEqual(safeFetchURL("https://localhost/a.png"), null);
});

test("IMG-01 后缀白名单是精确匹配，不误放伪造域名", () => {
  assert.strictEqual(safeFetchURL("https://evilmyqcloud.com/a.png"), null, "evilmyqcloud.com 不应匹配 .myqcloud.com");
  assert.strictEqual(safeFetchURL("https://myqcloud.com.evil.com/a.png"), null);
  assert.strictEqual(safeFetchURL("https://evil.com/?u=.myqcloud.com"), null);
});

test("IMG-01 isPrivateHost 覆盖各私网段与非法写法", () => {
  for (const h of ["10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.1.1", "100.64.0.1", "169.254.1.1", "127.0.0.1"]) {
    assert.strictEqual(isPrivateHost(h), true, `${h} 应判为私网`);
  }
  for (const h of ["8.8.8.8", "172.32.0.1", "192.169.0.1", "1.1.1.1"]) {
    assert.strictEqual(isPrivateHost(h), false, `${h} 不应判为私网`);
  }
  assert.strictEqual(isPrivateHost("999.1.1.1"), true, "非法 IP 也应拒绝");
});

// ─────────────────────────────────────────────────────────────
// IMG-02：尺寸与解码保护
// ─────────────────────────────────────────────────────────────

test("IMG-02 合法尺寸原样返回，超预算按比例缩小", () => {
  assert.strictEqual(clampExplicitSize("1024x1024"), "1024x1024");
  const big = clampExplicitSize("4000x4000");
  assert.ok(big, "4000x4000 应在单边限制内");
  const [w, h] = big.split("x").map(Number);
  assert.ok(w * h <= 4_622_220, `总像素仍超预算：${w}x${h}`);
  assert.strictEqual(w % 8, 0, "缩放后应对齐 8");
});

test("IMG-02 低于上游像素下限时等比放大（实测 512x512 会被上游拒绝）", () => {
  // 火山实测报错："image area must be at least 921600 pixels"
  const r = clampExplicitSize("512x512");
  assert.ok(r, "512x512 不应被直接拒绝，而应放大");
  const [w, h] = r.split("x").map(Number);
  assert.ok(w * h >= 921_600, `放大后仍低于上游下限：${w}x${h}=${w * h}`);
  assert.ok(Math.abs(w / h - 1) < 0.05, "放大后应保持原有宽高比");
  // 刚好达标的不放大
  assert.strictEqual(clampExplicitSize("960x960"), "960x960");
});

test("IMG-02 越界与非法尺寸返回 null", () => {
  assert.strictEqual(clampExplicitSize("99999x99999"), null);
  assert.strictEqual(clampExplicitSize("100x100"), null, "低于最小边应拒绝");
  assert.strictEqual(clampExplicitSize("abc"), null);
  assert.strictEqual(clampExplicitSize("1024x"), null);
});

test("IMG-02 能从不完整数据里读出 PNG 宽高", () => {
  const png = Buffer.alloc(33);
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]).copy(png, 0);
  png.writeUInt32BE(13, 8);
  png.write("IHDR", 12, "ascii");
  png.writeUInt32BE(3000, 16);
  png.writeUInt32BE(2000, 20);
  const size = probeImageSize(png);
  assert.deepStrictEqual({ w: size.w, h: size.h }, { w: 3000, h: 2000 });
});

test("IMG-02 图片炸弹在解码前被拒", () => {
  // 30000 x 30000 = 9 亿像素；压缩后可能只有几十 KB
  const bomb = Buffer.alloc(33);
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]).copy(bomb, 0);
  bomb.writeUInt32BE(13, 8);
  bomb.write("IHDR", 12, "ascii");
  bomb.writeUInt32BE(30000, 16);
  bomb.writeUInt32BE(30000, 20);
  const size = probeImageSize(bomb);
  assert.strictEqual(size.w, 30000);
  assert.strictEqual(decodedSizeAllowed(size), false, "9 亿像素必须拒绝解码");
});

test("IMG-02 尺寸正常但非图片的数据不通过", () => {
  assert.strictEqual(decodedSizeAllowed(probeImageSize(Buffer.from("not an image at all"))), false);
  assert.strictEqual(decodedSizeAllowed(null), false);
  assert.strictEqual(decodedSizeAllowed({ w: 0, h: 0 }), false);
});

// ─────────────────────────────────────────────────────────────
// 智能档位推断 + 按模型定价（10-24）
// ─────────────────────────────────────────────────────────────

test("模型质量档不再由物料关键词和 prompt 文案二次猜测", () => {
  assert.equal(typeof require("../cloudfunctions/bf-image/media-guards").inferQualityTier, "undefined");
});
