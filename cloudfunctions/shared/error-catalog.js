// ============================================================================
// error-catalog.js —— 统一错误目录与公共文案映射
//
// 设计原则（来自实施计划 §2.2 / §2.3）：
//   1. 内部错误码只用于机器判断与日志，**绝不出现在用户可见文案里**；
//   2. 每个错误必须同时给出：分类、是否可重试、面向用户的自然语言、受控动作；
//   3. 未知错误一律走安全兜底，不泄露供应商响应、堆栈、路径或内部术语。
//
// Canonical source. Runtime compatibility adapters load the build-packaged copy.
// ============================================================================

/**
 * @typedef {Object} Entry
 * @property {string} category   机器分类：input/auth/capability/upstream_timeout/upstream_busy/upstream_error/storage/billing/cancelled/internal
 * @property {boolean} retryable 用户能否原样重试
 * @property {string} message    面向用户的自然语言（禁止出现错误码/HTTP 状态/供应商原文）
 * @property {string[]} actions  受控动作 ID，客户端映射到本地实现
 */

/** @type {Record<string, Entry>} */
const CATALOG = {
  // ── 输入 ──
  BAD_REQUEST: {
    category: "input", retryable: false,
    message: "这次的要求里还缺一点必要信息，补充之后我就能继续。",
    actions: ["edit_request"],
  },
  BAD_ID: {
    category: "input", retryable: false,
    message: "这个标识格式不正确，操作已取消。",
    actions: ["edit_request"],
  },
  BAD_VALUE: {
    category: "input", retryable: false,
    message: "有一项设置的值不太对，改一下再试。",
    actions: ["edit_request"],
  },
  NO_CHANGE: {
    category: "input", retryable: false,
    message: "没有检测到实际改动。",
    actions: [],
  },
  CONFLICT: {
    category: "input", retryable: true,
    message: "这条内容刚被其他人改过，刷新后再试一次就能看到最新状态。",
    actions: ["retry"],
  },

  // ── 鉴权 / 权限 ──
  UNAUTHORIZED: {
    category: "auth", retryable: false,
    message: "登录状态已失效，重新登录后就能继续。",
    actions: ["relogin"],
  },
  FORBIDDEN: {
    category: "auth", retryable: false,
    message: "当前账号没有这个操作权限。",
    actions: [],
  },
  ACCOUNT_SUSPENDED: {
    category: "auth", retryable: false,
    message: "这个账号目前处于停用状态，需要联系我们恢复后才能继续使用。",
    actions: ["contact_support"],
  },
  MEMBERSHIP_EXPIRED: {
    category: "auth", retryable: false,
    message: "会员已到期，续费后可以继续使用。",
    actions: ["renew"],
  },
  SESSION_REPLACED: {
    category: "auth", retryable: false,
    message: "这个账号已在其他设备登录，当前设备需要重新登录。",
    actions: ["relogin"],
  },
  STAFF_DISABLED: {
    category: "auth", retryable: false,
    message: "这个员工账号已被停用，请联系管理员。",
    actions: ["contact_support"],
  },
  AUTH_UNAVAILABLE: {
    category: "internal", retryable: true,
    message: "暂时无法确认你的账号状态，稍等片刻再试一次。",
    actions: ["retry"],
  },

  // ── 能力不支持 ──
  TASK_UNSUPPORTED: {
    category: "capability", retryable: false,
    message: "这个效果目前还没法一次完成。我可以先帮你做出一张，其余的再接着做。",
    actions: ["single_only", "edit_request", "cancel"],
  },
  IMAGE_SIZE_UNSUPPORTED: {
    category: "input", retryable: false,
    message: "当前画布比例超出安全尺寸范围，尚未开始生成。请改用常见比例（如 1:1、4:3、3:4、16:9 或 9:16）后重试。",
    actions: ["edit_request", "cancel"],
  },
  FEATURE_DISABLED: {
    category: "capability", retryable: false,
    message: "这个功能暂时没有开放。",
    actions: ["cancel"],
  },

  // ── 额度 / 计费 ──
  QUOTA_EXCEEDED: {
    category: "billing", retryable: false,
    message: "当前额度已经用完，额度重置后可以继续使用。",
    actions: ["view_quota"],
  },
  SERIES_ALL_FAILED: {
    category: "upstream_error", retryable: true,
    message: "这次几张都没有生成成功，可以再试一次；已经保存过的图片不会有任何变化。",
    actions: ["retry", "edit_request"],
  },
  PLEASE_UPDATE: {
    category: "capability", retryable: false,
    message: "这个功能需要更新到最新版本才能使用。更新后原来的数据不会丢。",
    actions: ["contact_support"],
  },
  QUOTA_CHECK_UNAVAILABLE: {
    category: "billing", retryable: true,
    message: "暂时无法确认额度，请稍后重试。这次没有生成图片，也不会扣费。",
    actions: ["retry", "view_quota"],
  },
  QUOTA_INSUFFICIENT: {
    category: "billing", retryable: false,
    message: "剩余额度不足以完成这次的全部图片。可以先做一张，或续费后再试。",
    actions: ["single_only", "renew", "cancel"],
  },
  SERIES_NOT_FOUND: {
    category: "input", retryable: false,
    message: "没有找到这次组图任务的记录，重新描述一次就能再生成。",
    actions: ["edit_request"],
  },
  TASK_CANCELLED: {
    category: "cancelled", retryable: false,
    message: "这次任务已经取消，没有继续生成。",
    actions: [],
  },
  RATE_LIMITED: {
    category: "billing", retryable: true,
    message: "短时间内请求比较多，稍微等一下再试。",
    actions: ["retry"],
  },
  IN_PROGRESS: {
    category: "billing", retryable: true,
    message: "同一张图还在生成中，等它完成就好，不用重复提交。",
    actions: [],
  },

  // ── 上游 ──
  UPSTREAM_TIMEOUT: {
    category: "upstream_timeout", retryable: true,
    message: "这次处理没有在预期时间内返回。你的描述已经保留，可以再试一次。",
    actions: ["retry", "edit_request"],
  },
  UPSTREAM_BUSY: {
    category: "upstream_busy", retryable: true,
    message: "当前请求比较多，可以过一会儿再试。",
    actions: ["retry"],
  },
  UPSTREAM_ERROR: {
    category: "upstream_error", retryable: true,
    message: "这次没有顺利完成。可以再试一次；已完成的内容会保留。",
    actions: ["retry", "feedback"],
  },

  // ── 存储 / 文件 ──
  FILE_URL_FAILED: {
    category: "storage", retryable: true,
    message: "图片地址暂时取不到，稍后重试即可，不需要重新生成。",
    actions: ["retry"],
  },
  FILE_NOT_OWNED: {
    category: "auth", retryable: false,
    message: "这个文件不属于当前账号，无法打开。",
    actions: [],
  },
  UPLOAD_META_FAILED: {
    category: "storage", retryable: true,
    message: "上传准备没有完成，请重新选择文件再试。",
    actions: ["retry"],
  },

  CRASH_STORE_FAILED: {
    category: "storage", retryable: true,
    message: "诊断信息暂时没存上，稍后会自动重试。",
    actions: ["retry"],
  },

  // ── 同步 ──
  SYNC_FAILED: {
    category: "storage", retryable: true,
    message: "这次同步没有完成，本地数据仍然完整，稍后会自动重试。",
    actions: ["retry"],
  },
  STORAGE_UNAVAILABLE: {
    category: "storage", retryable: true,
    message: "云端保存暂未完成，本机内容已保留，稍后会重试保存。",
    actions: ["retry"],
  },
  ASSET_NOT_FOUND: {
    category: "storage", retryable: false,
    message: "没有找到可访问的文件，请从原设备重新同步或上传。",
    actions: ["feedback"],
  },
  CLOUD_INPUT_INVALID: {
    category: "input", retryable: false,
    message: "这次内容没有完整保存，请检查输入后重试。",
    actions: ["edit_request"],
  },

  // ── 兜底 ──
  INTERNAL: {
    category: "internal", retryable: true,
    message: "这次没有顺利完成。可以再试一次；如果反复出现，把下方的反馈编号发给我们。",
    actions: ["retry", "feedback"],
  },
};

/** 未知 code 的安全兜底（绝不回显原始 code） */
const FALLBACK = CATALOG.INTERNAL;

/**
 * 把内部错误码映射为可下发的公共错误对象。
 *
 * @param {string} code        内部错误码（可能为 HTTP 字符串，如 "HTTP 500"）
 * @param {Object} [opts]
 * @param {string} [opts.message] 调用方已写好的自然语言（优先于目录文案，但仍要过安全过滤）
 * @param {string} [opts.stage]   出错阶段：auth/parse/upstream/download/persist/compose/verify/billing
 * @param {string} [opts.requestId]
 * @param {Object} [opts.partialResult] 仅在确有已完成成果时传入
 * @returns {{ok:false,requestId:string,error:Object,message:string,actions:string[],partialResult:?Object}}
 */
function publicError(code, opts) {
  const o = opts || {};
  const entry = CATALOG[code] || FALLBACK;
  // 调用方自带文案时优先使用，但要挡住明显的技术串（错误码/HTTP/堆栈/路径）
  const custom = sanitizePublicMessage(o.message);
  const msg = custom || entry.message;

  // 兼容性关键：error 必须保持**字符串**（旧 App 用 `obj["error"] as? String` 判会话失效），
  // 结构化信息放 errorDetail，作为可选的增量字段。
  const safeCode = CATALOG[code] ? code : "INTERNAL";
  const body = {
    ok: false,
    requestId: String(o.requestId || ""),
    error: safeCode,
    errorDetail: {
      code: safeCode,
      category: entry.category,
      retryable: entry.retryable,
      stage: String(o.stage || ""),
    },
    message: msg,
    actions: entry.actions.slice(),
  };
  if (o.partialResult) body.partialResult = o.partialResult;
  return body;
}

/** 调用方文案的安全过滤：含技术痕迹就丢弃，改用目录文案 */
function sanitizePublicMessage(text) {
  const s = String(text || "").trim();
  if (!s) return "";
  if (s.length > 120) return "";
  // 出现这些痕迹说明更像内部信息，不能直接给用户看
  if (/\b(HTTP|ECONN|ETIMEDOUT|ENOTFOUND|stack|undefined|null|NaN)\b/i.test(s)) return "";
  if (/\b[45]\d{2}\b/.test(s)) return "";                 // 裸状态码
  // 纯 kebab-case 的内部原因串（如 series-unsupported / image-provider-timeout）
  if (/^[a-z][a-z0-9]*(-[a-z0-9]+)+$/.test(s)) return "";
  if (/[A-Z]{2,}_/.test(s)) return "";                    // 大写下划线错误码
  if (/^[A-Z][A-Z0-9_]{3,}$/.test(s)) return "";          // 纯大写错误码
  if (/[/\\][\w.-]+\.(js|json|swift)/.test(s)) return ""; // 文件路径
  if (/\bat\s+\w+\s*\(/.test(s)) return "";               // 堆栈帧
  return s;
}

module.exports = { CATALOG, publicError, sanitizePublicMessage };
