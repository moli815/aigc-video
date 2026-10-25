// ============================================================================
// 安全契约回归（10-24）
//
// 这些断言不是"功能测试"，而是**防回退锚点**：
// 每一条对应一个真实存在过的安全缺陷，改回去就立刻红。
// 静态断言有它的局限（不能证明运行时一定安全），但能拦住"重构时顺手删掉防护"这类事故。
// ============================================================================

const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.resolve(__dirname, "..");
const read = (rel) => fs.readFileSync(path.join(ROOT, rel), "utf8");

const ADMIN = read("web/admin.html");
const STAFF = read("web/staff.html");
const API = read("cloudfunctions/bf-api/index.js");
const IMAGE = read("cloudfunctions/bf-image/index.js");
const GUARDS = read("cloudfunctions/bf-image/media-guards.js");
const TIERS_MOD = read("cloudfunctions/bf-api/tiers.js");

// ─────────────────────────────────────────────────────────────
// SEC-01：动态数据不得进入内联事件处理器
// ─────────────────────────────────────────────────────────────

test("SEC-01 admin.html 不再把动态值拼进 onclick", () => {
  // 危险模式：onclick="fn('"+变量+'...  或  onclick=\"fn(\"+var+\"...
  const patterns = [
    /onclick="[a-zA-Z_$][\w$]*\(\\?'"\s*\+/,   // onclick="fn('"+x
    /onclick=\\"[a-zA-Z_$][\w$]*\(\\?'"\s*\+/, // onclick=\"fn('"+x
  ];
  for (const re of patterns) {
    const hit = ADMIN.match(re);
    assert.strictEqual(hit, null, `发现动态 onclick 拼接：${hit && hit[0]}`);
  }
});

test("SEC-01 staff.html 不再把动态值拼进 onclick", () => {
  const patterns = [
    /onclick="[a-zA-Z_$][\w$]*\(\\?'"\s*\+/,
    /onclick=\\"[a-zA-Z_$][\w$]*\(\\?'"\s*\+/,
  ];
  for (const re of patterns) {
    const hit = STAFF.match(re);
    assert.strictEqual(hit, null, `发现动态 onclick 拼接：${hit && hit[0]}`);
  }
});

test("SEC-01 两个页面都注册了 data-act 事件委托", () => {
  for (const [name, html] of [["admin", ADMIN], ["staff", STAFF]]) {
    assert.match(html, /closest\('\[data-act\]'\)/, `${name} 缺少 data-act 委托`);
    assert.match(html, /data-act="/, `${name} 未使用 data-act 属性`);
  }
});

// ─────────────────────────────────────────────────────────────
// SEC-02：配置审计链路不得泄露 secret
// ─────────────────────────────────────────────────────────────

test("SEC-02 存在递归脱敏函数并被 GET settings 使用", () => {
  assert.match(API, /function redactSecrets\(/, "缺少 redactSecrets");
  const getSettings = API.slice(API.indexOf("async function handleGetSettings"));
  const body = getSettings.slice(0, getSettings.indexOf("async function", 10));
  assert.match(body, /redactSecrets\(sn\.data\)/, "GET settings 的 snapshots 未脱敏");
  assert.match(body, /redactLogChanges\(e\.changes\)/, "GET settings 的 editLog 未脱敏");
});

test("SEC-02 保存响应里 secret 不写值", () => {
  assert.match(API, /spec\.type === "secret"[\s\S]{0,160}已更新（值不回显）/,
    "handleUpdateSettings 对 secret 仍可能输出明文");
});

test("SEC-02 快照落库前脱敏，回滚保留当前 secret", () => {
  assert.match(API, /data: redactSecrets\(previousData\)/, "快照未脱敏");
  assert.match(API, /快照不含 secret[\s\S]{0,400}restored\[k\] = current\[k\]/,
    "回滚未保留当前 secret（可能导致回滚即清空密钥）");
});

// ─────────────────────────────────────────────────────────────
// SEC-03：临时文件 URL 必须校验归属
// ─────────────────────────────────────────────────────────────

test("SEC-03 file-url 校验对象归属", () => {
  const fn = API.slice(API.indexOf("async function handleFileUrl"));
  const body = fn.slice(0, fn.indexOf("\nasync function", 10));
  assert.match(body, /ownerDirOf\(auth\.sub\)/, "未按当前账号生成归属目录");
  assert.match(body, /not-owner/, "未拒绝非本人对象");
  assert.match(body, /403/, "非本人对象未返回 403");
  assert.doesNotMatch(body, /const ok = list\.filter\(\(x\) => typeof x === "string" && x\.indexOf\("cloud:\/\/"\) === 0\);/,
    "仍是旧的『只看 cloud:// 前缀』实现");
});

test("SEC-03 上传路径用账号摘要而非前缀切片", () => {
  assert.match(API, /function ownerDirOf\(accountId\)/);
  assert.match(API, /createHash\("sha256"\)[\s\S]{0,120}slice\(0, 24\)/);
  assert.match(API, /"user\/" \+ ownerDirOf\(auth\.sub\) \+ "\/"/);
});

// ─────────────────────────────────────────────────────────────
// AUTH-02：额度检查 fail-closed
// ─────────────────────────────────────────────────────────────

test("AUTH-02 额度服务异常时拒绝出图，不再 fail-open", () => {
  const fn = IMAGE.slice(IMAGE.indexOf("async function quotaExhausted"));
  const body = fn.slice(0, fn.indexOf("\n// ──", 10));
  // 10-24：401/403 现在单独走 denied 分支（透传"会员到期/停用"），5xx 仍 fail-closed。
  // 窗口放宽到 1200 字符，但两种分支都必须给出 exhausted: true —— 任何一条都不放行。
  assert.match(body, /if \(!r\.ok\)[\s\S]{0,1200}exhausted: true/, "HTTP 非 2xx 未拒绝");
  assert.match(body, /r\.status === 401 \|\| r\.status === 403[\s\S]{0,200}denied: r\.status/, "401/403 未单独处理");
  assert.match(body, /catch \(e\)[\s\S]{0,260}exhausted: true/, "异常路径未拒绝");
  assert.match(body, /unavailable: true/, "未区分『超额』与『无法确认』");
  assert.doesNotMatch(body, /exhausted: false \};?\s*\} finally/, "仍是旧的放行写法");
});

// ─────────────────────────────────────────────────────────────
// BILL-01 / BILL-02：幂等隔离与账务确认
// ─────────────────────────────────────────────────────────────

test("BILL-01 幂等键绑定 accountId", () => {
  assert.match(IMAGE, /function idemKey\(rid, accountId\)/, "缺少按账号派生的幂等键");
  assert.match(IMAGE, /update\(String\(accountId\) \+ ":" \+ String\(rid\)\)/, "幂等键未包含 accountId");
  assert.match(IMAGE, /const sameOwner = !d \|\| String\(d\.accountId \|\| ""\) === String\(accountId\)/,
    "命中缓存时未校验归属");
});

test("BILL-01 缺 requestId 时在入口生成一次并全程复用", () => {
  // 10-24：兜底生成必须发生在入口（normalizeRid），而不是 claimIdem 内部改局部变量。
  assert.match(IMAGE, /function normalizeRid\(raw\)/, "缺少 requestId 规范化函数");
  assert.match(IMAGE, /return "srv-" \+ Date\.now\(\)\.toString\(36\)/, "缺少服务端兜底幂等键");
  assert.match(IMAGE, /const rid = normalizeRid\(body\.requestId\)/, "入口未规范化 requestId");
  assert.doesNotMatch(IMAGE, /if \(!rid\) return \{ state: "none" \}/, "仍是缺 rid 就放行的旧逻辑");
  // claimIdem 内部也不许再各自造 id
  const seg = IMAGE.slice(IMAGE.indexOf("async function claimIdem"));
  assert.doesNotMatch(seg.slice(0, 400), /if \(!rid\) rid = "srv-/, "claimIdem 内部仍在私造 requestId");
});

test("BILL-02 记账按唯一事件分阶段提交，flushJobs 只在成功时标 committed", () => {
  // 10-24 P0-4：账户累计 + 明细两次独立写入不可能原子，
  // 改为「唯一账务事件 + CAS 标记 + 明细复用同一 _id」的实现。
  assert.match(IMAGE, /const BILLING_COLL = "bf_billing_events"/, "缺少账务事件账本");
  assert.match(IMAGE, /function billingEventIdOf\(accountId, jobKey\)/, "缺少事件 ID 派生");
  assert.match(IMAGE, /if \(accountOk && usageOk\)[\s\S]{0,200}return true/, "未在双阶段都成功时返回成功");
  assert.match(IMAGE, /state: "committed", usageApplied: true/, "事件未落 committed 状态");
  assert.match(IMAGE, /_id: eventId, accountId, kind: "image"/, "明细未复用事件 ID（会重复流水）");
  assert.match(IMAGE, /const billed = cost <= 0 \? true : await addImageCost/, "flushJobs 未检查记账结果");
  assert.match(IMAGE, /if \(!billed\)[\s\S]{0,260}costTries/, "记账失败未保留重试标记");
});

// ─────────────────────────────────────────────────────────────
// BIZ-01：续费审批不得重复写账号
// ─────────────────────────────────────────────────────────────

test("BIZ-01 续费只执行一次 accounts.update", () => {
  const start = API.indexOf("const renewPatch = {");
  const seg = API.slice(start, start + 4000);
  // 10-25 C2.2-FIX：续费写入从"doc().update(renewPatch)"改为带条件的 where().update()，
  // 目的不只是"只写一次"，而是"同一次写里同时校验幂等键与到期日版本"。
  const unconditional = seg.match(/db\.collection\(C\.accounts\)\.doc\(reqDoc\.accountId\)\.update\(renewPatch\)/g) || [];
  assert.strictEqual(unconditional.length, 0, "仍存在无条件的整包写入（会覆盖并发续费）");
  const conditional = seg.match(/where\(\{[\s\S]{0,160}renewedRequestIds: _\.nin/g) || [];
  assert.ok(conditional.length >= 1, "续费未使用条件更新（缺幂等键）");
});

// ─────────────────────────────────────────────────────────────
// CFG-03：空值 = 回默认（secret 例外）
// ─────────────────────────────────────────────────────────────

test("CFG-03 配置读取区分 secret 与非 secret 的空值语义", () => {
  assert.match(API, /if \(spec && spec\.type === "secret"\) continue;/, "secret 空值未跳过");
  assert.match(API, /RUNTIME\[k\] = spec \? spec\.def\(\) : undefined;/, "非 secret 空值未回默认");
});

test("CFG-03 保存时空串走重置分支", () => {
  assert.match(API, /const wantsReset = \(v === null \|\| String\(v\)\.trim\(\) === ""\)/);
  assert.match(API, /if \(wantsReset && spec\.type !== "secret"\)[\s\S]{0,200}delete data\[k\]/);
});

// ─────────────────────────────────────────────────────────────
// 第二轮安全加固（IMG-01 / IMG-02 / REQ-01 / CFG-01）
// ─────────────────────────────────────────────────────────────

test("IMG-01 出站抓图有域名白名单与私网拦截", () => {
  assert.match(GUARDS, /const ALLOWED_FETCH_SUFFIXES = \[/, "缺少域名白名单");
  assert.match(GUARDS, /function isPrivateHost\(host\)/, "缺少私网判断");
  assert.match(GUARDS, /a === 169 && b === 254/, "未拦截 link-local / 云元数据");
  assert.match(GUARDS, /u\.protocol !== "https:"/, "未强制 https");
  assert.match(GUARDS, /u\.port && u\.port !== "443"/, "未限制端口");
  assert.match(GUARDS, /u\.username \|\| u\.password/, "未禁止 URL 内嵌凭据");
  assert.match(IMAGE, /redirect: "error"/, "仍会跟随重定向（可被 302 到内网绕过）");
  assert.match(IMAGE, /logStage\("fetch_blocked"/, "拦截未留可观测日志");
});

test("IMG-01 响应体有大小上限与 MIME 校验", () => {
  assert.match(IMAGE, /const FETCH_MAX_BYTES = 8 \* 1024 \* 1024/);
  assert.match(IMAGE, /if \(declared > limit\) return null/);
  assert.match(IMAGE, /if \(buf\.length > limit\) return null/);
  assert.match(IMAGE, /!ct\.startsWith\("image\/"\)[\s\S]{0,120}return null/);
});

test("IMG-02 显式像素尺寸有上下限与总像素预算", () => {
  assert.match(GUARDS, /const SIZE_MAX_EDGE = 4096/);
  assert.match(GUARDS, /const SIZE_MAX_PIXELS = 4_200_000/);
  assert.match(GUARDS, /function clampExplicitSize\(raw\)/);
  assert.match(GUARDS, /if \(w \* h > SIZE_MAX_PIXELS\)/, "超出像素预算时未按比例缩放");
  // 解码前保护（图片炸弹）
  assert.match(GUARDS, /const DECODE_MAX_PIXELS = 40_000_000/);
  assert.match(GUARDS, /function probeImageSize\(buf\)/);
  assert.match(GUARDS, /function decodedSizeAllowed\(size\)/);
  assert.match(IMAGE, /decodedSizeAllowed\(probeImageSize\(buf\)\)/, "decodeImage 未在解码前校验尺寸");
});

test("REQ-01 两个函数都按字节而非字符计数", () => {
  assert.match(IMAGE, /total \+= c\.length/, "bf-image 未按字节累加");
  assert.match(IMAGE, /Buffer\.concat\(chunks\)/, "bf-image 未用 Buffer 拼接");
  assert.doesNotMatch(IMAGE, /if \(data\.length > 20 \* 1024 \* 1024\)/, "仍是旧字符计数");
  assert.match(API, /total \+= c\.length/, "bf-api 未按字节累加");
  assert.match(API, /Buffer\.concat\(chunks\)/, "bf-api 未用 Buffer 拼接");
  assert.doesNotMatch(API, /if \(raw\.length > maxBytes\)/, "仍是旧字符计数");
});

test("CFG-01 档位每次从不可变基线重建", () => {
  assert.match(API, /const DEFAULT_TIERS = JSON\.parse\(JSON\.stringify\(TIERS\)\)/);
  assert.match(API, /function resetTiersToDefault\(\)/);
  assert.match(API, /applyTiersInto\(TIERS, computeTiers\(DEFAULT_TIERS/,
    "applyRuntime 未走「基线 + 覆盖」的纯函数");
  assert.match(TIERS_MOD, /function computeTiers\(base, override, order\)/);
  assert.match(TIERS_MOD, /features: Object\.assign\(\{\}, d\.features\)/, "features 未深拷贝，会污染基线");
  assert.match(TIERS_MOD, /function applyTiersInto\(target, next, order\)/);
});

// ─────────────────────────────────────────────────────────────
// AUTH-01：账号停用/改密后旧 token 立即失效
// ─────────────────────────────────────────────────────────────

test("AUTH-01 会员鉴权校验实时状态与版本", () => {
  const fn = API.slice(API.indexOf("async function requireMember"));
  const body = fn.slice(0, fn.indexOf("\nasync function", 10));
  assert.match(body, /await db\.collection\(C\.accounts\)\.doc\(payload\.sub\)\.get\(\)/, "未读取账号实时状态");
  assert.match(body, /acc\.status !== "active"[\s\S]{0,160}ACCOUNT_SUSPENDED/, "未校验停用");
  assert.match(body, /Number\(acc\.pwv \|\| 0\) !== Number\(payload\.pwv \|\| 0\)/, "未校验密码版本");
  assert.match(body, /Number\(acc\.sv \|\| 0\) !== Number\(payload\.sv \|\| 0\)/, "未校验会话版本");
  assert.match(body, /MEMBERSHIP_EXPIRED/, "未校验会员到期");
});

test("AUTH-01 鉴权 DB 异常时 fail-closed", () => {
  const fn = API.slice(API.indexOf("async function requireMember"));
  const body = fn.slice(0, fn.indexOf("\nasync function", 10));
  assert.match(body, /catch \(e\)[\s\S]{0,260}503[\s\S]{0,80}AUTH_UNAVAILABLE/,
    "DB 不可用时未拒绝（会变成全站免鉴权）");
});

test("AUTH-01 员工鉴权校验实时状态，角色以库为准", () => {
  const fn = API.slice(API.indexOf("async function requireStaff"));
  const body = fn.slice(0, fn.indexOf("\nasync function", 10));
  assert.match(body, /await db\.collection\(C\.staff\)\.doc\(payload\.sub\)\.get\(\)/, "未读取员工实时状态");
  assert.match(body, /STAFF_DISABLED/, "未校验停用");
  assert.match(body, /const liveRole = String\(st\.role \|\| payload\.role/, "角色未以数据库为准");
});

test("AUTH-01 所有调用点都 await（漏一个就等于该端点免鉴权）", () => {
  // 定义行不算；其余出现次数必须与 await 次数一致
  const defs = (API.match(/async function (requireMember|requireStaff|requireAny)\(/g) || []).length;
  const awaits = (API.match(/await require(Member|Staff|Any)\(req, res/g) || []).length;
  assert.ok(awaits >= 50, `await 调用点过少：${awaits}`);
  assert.strictEqual(defs, 3, "鉴权函数定义数量异常");
  // 不允许存在未加 await 的裸调用
  const bare = API.match(/(?<!await )(?<!function )require(Member|Staff|Any)\(req, res/g) || [];
  assert.strictEqual(bare.length, 0, `存在未 await 的鉴权调用：${bare.join(", ")}`);
});

test("BILL-01b 幂等三件套使用同一个 key（漏一个就会永远 processing）", () => {
  // idemKey 定义在 claimIdem 之前，所以在全文范围断言
  assert.match(IMAGE, /function idemKey\(rid, accountId\)/, "缺少 idemKey");
  const seg = IMAGE.slice(IMAGE.indexOf("async function claimIdem"));
  assert.match(seg.slice(0, 600), /const key = idemKey\(id, accountId\)/, "claimIdem 未用 idemKey");
  // claimIdem / finishIdem / abortIdem 都必须走 idemKey
  const fn = IMAGE.slice(IMAGE.indexOf("async function finishIdem"));
  const fin = fn.slice(0, fn.indexOf("async function flushJobs"));
  assert.match(fin, /const key = idemKey\(rid, accountId\)/, "finishIdem 未用 idemKey");
  assert.match(fin, /doc\(key\)\.update/, "finishIdem 仍在用裸 rid 作为 _id");
  assert.doesNotMatch(fin, /doc\(rid\)/, "finishIdem 仍用 doc(rid)");
  assert.match(fin, /logStage\("idem_finish_failed"/, "finishIdem 失败未留日志");
});

test("定价按模型分档，Flash 与 Pro 不同价", () => {
  const fn = IMAGE.slice(IMAGE.indexOf("function priceForSize"));
  const body = fn.slice(0, fn.indexOf("const C = {"));
  assert.match(body, /function priceForSize\(size, model\)/, "priceForSize 未接 model 参数");
  assert.match(body, /seedream-5-0-flash[\s\S]{0,80}IMAGE_PRICE_FAST/, "Flash 未走独立价档");
  assert.match(body, /IMAGE_PRICE_FAST/, "缺少 Flash 单价配置");
  // 调用点必须把实际模型传进去
  assert.match(IMAGE, /priceForSize\(resolveSize\(body\.size, aspectRatio\), usedModel\)/,
    "调用点未传 usedModel，价格仍按旧逻辑算");
  // 两端默认值必须一致（此前 0.61 vs 0.80 漂移）
  assert.match(API, /IMAGE_PRICE_2K[\s\S]{0,120}\|\| 0\.9\)/, "bf-api 2K 默认值未对齐 0.9");
  assert.match(IMAGE, /IMAGE_PRICE_2K: process\.env\.IMAGE_PRICE_2K \|\| "0\.9"/, "bf-image 2K 默认值未对齐 0.9");
});

test("智能分配只在未显式指定时生效", () => {
  const fn = IMAGE.slice(IMAGE.indexOf("function selectImageRoute"));
  const body = fn.slice(0, fn.indexOf("let _rtLoadedAt"));
  // 10-25：原来靠 `rawTier !== "auto"` 判显式，pro/hd 这类别名会漏判并静默降级；
  // 现在统一先 normalizeTier() 归一化，再比较 high/fast，语义不变但覆盖所有别名。
  assert.match(body, /const tier = normalizeTier\(qualityTier\)/, "未先归一化档位");
  assert.match(body, /if \(tier === "high"\) return \{ model: m\.pro/, "high 未走 Pro");
  assert.match(body, /if \(tier === "fast"\) return \{ model: m\.fast/, "fast 未走 Flash");
  assert.match(body, /inferQualityTier\(prompt, renderIntent\)/, "未做 prompt 推断（auto 分支）");
  assert.match(body, /inferred === "high"[\s\S]{0,80}m\.pro/, "推断 high 未走 Pro");
});

// ── DS4.1 §3.1：鉴权不得因密钥未加载而抛异常（2026-10-25）──────────────────

test("AUTH-10 密钥未就绪时 verifyToken 不得抛 TypeError", () => {
  const start = API.indexOf("function verifyToken");
  const body = API.slice(start, start + 700);
  assert.ok(API.includes("function secretsReady"), "缺少密钥就绪判断");
  const guard = body.indexOf("if (!secretsReady()) return null");
  const hmac = body.indexOf('createHmac("sha256", SECRETS.tokenSecret)');
  assert.ok(guard > 0, "密钥未就绪时没有短路");
  assert.ok(hmac > guard, "HMAC 必须在密钥就绪判断之后（否则空密钥仍会抛）");
});

test("AUTH-11 密钥不可用必须回 503，不能伪装成 401/500", () => {
  assert.ok(API.includes("async function ensureSecretsForAuth"), "缺少补载函数");
  const memberAt = API.indexOf("async function requireMember");
  const member = API.slice(memberAt, memberAt + 900);
  assert.ok(member.includes("ensureSecretsForAuth()"), "requireMember 未校验密钥");
  assert.ok(member.includes('503, "AUTH_UNAVAILABLE"'), "requireMember 未回 503");
  const staffAt = API.indexOf("async function requireStaff");
  const staff = API.slice(staffAt, staffAt + 900);
  assert.ok(staff.includes("ensureSecretsForAuth()"), "requireStaff 未校验密钥");
  assert.ok(staff.includes('503, "AUTH_UNAVAILABLE"'), "requireStaff 未回 503");
});

test("AUTH-12 token 两段格式与空值都要挡在 HMAC 之前", () => {
  const start = API.indexOf("function verifyToken");
  const body = API.slice(start, start + 700);
  assert.ok(body.includes("typeof token !== \"string\""), "未校验 token 类型");
  assert.ok(body.includes("parts.length !== 2"), "未校验两段格式");
});
