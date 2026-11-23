// ============================================================================
// media-guards.js —— 生图链路的纯判断函数（无 IO、无全局状态）
//
// 抽出来的唯一目的：**能被契约测试直接 require**。
// bf-image/index.js 末尾会 server.listen()，测试进程 require 它会挂住，
// 所以这些"看一眼就知道对不对"的判断必须独立成模块。
// ============================================================================

// ── 出站抓图白名单 ──
const ALLOWED_FETCH_SUFFIXES = [
  ".myqcloud.com",      // 腾讯云 COS（用户上传）
  ".tcloudbase.com",    // CloudBase API 域
  ".tcloudbaseapp.com", // CloudBase 静态托管域
  ".volces.com",        // 火山方舟 / TOS
  ".byteimg.com",       // 火山图片 CDN
  ".bytecdn.cn",
];

/** 私网 / 回环 / link-local / 云元数据地址 */
function isPrivateHost(host) {
  const h = String(host || "").toLowerCase();
  if (!h) return true;
  if (h === "localhost" || h.endsWith(".localhost") || h.endsWith(".local") || h.endsWith(".internal")) return true;
  const m = h.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
  if (m) {
    const a = Number(m[1]), b = Number(m[2]);
    if (![a, b].every((n) => n >= 0 && n <= 255)) return true;   // 非法写法也拒
    if (a === 0 || a === 10 || a === 127) return true;
    if (a === 169 && b === 254) return true;                     // link-local + 云元数据
    if (a === 172 && b >= 16 && b <= 31) return true;
    if (a === 192 && b === 168) return true;
    if (a === 100 && b >= 64 && b <= 127) return true;           // CGNAT
  }
  if (h === "::1" || h.startsWith("fc") || h.startsWith("fd") || h.startsWith("fe80")) return true;
  return false;
}

/**
 * 出站 URL 审核。返回 URL 对象或 null。
 *
 * 残余风险（明确记录，不假装解决）：DNS 解析后取到的 IP 无法在应用层二次校验，
 * 理论上存在 DNS rebinding。但白名单全部是云厂商自有域名，攻击者无法控制其解析；
 * 若将来要接入第三方图片域名，必须改成"解析 → 校验 IP → 用 IP 直连 + Host 头"。
 */
function safeFetchURL(raw) {
  let u;
  try { u = new URL(String(raw || "")); } catch { return null; }
  if (u.protocol !== "https:") return null;
  // 只允许默认 https 端口：非标端口常用于绕过基于主机名的策略
  if (u.port && u.port !== "443") return null;
  // 禁止 URL 内嵌凭据
  if (u.username || u.password) return null;
  const h = u.hostname.toLowerCase();
  if (!h) return null;
  // 禁止 IP 字面量：白名单是域名，IP 直连一律拒绝
  if (/^\d+\.\d+\.\d+\.\d+$/.test(h)) return null;
  if (h.includes(":")) return null;                              // IPv6 字面量
  if (isPrivateHost(h)) return null;
  // 精确后缀匹配：裸域或 .suffix。endsWith(".myqcloud.com") 不会误放 evilmyqcloud.com
  const allowed = ALLOWED_FETCH_SUFFIXES.some((suffix) => h === suffix.slice(1) || h.endsWith(suffix));
  return allowed ? u : null;
}

// ── 请求尺寸上限 ──
const SIZE_MIN_EDGE = 64;
const SIZE_MAX_EDGE = 8192;
/**
 * 10-24 实测修正：火山 Seedream 的硬性要求是 **总像素 ≥ 921600**（约 960×960）。
 * 实测 512×512 会直接返回 400 InvalidParameter：
 *   "image area must be at least 921600 pixels"
 * 旧实现只校验单边 512，放过了一个必然被上游拒绝的请求。
 * 现在低于下限时按比例**放大**到刚好满足，而不是直接拒绝（用户意图仍然被尊重）。
 */
const SIZE_MIN_PIXELS = 921_600;
// Seedream 5.0 Pro's documented 2K canvas can reach 4,622,220 pixels.
const SIZE_MAX_PIXELS = 4_622_220;

/** 显式像素尺寸钳制：非法/越界返回 null（由调用方回落默认档位） */
function clampExplicitSize(raw) {
  const m = String(raw || "").match(/^(\d+)\s*[xX×]\s*(\d+)$/);
  if (!m) return null;
  let w = Number(m[1]), h = Number(m[2]);
  if (!Number.isSafeInteger(w) || !Number.isSafeInteger(h) || !(w > 0 && h > 0) || w / h < 1 / 16 || w / h > 16) return null;
  if (w < SIZE_MIN_EDGE || h < SIZE_MIN_EDGE || w > SIZE_MAX_EDGE || h > SIZE_MAX_EDGE) return null;

  // 低于上游像素下限：等比放大（用户要 512×512 就给 960×960，而不是报错）
  if (w * h < SIZE_MIN_PIXELS) {
    const scale = Math.sqrt(SIZE_MIN_PIXELS / (w * h));
    w = Math.min(SIZE_MAX_EDGE, Math.ceil((w * scale) / 8) * 8);
    h = Math.min(SIZE_MAX_EDGE, Math.ceil((h * scale) / 8) * 8);
  }
  // 仍然不够（极端窄长比例，被单边上限卡住）→ 判定不合法
  if (w * h < SIZE_MIN_PIXELS) return null;

  if (w * h > SIZE_MAX_PIXELS) {
    const scale = Math.sqrt(SIZE_MAX_PIXELS / (w * h));
    w = Math.max(SIZE_MIN_EDGE, Math.floor((w * scale) / 8) * 8);
    h = Math.max(SIZE_MIN_EDGE, Math.floor((h * scale) / 8) * 8);
  }
  return `${w}x${h}`;
}

// ── 解码前尺寸探测（防图片炸弹）──
const DECODE_MAX_EDGE = 12000;
const DECODE_MAX_PIXELS = 40_000_000;   // 40MP

/**
 * 从图片头读宽高，不解码像素。
 * 支持 PNG / JPEG(SOF) / GIF；拿不到返回 null。
 */
function probeImageSize(buf) {
  if (!buf || buf.length < 16) return null;
  try {
    if (buf[0] === 0x89 && buf[1] === 0x50 && buf.length >= 24) {
      return { w: buf.readUInt32BE(16), h: buf.readUInt32BE(20), kind: "png" };
    }
    if (buf.length >= 10 && buf.toString("ascii", 0, 3) === "GIF") {
      return { w: buf.readUInt16LE(6), h: buf.readUInt16LE(8), kind: "gif" };
    }
    if (buf[0] === 0xFF && buf[1] === 0xD8) {
      let i = 2;
      while (i + 9 < buf.length) {
        if (buf[i] !== 0xFF) { i++; continue; }
        const marker = buf[i + 1];
        if (marker === 0xD8 || marker === 0x01 || (marker >= 0xD0 && marker <= 0xD7)) { i += 2; continue; }
        const len = buf.readUInt16BE(i + 2);
        if (len < 2) break;
        const isSOF = (marker >= 0xC0 && marker <= 0xC3) || (marker >= 0xC5 && marker <= 0xC7) ||
                      (marker >= 0xC9 && marker <= 0xCB) || (marker >= 0xCD && marker <= 0xCF);
        if (isSOF) return { w: buf.readUInt16BE(i + 7), h: buf.readUInt16BE(i + 5), kind: "jpeg" };
        i += 2 + len;
      }
    }
  } catch (e) { /* 头部损坏 */ }
  return null;
}

/** 解码后的像素是否在上限内 */
function decodedSizeAllowed(size) {
  if (!size || !(size.w > 0 && size.h > 0)) return false;
  if (size.w > DECODE_MAX_EDGE || size.h > DECODE_MAX_EDGE) return false;
  if (size.w * size.h > DECODE_MAX_PIXELS) return false;
  return true;
}

module.exports = {
  ALLOWED_FETCH_SUFFIXES,
  isPrivateHost,
  safeFetchURL,
  SIZE_MIN_EDGE,
  SIZE_MAX_EDGE,
  SIZE_MIN_PIXELS,
  SIZE_MAX_PIXELS,
  clampExplicitSize,
  DECODE_MAX_EDGE,
  DECODE_MAX_PIXELS,
  probeImageSize,
  decodedSizeAllowed,
};
