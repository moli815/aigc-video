/**
 * 配置中心契约（2026-10-23）
 *
 * 为什么需要这个文件：此前配置元数据散在三处——后端 RUNTIME_SPECS（类型/默认值）、
 * 前端 CFG_GROUPS（分组/顺序）、前端控件（全部当普通文本框）、后端校验（数值统一
 * 0~100000、字符串统一 120 字）。四处各写一份，必然漂移。
 *
 * 现在：分组、标题、说明、控件类型、范围/枚举、风险级别、生效来源统一在这里声明；
 * 前端只负责渲染，后端保存时用同一份规则重新校验（不信任前端）。
 */

// ── 分区（管理员视角的业务分类，不按代码变量名分）──
const SECTIONS = [
  { id: "model_provider", title: "模型与服务商", desc: "对话/生图/向量用哪个平台、哪个模型、走哪个端点。换平台只改这里，App 无需发版。" },
  { id: "generation", title: "生成与性能", desc: "超时、重试、提速模式、图片尺寸与压缩质量，以及用户看到的进度文案。" },
  { id: "context_rules", title: "上下文与回答规则", desc: "上下文压缩策略与全局回答规则。长文本改动影响所有对话，建议小步调整并观察。" },
  { id: "membership_cost", title: "会员、额度与成本", desc: "对会员记账的价格、额度池与提醒线。注意区分「向会员计价」和「供应商实际成本」。" },
  { id: "security_limits", title: "权限、安全与限流", desc: "能力总开关、单账号限流、服务时段与自动审核。改动直接影响用户可用性。" },
  { id: "storage_credentials", title: "凭证与存储", desc: "对话/生图/向量/搜索密钥与对象存储参数。密钥不回显完整值，留空表示不修改。" },
  { id: "version_compat", title: "版本与兼容", desc: "客户端版本门禁、升级提示，以及仍被旧代码路径引用的兼容字段。" },
];

// ── 键 → 分区 ──
const SECTION_OF = {
  model_provider: [
    "CHAT_PROVIDER", "CHAT_PROVIDER_BASE", "CHAT_BASE_URL", "CHAT_MODEL",
    "CHAT_MODEL_STANDARD", "CHAT_MODEL_HIGH", "CHAT_MODEL_ULTRA", "CHAT_MODEL_PRO",
    "CHAT_MODEL_UTILITY", "CHAT_MODEL_UTILITY_LITE", "CHAT_MODEL_VISION", "CHAT_THINKING_STYLE",
    "IMAGE_PROVIDER", "IMAGE_MODEL", "IMAGE_MODEL_FAST", "IMAGE_MODEL_PRO", "IMAGE_MODEL_SERIES",
    "IMAGE_ROUTING_MODE", "IMAGE_AUTO_POLICY", "IMAGE_LEGACY_BRAND_POLICY", "EMBED_MODEL",
    "IMAGE_SIZES",
  ],
  generation: [
    "APP_CHAT_TIMEOUT", "APP_CHAT_FIRST_TOKEN_TIMEOUT", "APP_IMAGE_TIMEOUT",
    "APP_STREAM_RETRY", "APP_IMAGE_RETRY", "APP_IMAGE_VERIFY",
    "APP_LOGO_CUTOUT", "APP_LOGO_CUTOUT_BEST_EFFORT", "APP_LOGO_CUTOUT_TOLERANCE", "APP_LOGO_CUTOUT_MAX_EDGE",
    "APP_GENERATED_PREVIEW_ENABLED", "APP_GENERATED_PREVIEW_EDGE",
    "APP_IMAGE_WAIT_PARTICLES", "APP_IMAGE_WAIT_PARTICLE_COUNT", "APP_IMAGE_WAIT_CYCLE",
    "IMAGE_FAST_MODE", "IMAGE_SIZE", "IMAGE_PRICE_FAST",
    "IMAGE_MAX_EDGE", "IMAGE_QUALITY", "IMAGE_MAX_PIXELS", "IMAGE_2K_PIXELS",
    "IMGPROG_STAGE1", "IMGPROG_STAGE2", "IMGPROG_STAGE3", "IMGPROG_ETA",
  ],
  context_rules: ["CTX_COMPACT_TOKENS", "CTX_KEEP_MESSAGES", "META_RULE", "CHAT_RULES"],
  membership_cost: [
    "CHAT_PRICE_IN", "CHAT_PRICE_OUT", "CHAT_PRICE_STANDARD_IN", "CHAT_PRICE_STANDARD_OUT",
    "CHAT_PRICE_HIGH_IN", "CHAT_PRICE_HIGH_OUT", "CHAT_PRICE_ULTRA_IN", "CHAT_PRICE_ULTRA_OUT",
    "CHAT_PRO_PRICE_IN", "CHAT_PRO_PRICE_OUT",
    "IMAGE_PRICE", "IMAGE_PRICE_PRO", "IMAGE_PRICE_SMALL", "IMAGE_PRICE_2K",
    "CHAT_CAP_CNY", "CHAT_NOTICE_CNY", "IMAGE_CAP_CNY", "IMAGE_NOTICE_CNY",
    "TIERS_OVERRIDE",
  ],
  security_limits: [
    "CAP_CHAT_ENABLED", "CAP_IMAGE_ENABLED", "CAP_POSTER_ENABLED",
    "RATE_CHAT_PER_HOUR", "RATE_IMAGE_PER_HOUR",
    "SERVICE_START_HOUR", "SERVICE_END_HOUR", "AUTO_APPROVE_HOURS",
    "REVEAL_DELIVERY_PASSWORD",
  ],
  storage_credentials: [
    "CHAT_API_KEY", "IMAGE_API_KEY", "EMBED_API_KEY", "DEEPSEEK_SEARCH_KEY",
    "COS_BUCKET", "COS_REGION",
  ],
  version_compat: ["MIN_APP_VERSION", "LATEST_APP_VERSION", "UPDATE_MESSAGE"],
};

// 反向索引：key → sectionId（未列出的落 version_compat，并标记 advanced）
const KEY_SECTION = {};
for (const [sid, keys] of Object.entries(SECTION_OF)) {
  for (const k of keys) KEY_SECTION[k] = sid;
}

// ── 字段级元数据（未声明的键走按类型推导的默认规则）──
// widget: text | number | toggle | enum | textarea | password | json
const META = {
  // 模型与服务商
  CHAT_PROVIDER: { title: "对话服务商平台", widget: "enum", enum: ["qwen", "deepseek", "doubao", "zhipu", "moonshot", "openai"], risk: "high",
    description: "决定对话请求发往哪家平台。换平台需同时确认端点与三档模型名，改完约 30 秒生效。" },
  CHAT_PROVIDER_BASE: { title: "对话服务商端点", widget: "text", risk: "high",
    description: "留空使用平台预设地址；自定义网关时填完整 baseURL（含 /v1）。" },
  CHAT_THINKING_STYLE: { title: "思考参数风格", widget: "enum", enum: ["ark", "dashscope"], risk: "high",
    description: "不同平台的深度思考参数格式不同：ark 用 thinking.type，dashscope 用 enable_thinking。填错会导致模型忽略思考开关。" },
  IMAGE_PROVIDER: { title: "生图平台", widget: "enum", enum: ["ark", "dashscope"], risk: "high",
    description: "ark=火山方舟（支持参考图），dashscope=阿里百炼。" },
  IMAGE_SIZES: { title: "允许的画布尺寸", widget: "text", risk: "medium",
    description: "逗号分隔的尺寸白名单，供模型选择；留空使用服务端默认。" },

  // 生成与性能
  APP_LOGO_CUTOUT: { title: "Logo 自动去底", widget: "toggle", risk: "medium" },
  APP_LOGO_CUTOUT_BEST_EFFORT: { title: "复杂背景尽力处理", widget: "toggle", risk: "medium" },
  APP_LOGO_CUTOUT_TOLERANCE: { title: "纯色背景容差", widget: "number", min: 8, max: 80, step: 1, risk: "medium" },
  APP_LOGO_CUTOUT_MAX_EDGE: { title: "抠图最大长边", widget: "number", min: 256, max: 2048, step: 1, risk: "low" },
  APP_GENERATED_PREVIEW_ENABLED: { title: "编辑时提供一张生成图预览", widget: "toggle", risk: "medium" },
  APP_GENERATED_PREVIEW_EDGE: { title: "生成图预览长边", widget: "number", min: 256, max: 1024, step: 1, risk: "low" },
  APP_IMAGE_WAIT_PARTICLES: { title: "C版等待粒子", widget: "toggle", risk: "low" },
  APP_IMAGE_WAIT_PARTICLE_COUNT: { title: "等待粒子数量", widget: "number", min: 60, max: 240, step: 10, risk: "low" },
  APP_IMAGE_WAIT_CYCLE: { title: "聚散周期秒数", widget: "number", min: 3, max: 12, step: 0.1, risk: "low" },
  APP_CHAT_TIMEOUT: { title: "对话请求超时", widget: "number", min: 10, max: 600, step: 1, unit: "秒", risk: "high",
    description: "单次对话请求的整体超时。过小会频繁中断，过大会让用户长时间等待。" },
  APP_CHAT_FIRST_TOKEN_TIMEOUT: { title: "首包超时", widget: "number", min: 0, max: 600, step: 1, unit: "秒", risk: "high",
    description: "流式开始后多久没收到首个响应判为超时。生图等工具轮次不受它约束。0 表示使用默认 45 秒。" },
  APP_IMAGE_TIMEOUT: { title: "生图请求超时", widget: "number", min: 10, max: 900, step: 1, unit: "秒", risk: "high",
    description: "单张图生成的最长等待时间。需大于上游实际耗时（通常 40–90 秒）。" },
  APP_STREAM_RETRY: { title: "流式中断自动重试", widget: "number", min: 0, max: 5, step: 1, unit: "次", risk: "medium",
    description: "网络类中断且未收到任何内容时自动重试的次数。0=关闭。" },
  APP_IMAGE_RETRY: { title: "生图失败自动重试", widget: "number", min: 0, max: 5, step: 1, unit: "次", risk: "medium",
    description: "生图失败后的自动重试次数，每次都会产生上游成本。" },
  APP_IMAGE_VERIFY: { title: "生图后视觉验证", widget: "toggle", risk: "medium",
    description: "生成后用视觉模型检查是否满足用户要求，不符则带修正提示重试一次。会增加一次视觉调用成本。" },
  IMAGE_MODEL_FAST: { title: "作图模型 · 快速档", widget: "text", risk: "medium", maxLength: 120,
    description: "普通插画/配图/草稿使用。留空 = 沿用兼容别名。建议填 Seedream 5.0 Flash。" },
  IMAGE_MODEL_SERIES: { title: "作图模型 · 组图档（兼容项，已不参与主链路）", widget: "text", risk: "low", maxLength: 120,
    description: "【已弃用】组图现在由云端编排器拆成 N 个单图子任务执行，每张走快速/高质量档（Flash 或 Pro），不再需要原生组图模型。此项仅保留给旧配置兼容，留空即可，不会关闭组图功能。" },
  IMAGE_ROUTING_MODE: { title: "生图路由模式", widget: "enum", risk: "high",
    enum: ["auto", "flash_only", "pro_only"],
    enumLabels: { auto: "自动（按任务）", flash_only: "全部快速档", pro_only: "全部高质量档" },
    description: "运维止损用。flash_only 可在高质量模型故障时立刻把全站切到快速档；pro_only 用于临时提质量对比。" },
  IMAGE_AUTO_POLICY: { title: "自动作图 · 升级策略 JSON", widget: "json", risk: "medium", maxLength: 6000,
    description: "auto 默认 Flash。可配置 defaultTier、honorClientHigh、proTaskKinds、proReasons、minReferencesForPro、nativeTextCharsForPro、retryQualityToPro、capabilityFallback、fallbackCodes。客户端旧 high 推荐默认不强制升级；超时或不确定结果不会重复生图。" },
  IMAGE_LEGACY_BRAND_POLICY: { title: "旧包 Logo 规划 · 测试账号开关", widget: "json", risk: "medium", maxLength: 6000,
    description: '默认关闭。格式：{"enabled":true,"accountIds":["测试账号内部ID"]}；不支持全量或通配符。只增强已有工具的规划，不更换手机抠图/合成算法，不影响未列入账号。关闭后约30秒停止新请求注入。' },
  IMAGE_FAST_MODE: { title: "生图提速模式", widget: "toggle", risk: "medium",
    description: "开启=fast（更快）；关闭=standard（质量优先）。由 bf-image 实际读取。" },
  IMAGE_SIZE: { title: "生图默认尺寸", widget: "enum", enum: ["1K", "1.5K", "2K"], risk: "high",
    description: "客户端不再传尺寸，统一由这里决定。1.5K 与 1K 同价、画质更好；2K 单价更高。" },
  IMAGE_MAX_EDGE: { title: "参考图压缩长边", widget: "number", min: 256, max: 4096, step: 64, unit: "像素", risk: "low",
    description: "客户端上传参考图前压缩到的最长边，影响画质与流量。" },
  IMAGE_QUALITY: { title: "参考图压缩质量", widget: "number", min: 0.1, max: 1, step: 0.01, unit: "比例", risk: "low",
    description: "JPEG 压缩质量，越高画质越好、文件越大。" },
  IMAGE_MAX_PIXELS: { title: "生图像素预算（常规）", widget: "number", min: 0, max: 20000000, step: 1000, unit: "像素", risk: "medium" },
  IMAGE_2K_PIXELS: { title: "生图像素预算（2K 阈值）", widget: "number", min: 0, max: 40000000, step: 1000, unit: "像素", risk: "medium" },
  IMGPROG_STAGE1: { title: "进度文案 · 阶段1", widget: "text", maxLength: 60, risk: "low", description: "0–15 秒显示。" },
  IMGPROG_STAGE2: { title: "进度文案 · 阶段2", widget: "text", maxLength: 60, risk: "low", description: "15–45 秒显示。" },
  IMGPROG_STAGE3: { title: "进度文案 · 阶段3", widget: "text", maxLength: 60, risk: "low", description: "45 秒后显示。" },
  IMGPROG_ETA: { title: "预计时长提示", widget: "text", maxLength: 60, risk: "low" },

  // 上下文与规则
  CTX_COMPACT_TOKENS: { title: "上下文压缩阈值", widget: "number", min: 0, max: 200000, step: 1000, unit: "token", risk: "high",
    description: "估算 token 超过该值时摘要早期消息。0=关闭压缩。" },
  CTX_KEEP_MESSAGES: { title: "压缩保留最近消息数", widget: "number", min: 0, max: 100, step: 1, unit: "条", risk: "medium" },
  META_RULE: { title: "回答规则 · metaRule", widget: "textarea", maxLength: 20000, risk: "high",
    description: "整段覆盖服务端默认规则。改错会直接影响所有对话，建议先小范围试。" },
  CHAT_RULES: { title: "能力表达铁律", widget: "textarea", maxLength: 20000, risk: "high",
    description: "注入系统提示词的行为约束（身份口径、工具使用、失败兜底）。" },

  // 会员与成本
  CHAT_CAP_CNY: { title: "对话额度池上限", widget: "number", min: 0, max: 1000000, step: 1, unit: "元", risk: "high" },
  CHAT_NOTICE_CNY: { title: "对话余额提醒线", widget: "number", min: 0, max: 1000000, step: 1, unit: "元", risk: "medium" },
  IMAGE_CAP_CNY: { title: "生图额度池上限", widget: "number", min: 0, max: 1000000, step: 1, unit: "元", risk: "high" },
  IMAGE_NOTICE_CNY: { title: "生图余额提醒线", widget: "number", min: 0, max: 1000000, step: 1, unit: "元", risk: "medium" },
  TIERS_OVERRIDE: { title: "档位运营配置（JSON）", widget: "json", risk: "high",
    description: "价格/额度/显示/收款码/功能开关。结构复杂，建议用专门的档位运营页编辑。" },

  // 权限与安全
  CAP_CHAT_ENABLED: { title: "能力开关 · 智能对话", widget: "toggle", risk: "high", description: "关闭后对话接口返回 503。" },
  CAP_IMAGE_ENABLED: { title: "能力开关 · 图片生成", widget: "toggle", risk: "high", description: "关闭后生图接口返回 503。" },
  CAP_POSTER_ENABLED: { title: "能力开关 · 海报生成", widget: "toggle", risk: "high" },
  RATE_CHAT_PER_HOUR: { title: "对话限流（每账号）", widget: "number", min: 0, max: 100000, step: 1, unit: "次/小时", risk: "medium", description: "0=不限。" },
  RATE_IMAGE_PER_HOUR: { title: "生图限流（每账号）", widget: "number", min: 0, max: 100000, step: 1, unit: "张/小时", risk: "medium", description: "0=不限。由 bf-image 原子计数执行。" },
  SERVICE_START_HOUR: { title: "服务开始时间", widget: "number", min: 0, max: 23, step: 1, unit: "时", risk: "medium" },
  SERVICE_END_HOUR: { title: "服务结束时间", widget: "number", min: 0, max: 23, step: 1, unit: "时", risk: "medium" },
  AUTO_APPROVE_HOURS: { title: "超时自动通过", widget: "number", min: 0, max: 720, step: 1, unit: "小时", risk: "medium", description: "0=关闭，全部人工审核。" },

  // 凭证与存储
  CHAT_API_KEY: { title: "对话 API Key", widget: "password", risk: "high" },
  IMAGE_API_KEY: { title: "生图 API Key", widget: "password", risk: "high" },
  EMBED_API_KEY: { title: "向量 API Key", widget: "password", risk: "high" },
  DEEPSEEK_SEARCH_KEY: { title: "搜索服务 Key", widget: "password", risk: "high" },
  COS_BUCKET: { title: "对象存储 Bucket", widget: "text", risk: "high", description: "参考图转存与文件访问使用。" },
  COS_REGION: { title: "对象存储地域", widget: "text", risk: "high" },

  // 版本
  REVEAL_DELIVERY_PASSWORD: { title: "发放存档回显初始密码", widget: "text", risk: "high",
    description: "1=列表里可以查看初始密码（当前流程依赖）；0=列表只显示「已设置」，需要凭据时走重置。置 0 后历史密文仍留在库里，但不再通过接口回显。" },
  MIN_APP_VERSION: { title: "最低可用版本", widget: "text", maxLength: 20, risk: "high", description: "低于该版本的客户端会被提示升级；留空=不限制。" },
  LATEST_APP_VERSION: { title: "最新版本号", widget: "text", maxLength: 20, risk: "low" },
  UPDATE_MESSAGE: { title: "升级提示文案", widget: "textarea", maxLength: 500, risk: "low", description: "可包含下载链接。" },
};

// 价格类统一规则（逐项声明太啰嗦，这里批量补）
for (const k of Object.keys(KEY_SECTION).filter((x) => /PRICE/.test(x))) {
  META[k] = Object.assign({ title: META[k] && META[k].title ? META[k].title : "计价单价 · " + k.toLowerCase(), risk: "high", widget: "number", min: 0, max: 10000, step: 0.01, unit: "元/单位" }, META[k] || {});
}

function sectionOf(key) {
  return KEY_SECTION[key] || "version_compat";
}

function widgetOf(spec, meta) {
  if (meta.widget) return meta.widget;
  if (spec.type === "secret") return "password";
  if (spec.type === "json") return "json";
  if (spec.type === "num") return "number";
  return "text";
}

/** 生效来源：数据库覆盖 > 环境变量 > 代码默认值。 */
function sourceOf(key, dbData) {
  const hasDb = dbData && Object.prototype.hasOwnProperty.call(dbData, key) && dbData[key] !== "" && dbData[key] != null;
  if (hasDb) return "database";
  if (Object.prototype.hasOwnProperty.call(process.env, key) && process.env[key] !== "") return "environment";
  return "builtin";
}

/** 组装前端需要的完整配置描述（不含敏感明文）。 */
function describeSettings(specs, runtime, dbData) {
  return Object.entries(specs).map(([key, spec]) => {
    const meta = META[key] || {};
    const secret = spec.type === "secret";
    const widget = widgetOf(spec, meta);
    return {
      key,
      section: sectionOf(key),
      title: meta.title || spec.label,
      label: spec.label,
      description: meta.description || "",
      type: spec.type,
      widget,
      unit: meta.unit || "",
      enum: meta.enum || null,
      min: meta.min != null ? meta.min : (spec.type === "num" ? 0 : null),
      max: meta.max != null ? meta.max : (spec.type === "num" ? 100000 : null),
      step: meta.step != null ? meta.step : (spec.type === "num" ? 1 : null),
      maxLength: meta.maxLength || (widget === "textarea" ? 20000 : 120),
      risk: meta.risk || "low",
      secret,
      // 密钥只给"是否已配置"与掩码，绝不返回明文
      value: secret ? (runtime[key] ? String(runtime[key]).slice(0, 4) + "****" + String(runtime[key]).slice(-4) : "") : runtime[key],
      configured: secret ? !!runtime[key] : true,
      source: sourceOf(key, dbData),
      builtinDefault: secret ? "" : spec.type === "num" ? Number(spec.def()) : String(spec.def()),
    };
  });
}

/** 保存时的字段级校验。返回 { ok, value } 或 { ok:false, reason }。 */
function validateValue(key, raw, spec, meta) {
  const m = meta || META[key] || {};
  if (spec.type === "secret") {
    const sv = String(raw == null ? "" : raw).trim();
    if (!sv || sv.includes("****")) return { ok: false, skip: true, reason: "未修改" };
    if (sv.length < 16) return { ok: false, reason: `${m.title || spec.label} 长度不正确（应为完整 Key）` };
    return { ok: true, value: sv };
  }
  if (m.widget === "toggle") {
    const s = String(raw).trim().toLowerCase();
    if (["1", "0", "true", "false", "on", "off", ""].includes(s)) {
      const on = ["1", "true", "on"].includes(s);
      return { ok: true, value: on ? "1" : "0" };
    }
    return { ok: false, reason: `${m.title || spec.label} 只能是开启或关闭` };
  }
  if (m.enum && m.enum.length) {
    const s = String(raw).trim();
    if (!m.enum.includes(s)) return { ok: false, reason: `${m.title || spec.label} 必须是：${m.enum.join(" / ")}` };
    return { ok: true, value: s };
  }
  if (spec.type === "num") {
    const n = Number(raw);
    const min = m.min != null ? m.min : 0;
    const max = m.max != null ? m.max : 100000;
    if (!Number.isFinite(n)) return { ok: false, reason: `${m.title || spec.label} 必须是数字` };
    if (n < min || n > max) return { ok: false, reason: `${m.title || spec.label} 必须在 ${min}~${max} 之间` };
    return { ok: true, value: n };
  }
  if (spec.type === "json") {
    const sv = typeof raw === "string" ? raw.trim() : JSON.stringify(raw || {});
    if (!sv) return { ok: false, reason: `${m.title || spec.label} 不能为空` };
    if (sv.length > 20000) return { ok: false, reason: `${m.title || spec.label} 内容过大` };
    let parsed;
    try { parsed = JSON.parse(sv); } catch { return { ok: false, reason: `${m.title || spec.label} 不是合法 JSON` }; }
    if (typeof parsed !== "object" || Array.isArray(parsed)) return { ok: false, reason: `${m.title || spec.label} 必须是 JSON 对象` };
    return { ok: true, value: sv };
  }
  // 普通字符串 / 长文本
  const sv = String(raw == null ? "" : raw).trim();
  const limit = m.maxLength || (m.widget === "textarea" ? 20000 : 120);
  if (sv.length > limit) return { ok: false, reason: `${m.title || spec.label} 不能超过 ${limit} 个字符` };
  return { ok: true, value: sv };
}

module.exports = {
  SECTIONS,
  SECTION_OF,
  META,
  sectionOf,
  widgetOf,
  sourceOf,
  describeSettings,
  validateValue,
};
