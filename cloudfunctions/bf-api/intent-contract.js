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
function wantsAllAttachments(request,count) {
  // “仅用已有素材” limits provenance, while “仅用第二张” limits selection.
  const text = String(request || '').replace(/(?:仅用|只用)(?:我(?:发的|上传的)?|本轮|已有|已给|现有|提供的|上传的)(?:的)?(?:素材|附件|产品图|图片)/g,'');
  const explicitAll = /都用上|全部使用|全部用上|每张都|(?:原件|产品图|照片|素材)(?:全都|都|全部)(?:放进|放上|用上)|所有产品图|所有附件|全部产品图/.test(text);
  const numberedPhotos = /(?:用|使用|选用)这?\s*\d+\s*张(?:产品图|图片|照片)/.test(text);
  const includeSet = numberedPhotos && /(?:全部|全都)(?:放进|放上)/.test(text);
  const together=/(?:把|用)这(几|[一二三四五六七八九十]|\d+)张(?:产品图|图片|照片|图)(?:一起)?(?:做|制作|生成|合成|排成)/.exec(text)?.[1];
  const requestedCount=together&&(Number(together)||"一二三四五六七八九十".indexOf(together)+1);
  return (explicitAll || includeSet || together==="几" || requestedCount===count)
    && !/只用|仅用|不要用|别用|不使用|不要全|别全|不用全|不必全|不需要全/.test(text);
}

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
  const users = messages.filter(m => m?.role === "user" && !require("./shared/image-delivery").isHistoryPreview(m));
  const recent = users.slice(-3).map(textOf);
  const latest = recent[recent.length - 1] || "";
  const memoryText = memories.filter(t => typeof t === "string" && t).join("\n");

  // Keep direction and ratio from compatible turns. A newer change of
  // direction invalidates an older incompatible ratio, including memory.
  let ratio = null, orientation = null;
  for (const raw of [latest, ...recent.slice(0,-1).reverse(), memoryText]) {
    const src = normalizeDirection(raw);
    const portrait = ORIENT.portrait.test(src), landscape = ORIENT.landscape.test(src);
    const direction = portrait !== landscape ? (portrait ? "portrait" : "landscape") : null;
    const explicitRatio = ratioValue(raw);
    const parsed = explicitRatio && ratioValue(require("./shared/poster-reformat").ratioOf(src));
    if (!orientation) {
      orientation = parsed ? (parsed.value === 1 ? null : parsed.value > 1 ? "landscape" : "portrait") : direction;
    }
    if (parsed && (!orientation || (orientation === "portrait" ? parsed.value < 1 : parsed.value > 1))) {
      ratio = parsed;
      break;
    }
    if (direction && direction !== orientation) break;
  }
  const orientSource = orientation ? "explicit" : "", ratioSource = ratio ? "explicit" : "";

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
    userText: require("./shared/verbatim-image-prompt").authoredText(messages),
    verbatim: require("./shared/verbatim-image-prompt").fromMessages(messages),
    currentImageCount: (() => {
      const user = [...messages].reverse().find(m => m?.role === 'user' && !require('./shared/image-delivery').isHistoryPreview(m));
      if (!Array.isArray(user?.content)) return 0;
      const previews = require('./reference-text').currentImageParts(messages).length;
      if (!previews) return 0;
      // The iPad packs large sets into preview sheets but keeps original slot numbers.
      const catalog = user.content.filter(part => part?.type === 'text')
        .map(part => /(?:^|\n\n)【本轮附件图册】共有 (\d{1,3}) 张独立图片。REF 番号就是原附件序号；上面只是规划用预览。/u.exec(part.text))
        .find(Boolean);
      return catalog && Number(catalog[1]) > 6 && Number(catalog[1]) <= 16 ? Number(catalog[1]) : previews;
    })(),
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
    return posterDelivery.copyOf(args.structured);
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

    let changed = null;
    const count = intent.currentImageCount;
    // The iPad converts large selections into sheets; the server owns the choice.
    const allAttachments = wantsAllAttachments(intent.userText,count);
    if (fn.name === 'image_generate' && count > 0) {
      args.use_entire_catalog = allAttachments;
      const lastLogo = count > 6 && count <= 16 && allAttachments && !intent.verbatim &&
        /最后(?:一张|那张)(?:图|图片)?(?:是|作为|用作|的)?\s*(?:logo|标识|标志)|最后的\s*logo|logo\s*(?:用|选|是)\s*最后(?:一张|那张)/iu.test(intent.userText) &&
        !/(?:不用|不要|不加|取消|删除).{0,10}(?:logo|标识|标志)/iu.test(intent.userText);
      args.print_catalog_originals = count > 6 && allAttachments && !intent.verbatim
        && !args.structured?.preserve_assets?.length && !args.structured?.image_references
        && !args.structured?.poster_reformat && args.text_mode !== 'overlay'
        && !['both','last'].includes(args.source) && /海报|图册|宣传图/u.test(intent.userText)
        && (lastLogo || /(?:型号|产品编号|货号|每件产品|产品原图|产品原件|原件.{0,16}(?:别改|不变|保留))/u.test(intent.userText))
        && !/重画产品|重新设计产品|重绘产品|不要原图|不用原图/u.test(intent.userText);
      if (args.print_catalog_originals) {
        args.structured = {...args.structured, catalog_attachment_count: count};
        if (lastLogo) {
          args.structured.catalog_logo_slot = count;
          // The frozen client packs all attachments without these hints. An
          // inferred role on the first six can steal the user's explicit slot.
          args.source = 'attached';
          delete args.source_index;
          delete args.source_indexes;
          delete args.reference_roles;
        }
      }
      changed = {catalogSelection: allAttachments};
    }
    if (fn.name === 'image_generate' && [undefined,'auto','none','attached'].includes(args.source) && count >= 2
        && !args.library_refs?.length && !args.structured?.image_references
        && !args.structured?.preserve_assets?.length && !args.structured?.poster_reformat && allAttachments) {
      const plan = args.structured?.image_plan;
      const oldIndices = args.source_indexes || [args.source_index || 1];
      const protectedRefs = plan?.protected_references || [];
      if (count <= 6 && protectedRefs.every(ref => oldIndices[ref.index - 1] >= 1 && oldIndices[ref.index - 1] <= count)) {
        const roles = new Map(oldIndices.map((index, slot) => [index, args.reference_roles?.[slot]]));
        args.source = 'attached';
        args.source_indexes = Array.from({length: count}, (_,slot) => slot + 1);
        delete args.source_index;
        args.reference_roles = args.source_indexes.map(index => roles.get(index) || ('本轮素材' + index));
        if (plan) {
          plan.reference_count = count;
          plan.protected_references = protectedRefs.map(ref => ({...ref,index:oldIndices[ref.index - 1]}));
        }
        changed = {completeCurrentReferences:count};
      } else if (count > 6 && count <= 16 && !plan && !intent.verbatim) {
        // The installed app reconstructs the full selection from its ordered sheets.
        // Compatible hints can still let it upload a separate Logo original.
        const pairs = args.print_catalog_originals && Array.isArray(args.source_indexes)
          ? args.source_indexes.map((index, slot) => [index, args.reference_roles?.[slot]]).filter(([index]) => index >= 1 && index <= 6)
          : [];
        args.source = 'attached';
        delete args.source_index;
        delete args.source_indexes;
        delete args.reference_roles;
        if (pairs.length) {
          args.source_indexes = pairs.map(([index]) => index);
          if (pairs.every(([,role]) => role)) args.reference_roles = pairs.map(([,role]) => role);
        }
      }
    }
    // Binding happens after membership/reference finalization, using only this user turn.
    if (intent.verbatim && fn.name !== 'image_series') {
      const { image_references, preserve_assets, preserve_outside, routing } = args.structured || {};
      args.structured = { verbatim_prompt: intent.verbatim, routing, image_references, preserve_assets, preserve_outside };
      // The planner may invent a protection/layout plan even for a verbatim brief.
      // Keep source authorization and binding, without rerouting its numbered images.
      // Older iPads may add catalogue text to prompt. The structured original survives the round trip.
      args.prompt = intent.verbatim.length <= 1400 ? intent.verbatim : '使用本轮用户提供的完整作图提示词。';
      delete args.text_mode;
      const ratio = ratioValue(intent.verbatim);
      if (ratio) args.aspect_ratio = ratio.label;
      else delete args.aspect_ratio;
      touched.push({tool: fn.name, verbatim: true});
      return { ...call, function: { ...fn, arguments: JSON.stringify(args) } };
    }
    const referenceText = require('./reference-text');
    const originalIndex = args.source === 'attached' && referenceText.restylesReference(intent.userText)
      ? referenceText.sourceImageIndex(intent.userText, count) : null;
    const referenceRedesign = Boolean(originalIndex);
    if (originalIndex && count > 1) {
      const selected = args.source_indexes || [args.source_index || 1];
      const roles = new Map(selected.map((index, slot) => [index, args.reference_roles?.[slot]]));
      args.source_indexes = [originalIndex, ...selected.filter(index => index !== originalIndex)];
      args.reference_roles = args.source_indexes.map(index => index === originalIndex ? '原海报' : roles.get(index) || '用户提供的参考图');
      delete args.source_index;
      changed = { ...changed, originalReference: originalIndex };
    }
    const referenceDesign=referenceRedesign&&(refLines?.length>=2||posterDelivery.copyOf(args.structured).length>=2);
    const nativePoster = fn.name === 'image_generate' && posterDelivery.nativePoster(args, intent.userText,{referenceDesign});
    const poster = nativePoster || wantsPosterLayout(args, blocksOf(args), intent);
    let blocks = nativePoster ? posterDelivery.copyOf(args.structured) : blocksOf(args);
    if(nativePoster && referenceRedesign && refLines?.length){
      blocks=require('./reference-text').keepSourceLines(blocks,refLines);
    }
    if (nativePoster && !blocks.some(row => typeof row?.text === 'string' && row.text.trim())) {
      throw Object.assign(Error('TOOL_ARGUMENTS_INVALID'), { code: 'TOOL_ARGUMENTS_INVALID', reason: 'TEXT_ARRAY_INVALID', field: 'structured.text' });
    }
    if (observe) observe({ tag: "intent_apply_entry", tool: fn.name, hasIntent: !!intent, hasAny: !!(intent && intent.hasAny), promptChars: args.prompt ? String(args.prompt).length : 0, blocks: blocks ? blocks.length : 0, structuredKeys: args.structured && typeof args.structured === "object" ? Object.keys(args.structured).join(",") : "" });
    if (nativePoster) {
      args.structured = posterDelivery.mark({ ...args.structured, text: blocks }, intent.userText,{referenceRedesign,compactBrief:posterDelivery.compactBriefFor(args,intent,referenceRedesign)});
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

    if (fn.name === 'image_edit') {
      const requestedAspect = require('./shared/poster-reformat').ratioOf(normalizeDirection(intent.userText));
      if (requestedAspect) args.aspect_ratio = requestedAspect;
      else delete args.aspect_ratio; // the transport supplies the real source dimensions
      changed = { ...changed, editCanvas: requestedAspect || 'source' };
    }

    const originalCanvas=intent.roles?.poster?.size;
    if(referenceRedesign && originalCanvas
        && !ratioValue(intent.userText)
        && !ORIENT.portrait.test(normalizeDirection(intent.userText))
        && !ORIENT.landscape.test(normalizeDirection(intent.userText))){
      args.aspect_ratio=originalCanvas.w+":"+originalCanvas.h;
      changed={...changed,canvas:{to:args.aspect_ratio,why:"仅改整图风格，保留原画布比例"}};
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
    "【prompt 只写画面】用简短自然语言说明本轮主体、场景、视觉表现和必要约束。定稿文案单独填写，不重复贴进 prompt。",
    "【长文】用栏目和自然句组织完整信息，显式全文要求保留原文。资料不足时只写确认内容，背景和图解承担视觉信息。",
    "【直接执行】以上是执行约束，不要在回复里复述或列计划，直接调用工具。",
  ].filter(Boolean).join("\n");
}

module.exports = { resolve, apply, guidance, fallbackRatio, ratioValue, normalizeDirection, cleanPlaceholders, CONTACT };
