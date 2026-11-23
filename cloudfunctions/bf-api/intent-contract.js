"use strict";
const posterDelivery = require('./shared/poster-delivery');

/**
 * 前置意图契约（Intent Contract）
 *
 * 解决的问题：模型每一轮都要重新猜「横版还是竖版、要不要重绘、必须带什么」，
 * 于是同一个需求能出 0.845 / 0.75 / 4.1:1 三种比例。
 *
 * 做法：在生图参数定稿（finalizeImageCalls）之前，把
 *   ① 用户本轮原话 ② 最近几轮对话 ③ 长期记忆
 * 里的硬约束抽出来，做两件事：
 *   - 返回一段极短的 system 提示，让模型自己就按这个计划（不是写死画面）
 *   - 对模型给出的 tool_calls 做**确定性校正**（比例冲突才改，不冲突不动）
 *
 * 原则：只校正「用户明确说过」或「记忆里明确写过」的项；没有依据一律不动。
 * 不编造文案、不编造号码、不改 prompt 的创作内容。
 */

const ORIENT = {
  portrait: /竖版|竖向|竖屏|竖图|立式|纵向/,
  landscape: /横版|横向|横屏|横图|横幅|宽幅/,
};
const RATIO = /(\d{1,2}(?:\.\d+)?)\s*[:：]\s*(\d{1,2}(?:\.\d+)?)/g;
// 400/800 热线、固话、手机号；只认用户或记忆里真正出现过的
const CONTACT = /(?:400|800)[-\s]?\d{3,4}[-\s]?\d{3,4}|0\d{2,3}[-\s]?\d{7,8}|1[3-9]\d{9}/;

/** 把「不要横版」这类否定说法先规范化，避免竖/横互相抵消 */
function normalizeDirection(src) {
  return String(src || "").replace(
    /(?:不要|别|不是|拒绝|无需|不用)[^，。；\n]{0,4}?(横版|横向|横屏|横图|竖版|竖向|竖屏|竖图)/g,
    (m, kw) => (/^横/.test(kw) ? "竖版" : "横版")
  );
}

function textOf(message) {
  const c = message && message.content;
  if (typeof c === "string") return c;
  if (Array.isArray(c)) return c.filter(p => p && p.type === "text").map(p => p.text || "").join("\n");
  return "";
}

function ratioValue(text) {
  RATIO.lastIndex = 0;
  const m = RATIO.exec(String(text || ""));
  if (!m) return null;
  const a = Number(m[1]), b = Number(m[2]);
  if (!(a > 0 && b > 0)) return null;
  const v = a / b;
  return v >= 0.25 && v <= 4 ? { label: `${m[1]}:${m[2]}`, value: v } : null;
}

/**
 * 解析意图。
 * @param {{messages:Array, memories:Array<string>}} input
 */
function resolve({ messages = [], memories = [] } = {}) {
  const users = messages.filter(m => m && m.role === "user");
  const recent = users.slice(-3).map(textOf).filter(Boolean);
  const latest = recent[recent.length - 1] || "";
  const memoryText = memories.filter(t => typeof t === "string" && t).join("\n");

  // 比例：本轮原话 > 最近几轮 > 记忆（越新的越优先）
  let ratio = null, ratioSource = "";
  for (const src of [latest, ...recent.slice(0, -1).reverse(), memoryText]) {
    const r = ratioValue(src);
    if (r) { ratio = r; ratioSource = "explicit"; break; }
  }

  // 方向：同上，取最新一次明确表述
  let orientation = null, orientSource = "";
  for (const raw of [latest, ...recent.slice(0, -1).reverse(), memoryText]) {
    const src = normalizeDirection(raw);
    const p = ORIENT.portrait.test(src), l = ORIENT.landscape.test(src);
    if (p && !l) { orientation = "portrait"; orientSource = "explicit"; break; }
    if (l && !p) { orientation = "landscape"; orientSource = "explicit"; break; }
  }
  if (!orientation && ratio) orientation = ratio.value >= 1 ? "landscape" : "portrait";

  // 联系方式：优先本轮给过的，其次近几轮，最后记忆
  let contact = "";
  for (const src of [latest, ...recent.slice(0, -1).reverse(), memoryText]) {
    const m = CONTACT.exec(src);
    if (m) { contact = m[0].replace(/\s+/g, ""); break; }
  }

  // 公司全称：从记忆里取最长的「…有限公司」，没有就留空（不编造）
  let company = "";
  const names = memoryText.match(/[\u4e00-\u9fa5（）()·]{2,30}有限公司/g) || [];
  if (names.length) company = names.sort((a, b) => b.length - a.length)[0];

  // 任务性质：重绘/重新设计 vs 只加元素
  const redesign = /重(?:新)?(?:设)?计|重绘|重做|再设计|改版|美化|提升美观|重新生成一版|做成海报|做一张海报/.test(latest);
  const additive = /只(?:要|需)?(?:加|贴|放)|基础(?:之)?上(?:直接)?(?:加|增)|不改(?:动)?(?:原|底)图|保持原图/.test(latest);

  return {
    orientation, orientSource, ratio, ratioSource, contact, company,
    redesign, additive,
    // 用户本轮原话：判断「是不是海报任务」时以用户说法为准，
    // 不依赖模型自己在 tool 参数里填 render_intent（实测它经常不填）。
    userText: latest,
    hasAny: !!(orientation || contact || company),
  };
}

/** 按文字量给一个与方向相符的默认比例（只在模型给的比例与方向冲突时使用） */
function fallbackRatio(intent, blocks) {
  const chars = Array.isArray(blocks)
    ? blocks.reduce((n, b) => n + String((b && b.text) || "").replace(/\s/g, "").length, 0)
    : 0;
  if (intent.orientation === "landscape") return chars > 600 ? "16:9" : "4:3";
  if (chars > 600) return "9:16";
  if (chars > 260) return "3:4";
  return "4:5";
}

const PLACEHOLDER = /^(?:品牌名称|公司名称|公司名字|待补充|待填写|XXX+|×+|logo|Logo|LOGO|示例|示例文字|您好)$/;

/** 占位文字处理：有公司名就替换，没有就删掉这条，避免"品牌名称"印在成品上 */
function cleanPlaceholders(blocks, company) {
  if (!Array.isArray(blocks)) return { blocks, changed: false };
  let changed = false;
  const out = [];
  for (const b of blocks) {
    const raw = String((b && b.text) || "").trim();
    if (!raw) { out.push(b); continue; }
    const isCompanySlot = /^(?:品牌名称|公司名称|公司名字)$/.test(raw);
    const isPlaceholder = PLACEHOLDER.test(raw) || /待补充|待填写|品牌名称|公司名称/.test(raw);
    if (isCompanySlot) {
      changed = true;
      if (company) out.push({ ...b, text: company });   // 有全称就写实
      continue;                                          // 没有就删掉这条占位
    }
    if (isPlaceholder) { changed = true; continue; }     // 其他占位（待补充/XXX/您好）一律删掉
    out.push(b);
  }
  return { blocks: out, changed };
}

/**
 * 是否是「海报 / 宣传物料」类请求。
 * 只有这类才需要按版式组织文案；普通配图（画一只猫、一张插画、换背景）
 * 必须原样把 prompt 交给模型，不能追加任何海报约束。
 */
function wantsPosterLayout(args, blocks, intent) {
  const ri = String(args.render_intent || "").toLowerCase();
  if (["poster", "advertisement", "banner", "flyer", "promo", "campaign"].includes(ri)) return true;
  const tm = String(args.text_mode || "").toLowerCase();
  if (tm === "overlay") return true;
  // 有结构化文案（3 条以上）通常是海报/价目表/宣传物料
  // 有 2 条以上文案，基本就是「海报/价目表/宣传物料」而非普通配图
  if (Array.isArray(blocks) && blocks.length >= 2) return true;
  // blocks 只认 text 数组；模型常用 labels/bodies、products、items 这些形态，
  // 这时 blocks 是 null，判定会漏，画布也就不会被规范化（实测出过 2:3）。
  const st = args.structured;
  if (st && typeof st === "object") {
    const counts = ["labels", "bodies", "products", "items", "text"].map(k => (Array.isArray(st[k]) ? st[k].filter(Boolean).length : 0));
    if (Math.max(...counts) >= 2) return true;
  }
  // 以用户原话为准：模型经常不填 render_intent，只看 tool 参数会漏判，
  // 结果海报走了普通配图路径、画面上的字全靠模型猜。
  const userText = String((intent && intent.userText) || "");
  const p = String(args.prompt || "");
  if (/海报|宣传|展架|易拉宝|物料|门店贴|促销|广告图|朋友圈图|banner|poster|flyer/i.test(userText + " " + p)) return true;
  // 2026-11-22：只在最后一句找关键词会漏判——用户上一轮说「按这个做吧」，
  // 关键词全在前面的对话里，结果契约没追加，标题和规格被模型自由发挥。
  // 账号记忆中的公司名或电话不代表每轮配图都是商业物料。
  if ((p.match(/[¥￥]\s*\d+/g) || []).length >= 2) return true;
  return false;
}

function blocksOf(args) {
  const t = args && args.structured && args.structured.text;
  if (Array.isArray(t)) return t;
  // 实测：模型经常把全部文案写成「多行字符串」而不是对象数组。
  // 旧实现只认数组，字符串一律当空，导致文案被兜底逻辑吃掉，只剩公司名和电话。
  if (typeof t === "string" && t.trim()) {
    try { return require("./prompt-contract").parseTextString(t); } catch { return null; }
  }
  return null;
}

function hasContact(blocks, contact) {
  if (!Array.isArray(blocks) || !contact) return false;
  const digits = contact.replace(/\D/g, "");
  return blocks.some(b => String((b && b.text) || "").replace(/\D/g, "").includes(digits));
}

/**
 * 对生图 tool_calls 做确定性校正。
 * @param {Array} calls
 * @param {ReturnType<resolve>} intent
 * @param {(fields:object)=>void} [observe]
 */
function apply(calls, intent, observe) {
  const refLines = Array.isArray(intent && intent.referenceLines) ? intent.referenceLines : null;
  const repair = refLines ? require("./reference-text").repairTerms : null;
  if (!Array.isArray(calls) || !intent) return calls;
  const touched = [];
  const out = calls.map(call => {
    const fn = call && call.function;
    // image_series 也要走契约：实测模型会用组图接口出单张海报，
    // 只放行 generate/edit 时它的提示词完全不被改写（2026-11-23 真实客户复现）。
    if (!fn || !["image_generate", "image_edit", "image_series"].includes(fn.name)) {
      // 诊断（2026-11-23）：真实客户复现时契约没生效，需要知道是「工具名不匹配」
      // 还是「判定不通过」还是「JSON 解析失败」。日志只记状态，不含用户文案。
      if (observe) observe({ tag: "intent_apply_skip", reason: "tool_name", tool: (fn && fn.name) || "?", tools: calls.map(c => c && c.function && c.function.name).join(",") });
      return call;
    }
    let args;
    try { args = JSON.parse(fn.arguments); }
    catch (e) {
      if (observe) observe({ tag: "intent_apply_skip", reason: "json_parse", tool: fn.name, argType: typeof fn.arguments });
      return call;
    }

    const nativePoster = fn.name === 'image_generate' && posterDelivery.nativePoster(args, intent.userText);
    const poster = nativePoster || wantsPosterLayout(args, blocksOf(args), intent);
    let blocks = nativePoster ? posterDelivery.copyOf(args.structured) : blocksOf(args);
    if (nativePoster && !blocks.some(row => typeof row?.text === 'string' && row.text.trim())) {
      throw Object.assign(Error('TOOL_ARGUMENTS_INVALID'), { code: 'TOOL_ARGUMENTS_INVALID', reason: 'TEXT_ARRAY_INVALID', field: 'structured.text' });
    }
    if (observe) observe({ tag: "intent_apply_entry", tool: fn.name, hasIntent: !!intent, hasAny: !!(intent && intent.hasAny), promptChars: args.prompt ? String(args.prompt).length : 0, blocks: blocks ? blocks.length : 0, structuredKeys: args.structured && typeof args.structured === "object" ? Object.keys(args.structured).join(",") : "" });
    let changed = null;
    if (nativePoster) {
      args.structured = posterDelivery.mark({ ...args.structured, text: blocks }, intent.userText);
      changed = { posterDelivery: true, copyRows: blocks.length };
    }
    // 字符串形态的文案解析成数组后写回，下游（文字层 / 排版）只认数组
    if (blocks && blocks.length && typeof (args.structured && args.structured.text) === "string") {
      args.structured = { ...(args.structured || {}), text: blocks };
      changed = changed || {};
      changed.copyParsed = { count: blocks.length };
    }
    // 兜底：模型漏了 structured.text 时，至少把已知的公司与电话补上，
    // 否则 prompt 里一条文字都没有，画面文字只能由生成模型瞎猜。
    if (poster && (!blocks || !blocks.length) && intent.enforceSpec) {
      const seed = [];
      if (intent.enforceSpec.company) seed.push({ key: "company_name", role: "footer", text: String(intent.enforceSpec.company) });
      if (intent.enforceSpec.contact) seed.push({ key: "contact_hotline", role: "contact", text: `全国服务热线 ${intent.enforceSpec.contact}` });
      if (seed.length) {
        args.structured = { ...(args.structured || {}), text: seed };
        blocks = seed;
        changed = changed || {};
        changed.copyBackfill = { added: seed.length };
      }
      if (typeof observe === "function") {
        try { observe({ tag: "image_call_without_structured_text", backfilled: seed.length }); } catch { /* ignore */ }
      }
    }
    // 交付要求硬校验：占位/重复/必需字段
    if (poster && blocks && intent.enforceSpec) {
      const r = require("./requirement-guard").enforce(blocks, intent.enforceSpec);
      if (r.issues.length) {
        args.structured = { ...(args.structured || {}), text: r.blocks };
        blocks = r.blocks;
        changed = changed || {};
        changed.enforced = { issues: r.issues };
      }
    }

    // ① 比例：只有「方向明显冲突」或「用户明确给了比例但模型没用」才改
    const current = ratioValue(String(args.aspect_ratio || ""));
    const explicit = intent.ratio;
    const wrongDirection = intent.orientation && current &&
      ((intent.orientation === "portrait" && current.value > 1) ||
       (intent.orientation === "landscape" && current.value < 1));
    const missing = !current && (intent.orientation || explicit);
    if (explicit && (!current || Math.abs(current.value - explicit.value) / explicit.value > 0.08)) {
      args.aspect_ratio = explicit.label;
      changed = changed || {};
      changed.aspect_ratio = { from: current ? current.label : "(未给)", to: explicit.label, why: "用户明确指定" };
    } else if (wrongDirection || missing) {
      const to = fallbackRatio(intent, blocks);
      args.aspect_ratio = to;
      changed = changed || {};
      changed.aspect_ratio = { from: current ? current.label : "(未给)", to, why: wrongDirection ? "方向与要求相反" : "未给比例" };
    }

    // ①.8 海报画布规范化（2026-11-22）
    // 模型会自己挑比例：同一段烘焙需求出过 2:3、4:5、3:4 三种。客户端按请求比例做几何校验，
    // 一不一致就判「画布比例与要求不同」并把整张图丢掉——用户白等 40 秒还看不到图。
    // 用户没明确要求比例时，海报统一锁 3:4（门店海报通行比例），减少这类误杀。
    if (!nativePoster && !explicit && !intent.orientation && wantsPosterLayout(args, blocks, intent)) {
      const cur = ratioValue(String(args.aspect_ratio || ""));
      if (!cur || Math.abs(cur.value - 0.75) / 0.75 > 0.02) {
        args.aspect_ratio = "3:4";
        changed = changed || {};
        changed.canvas = { from: cur ? cur.label : "(未给)", to: "3:4", why: "海报画布规范化" };
      }
    }

    // ①.5 术语校正：模型把逐字稿里的词写歪了，就改回逐字稿的写法
    if (blocks && repair) {
      let touchedTerm = false;
      args.structured = { ...(args.structured || {}), text: blocks.map(b => {
        const r = repair(String((b && b.text) || ""), refLines);
        if (r.fixed.length) { touchedTerm = true; return { ...b, text: r.text }; }
        return b;
      }) };
      if (touchedTerm) { changed = changed || {}; changed.terms = { repaired: true }; }
    }

    // ② 占位文字：有公司名就写实，没有就删掉
    if (blocks) {
      const r = cleanPlaceholders(blocks, intent.company);
      if (r.changed) {
        args.structured = { ...(args.structured || {}), text: r.blocks };
        changed = changed || {};
        changed.placeholder = { company: intent.company || "(已删除)" };
      }
    }

    // ③ 联系方式：用户/记忆给过、而模型漏了，就补一条（不改其他文案）
    if (poster && intent.contact && blocks && !hasContact(blocks, intent.contact)) {
      blocks.push({ key: "contact_hotline", role: "contact", text: `全国服务热线 ${intent.contact}` });
      changed = changed || {};
      changed.contact = { added: intent.contact };
    }

    // 提示词契约：按官方指南补「用途 / 参考图角色 / 版式关系 / 引号文字」，版式仍由模型自己排
    // 只对「海报/宣传物料」类请求追加排版契约。
    // 旧实现在有任何 prompt 时都追加，会把「画一只猫」改成商业海报并塞进一堆
    // 版式与文字要求，严重破坏普通配图——上线前必须按意图分流。
    if (observe && args.prompt) observe({ tag: "intent_apply_decision", tool: fn.name, want: wantsPosterLayout(args, blocks, intent) });
    if (!nativePoster && args.prompt && wantsPosterLayout(args, blocks, intent)) {
      // fail-open：排版契约只是锦上添花，任何异常都不能让整条回复流中断
      //（历史事故：一个未定义的函数就让客户端看到「输出尚未完成」）。
      try {
        args.prompt = require("./prompt-contract").augment(args.prompt, {
          roles: intent.roles,
          aspectRatio: args.aspect_ratio,
          texts: (blocks || []).map(b => String((b && b.text) || "")).filter(Boolean),
          blocks: blocks || [],
          structured: args.structured,
          company: intent.enforceSpec && intent.enforceSpec.company,
          contact: intent.enforceSpec && intent.enforceSpec.contact,
        });
        changed = changed || {};
        changed.promptContract = { augmented: true, chars: args.prompt.length };
      } catch (e) {
        if (typeof observe === "function") {
          try { observe({ tag: "prompt_contract_failed", code: String((e && (e.code || e.message)) || "UNKNOWN").slice(0, 120) }); } catch { /* ignore */ }
        }
      }
    }
    if (!changed) return call;
    touched.push({ tool: fn.name, ...changed });
    return { ...call, function: { ...fn, arguments: JSON.stringify(args) } };
  });

  if (touched.length && typeof observe === "function") {
    try { observe({ tag: "intent_contract_applied", changes: touched }); } catch { /* ignore */ }
  }
  return touched.length ? out : calls;
}

/** 给模型的一段极短计划提示（不进入画面文案） */
function guidance(intent) {
  if (!intent) return "";
  const newPoster = posterDelivery.nativePoster({}, intent.userText);
  const parts = [];
  if (intent.orientation === "portrait") parts.push("版式必须是竖版（高大于宽）");
  if (intent.orientation === "landscape") parts.push("版式必须是横版（宽大于高）");
  if (intent.ratio) parts.push(`画布比例用 ${intent.ratio.label}`);
  if (intent.contact) parts.push(`必须原样印出全国服务热线 ${intent.contact}`);
  if (intent.company) parts.push(`公司全称是「${intent.company}」`);
  if (!parts.length && !newPoster) return "";
  return [
    parts.length && `【本轮硬约束】${parts.join("；")}。这些是从用户历史里确认过的要求，不是让你重写画面内容。`,
    "【照抄规则】参考图里已有的栏目名、接口名、型号、参数必须逐字照抄，不得换成近义术语（例如 PGM 接口不能写成 PWM/PoE，多防区接口不能写成多协议接口）；拿不准就保留原图文字。",
    "【禁占位】画面不得出现「品牌名称」「公司名称」「待补充」「XXX」「您好」这类占位或示例文字；已知信息直接写实，未知信息就留空不写字。",
    "【structured.text 要写全】新海报默认高信息密度。按已确认资料写全标题、分区标题、完整说明和联系信息，按阅读顺序逐项放入 structured.text。用户指定极简、少字或逐字全文时直接遵循。价格、日期、型号、联系方式只用已有依据。",
    "【prompt 只写画面】prompt 只描述主体、场景、材质、光线、气质，≤180 字；不要把文案抄进 prompt，也不要写 1./2./3. 版式清单或坐标。",
    "【长文】用栏目和自然句组织完整信息，显式全文要求保留原文。资料不足时只写确认内容，背景和图解承担视觉信息。",
    "【风格贴合场景】按行业定视觉基调，并配上该行业的内容型元素：食品烘焙用暖色食欲感，配产品特写缩略图与原料/工艺插画；医疗用干净克制，配诊室实景与设备示意；教育培训用明亮亲和，配课堂场景与进阶路径图；工程安防用专业冷静，配城市剪影、设备特写与系统联动示意。不要所有行业都套同一种深色科技风，也不要只有配色没有元素。",
    "【画面要有元素】不能是纯色底+文字块：用色带或圆角卡片分区、图标、场景缩略图、大数字、示意图承载信息，元素必须来自内容本身（烘焙用食材与工艺，安防用设备与联动节点，医疗用诊室与设备）。只挑用得上的，不要全堆。",
    "【直接执行】以上是执行约束，不要在回复里复述或列计划，直接调用工具。",
  ].filter(Boolean).join("\n");
}

module.exports = { resolve, apply, guidance, fallbackRatio, ratioValue, normalizeDirection, cleanPlaceholders, CONTACT };
