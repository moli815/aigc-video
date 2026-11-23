/**
 * log-safe.js —— 日志脱敏统一出口（P1：日志 PII 打码）
 *
 * 背景与目标
 *   · 10-24 之前只做到「不写密钥」：API Key 不进日志。但用户标识仍以明文出现：
 *     手机号 / 邮箱 / accountId / 身份证 / 银行卡，以及上游返回体原文（可能带 prompt）。
 *   · CloudBase 的 CLS 日志默认保留 7 天，任何有日志权限的运维/子账号都能看到明文 PII。
 *   · 本模块把「写日志」收敛成一个出口：所有日志对象先过 scrub()，再 JSON 化输出。
 *
 * 设计原则（防呆 > 方便）
 *   1. 宁可多打码，不可漏：无法判断时按最严格规则处理（丢弃或只留长度/哈希）。
 *   2. 可关联：accountId 不删除，转成稳定短哈希（sha256 前 8 位），仍可追同一个用户的一条链路，
 *      但日志泄露后无法反推真实账号，也不能拿去登录。
 *   3. 可排障：错误文案（detail/msg）保留，只对其中的 PII 形态打码并截断，不整条丢弃。
 *   4. 不抛异常：日志失败绝不影响主流程（全部 try/catch）。
 *
 * Canonical source: runtime adapters are packaged by scripts/bundle-function-shared.js.
 */
const crypto = require("crypto");

const DEFAULT_MAX_STR = 240;   // 单条字符串上限（超出截断并标注原长）
const MAX_DEPTH = 4;           // 递归深度上限，防止循环引用/超大对象
const MAX_ARRAY = 20;          // 数组最多处理前 20 项

// ── 值形态规则 ────────────────────────────────────────────────────────────
// 顺序敏感：先处理长且强的模式（JWT/Bearer/密钥），再处理证件与号码。
const RE = {
  // JWT：三段 base64url
  jwt: /\beyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\b/g,
  // Authorization 头：Bearer xxx / Basic xxx
  auth: /\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{8,}/gi,
  // 常见的「密钥样式」串：sk-xxx / ak_xxx / api_key=xxx / token:xxx
  keyLike: /\b(?:sk|ak|pk|rk)[-_][A-Za-z0-9]{12,}\b|\b(?:api[_-]?key|access[_-]?key|secret[_-]?key|token)\s{0,2}[:=]\s{0,2}[A-Za-z0-9._~+/=-]{12,}/gi,
  // URL 里内嵌的 user:password@host
  urlCred: /\/\/[^/\s:@]+:[^/\s@]+@/g,
  // 邮箱
  email: /[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+/g,
  // 中国大陆身份证：17 位数字 + 数字/X（\w 边界避免误伤十六进制串）
  cnId: /(?<![\w])\d{6}\d{8}\d{3}[\dXx](?![\w])/g,
  // 中国大陆手机号（允许 +86 前缀，允许空格/连字符分组：138-1234-5678）
  cnPhone: /(?<![\w])(?:\+?86[-\s]?)?1[3-9]\d(?:[-\s]?\d{4}){2}(?![\w])/g,
  // 签名类 query 参数：临时票据/签名一律不落日志
  signedQuery: /([?&](?:X-Tos-Signature|X-Amz-Signature|X-Amz-Credential|Signature|sign|signature|token|access_token|Expires|OSSAccessKeyId|q-signature)=)[^&\s"']*/gi,
  // 银行卡：16~19 位纯数字（\w 边界避免误伤 hash）
  bank: /(?<![\w])\d{16,19}(?![\w])/g,
  // 空格/换行：日志保持单行，避免伪造多行日志
  newline: /[\r\n\t]+/g,
};

function shorthash(s) {
  return crypto.createHash("sha256").update(String(s)).digest("hex").slice(0, 8);
}

/** 邮箱：保留前 2 个字符 + 域名，例如 wangzong836@gmail.com → wa***@gmail.com */
function maskEmail(v) {
  const s = String(v);
  const at = s.lastIndexOf("@");
  if (at <= 0) return "***";
  const local = s.slice(0, at);
  const domain = s.slice(at + 1);
  const head = local.length <= 2 ? local.slice(0, 1) : local.slice(0, 2);
  return head + "***@" + domain;
}

/** 手机号：13812345678 / 138-1234-5678 / +86 138 1234 5678 → 统一输出 138****5678 */
function maskPhone(v) {
  const s = String(v);
  const digits = s.replace(/[^\d]/g, "");
  const m = digits.match(/(1[3-9]\d)(\d{4})(\d{4})$/);
  if (!m) return "***";
  return m[1] + "****" + m[3];
}

/** 证件/卡号：前 3 + 后 4，中间等长星号 */
function maskDigits(v) {
  const s = String(v);
  if (s.length <= 7) return "***";
  return s.slice(0, 3) + "*".repeat(Math.max(3, s.length - 7)) + s.slice(-4);
}

/**
 * 文本脱敏：把一段自由文本里的 PII/密钥形态全部打码。
 * 用于错误文案、上游报错、UA 等「需要保留可读性」的字段。
 */
function maskText(input, maxLen) {
  if (input === null || input === undefined) return "";
  let s;
  try { s = typeof input === "string" ? input : String(input); }
  catch (e) { return "[unstringifiable]"; }
  const limit = Number(maxLen || DEFAULT_MAX_STR);
  const rawLen = s.length;
  if (rawLen > limit) s = s.slice(0, limit) + "…(+" + (rawLen - limit) + ")";
  try {
    s = s.replace(RE.jwt, "«jwt»")
      .replace(RE.auth, (m, kw) => kw + " «redacted»")
      .replace(RE.keyLike, "«key»")
      .replace(RE.urlCred, "//«cred»@")
      .replace(RE.signedQuery, "$1«omitted»")
      .replace(RE.email, (m) => maskEmail(m))
      .replace(RE.cnId, (m) => maskDigits(m))
      .replace(RE.cnPhone, (m) => maskPhone(m))
      .replace(RE.bank, (m) => maskDigits(m))
      .replace(RE.newline, " ");
  } catch (e) { return "[mask-failed]"; }
  return s;
}

/**
 * 账号/用户标识 → 稳定短标签。
 * 不做单向删除，是因为排障时「同一个账号的连续行为」必须能串起来；
 * sha256 前 8 位既不可逆，也不会因为实例重启而变。
 */
function tagId(v, prefix) {
  if (v === null || v === undefined || v === "") return "";
  return (prefix || "id") + ":" + shorthash(v);
}

// ── 键名规则 ──────────────────────────────────────────────────────────────
const KEY = {
  secret: /pass(word|wd)?|secret|token|api[-_]?key|access[-_]?key|private[-_]?key|credential|signature|session|cookie|authorization|^auth$/i,
  email: /e?mail/i,
  phone: /phone|mobile|msisdn|telephone/i,
  idcard: /id[-_]?card|idcard|identity|id[-_]?no|passport/i,
  account: /^(sub|uid|userId|user_id|accountId|account_id|openid|unionid|ownerId|owner_id|targetAccountId|target_account_id)$/i,
  // 用户原文：只留长度 + 哈希，绝不写内容
  content: /^(prompt|content|answer|text|query|question|reply|input|output|completion|messages)$/i,
  // 上游原文：直接丢弃
  rawBody: /^(body|raw|rawBody|response|respBody|errBody|stdout|stderr)$/i,
  // URL：保留 host + path，抹掉 query（签名/临时票据都在 query 里）
  url: /^(url|uri|href|link|image|imageUrl|qrUrl)$/i,
  // 诊断文案：保留但打码
  message: /^(detail|msg|message|err|error|reason|note|desc|description)$/i,
};

/** URL 只保留 scheme://host/path，query 与 fragment 一律丢弃（签名/ticket 都在里面） */
function maskUrl(v) {
  const s = String(v);
  try {
    const u = new URL(s);
    const q = u.search ? "?«omitted»" : "";
    return u.origin + u.pathname + q;
  } catch (e) {
    // 不是合法 URL：按普通文本打码，并把可能的内嵌凭据去掉
    return maskText(s, 200).replace(/([?&][^=&\s]+)=[^&\s]*/g, "$1=«omitted»");
  }
}

/**
 * 递归脱敏一个日志对象。
 * opts.stringMax   单串上限
 * opts.dropContent 是否把用户原文替换成 {len,sha}（默认 true）
 * opts.keepKeys    需要原样保留的键（例如 tag、stage、fn、requestId）
 */
function scrub(value, opts) {
  const o = opts || {};
  const maxStr = Number(o.stringMax || DEFAULT_MAX_STR);
  const dropContent = o.dropContent !== false;
  const keep = o.keepKeys || ["tag", "stage", "fn", "ts", "requestId", "code", "category", "httpStatus", "retryable", "m", "ms"];

  function walk(v, depth, keyName) {
    if (v === null || v === undefined) return v;
    const k = keyName || "";
    if (k && keep.indexOf(k) >= 0) {
      // 白名单键只做字符串截断，避免 requestId 这类可检索字段被打码
      return typeof v === "string" ? v.slice(0, maxStr) : v;
    }
    // 数值：默认原样保留（ms/count/cost 这类必须是数字，不能变成字符串），
    // 只有落在敏感键上才按字符串打码（手机号/证件号偶尔被存成 number）。
    if (typeof v === "number") {
      if (!Number.isFinite(v)) return String(v);
      if (k && (KEY.secret.test(k) || KEY.email.test(k) || KEY.phone.test(k) || KEY.idcard.test(k) || KEY.account.test(k))) {
        const s = String(v);
        if (KEY.secret.test(k)) return "«redacted»";
        if (KEY.email.test(k)) return maskEmail(s);
        if (KEY.phone.test(k)) return maskPhone(s);
        if (KEY.idcard.test(k)) return maskDigits(s);
        return tagId(s, "acct");
      }
      return v;
    }
    if (typeof v === "string") {
      const s = String(v);
      if (k && KEY.secret.test(k)) return "«redacted»";
      if (k && KEY.email.test(k)) return maskEmail(s);
      if (k && KEY.phone.test(k)) return maskPhone(s);
      if (k && KEY.idcard.test(k)) return maskDigits(s);
      if (k && KEY.account.test(k)) return tagId(s, "acct");
      if (k && KEY.url.test(k)) return maskUrl(s);
      if (k && dropContent && KEY.content.test(k)) return { len: s.length, sha: shorthash(s) };
      if (k && KEY.rawBody.test(k)) return "«omitted:" + s.length + "»";
      if (k && KEY.message.test(k)) return maskText(s, maxStr);
      return maskText(s, maxStr);
    }
    if (typeof v === "boolean") return v;
    if (typeof v === "bigint") return String(v);
    if (typeof v === "function") return "[function]";
    if (depth >= MAX_DEPTH) return "«max-depth»";
    if (Array.isArray(v)) {
      const head = v.slice(0, MAX_ARRAY).map((x) => walk(x, depth + 1, ""));
      if (v.length > MAX_ARRAY) head.push("«+" + (v.length - MAX_ARRAY) + " more»");
      return head;
    }
    if (v instanceof Error) return { name: v.name, message: maskText(v.message, maxStr) };
    if (Buffer.isBuffer && Buffer.isBuffer(v)) return "«buffer:" + v.length + "»";
    const out = {};
    let n = 0;
    for (const kk of Object.keys(v)) {
      if (n++ >= 40) { out["«truncated»"] = true; break; }
      try { out[kk] = walk(v[kk], depth + 1, kk); }
      catch (e) { out[kk] = "«unreadable»"; }
    }
    return out;
  }

  try { return walk(value, 0, ""); }
  catch (e) { return { logError: "scrub-failed" }; }
}

/** 输出一行结构化日志（对象先脱敏再序列化，任何一个键出错都不影响其它键） */
function logSafe(obj, level) {
  try {
    const line = JSON.stringify(scrub(obj));
    if (level === "error") console.error(line); else console.log(line);
  } catch (e) {
    try { console.log(JSON.stringify({ tag: "log_failed" })); } catch (e2) { /* 彻底放弃 */ }
  }
}

module.exports = {
  maskText, maskEmail, maskPhone, maskDigits, maskUrl,
  tagId, shorthash, scrub, logSafe,
  // 便于测试断言
  _RE: RE, _KEY: KEY,
};
