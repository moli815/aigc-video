"use strict";

// Server-owned planning for phones already in customers' hands.
// Never manufacture tool capabilities, asset IDs, image bytes or a new protocol.
const VERSION = "LEGACY_BRAND_PLANNING_V1";
const RULE = `【${VERSION}·已安装客户端素材合成】
目标是保留用户喜欢的原海报，为原Logo找到不遮挡内容的位置，而不是重新画一个相似Logo。
同一张海报的一次编辑只调用一次image_edit；多个Logo放在同一个preserve_assets数组中，不另生成Logo图片、不同时提交两个编辑方案。
先读本轮实际图片和已有预览，区分底图、Logo、人物和风格参考；只使用本轮真实附件序号或检索返回的原件ID。底图在references首位；不要根据用户编号猜发送槽位。不能只发底图而漏掉人物或产品素材。
已生成海报+一张上传Logo：用image_edit、source=both、source_index=上传Logo序号；不能同时传source_indexes或reference_roles。structured.preserve_assets的reference_index=2、kind=logo、background=auto。保留旧文字时structured.text=[]、preserve_outside=true，避免再次叠字。这里Logo由手机保留原素材并合成，底图模型不收到Logo是正常的，不能宣称它已重绘Logo。
两张上传图互合成人物/产品时，用source=attached、source_indexes=[底图序号,素材序号,...]及等长reference_roles。仅选用户需要的素材，不能把所有历史图片无差别送入。精确Logo替换在旧包有额外本地校验：source=attached的双附件不能冒充both（both会改用上次生成图）；先用已开放的recall_history找出两张真实原件，library_refs=[底图ID,LogoID]，没有检索返回的ID不得编造、不得声称已支持这个入口。网页裁取/网上Logo抓取也只有开放了真实对应工具才能声称执行。
落位要避开标题、正文、电话、二维码、人脸和关键产品，优先用户指定方位的留白。旧包添加Logo会按素材原始宽高比计算：默认宽=画布短边16%，边距=短边5.5%，位置按box中心吸附左/中/右与上/中/下；大一点乘1.35、小一点乘0.78。检查的是这一最终占位，而不是只检查你填的小框。box须在[0,1]内、面积不超过35%，并尽量与最终位置一致，保证模型清理区域和手机贴图区域相同。明确替换旧Logo时手机使用原box，必须依据预览定位旧Logo区域。
有空位就保持原海报，不把标题或说明覆盖掉。用户没有同意改版时不得设preserve_outside=false；如果用户明确同意微调且确需腾出位置，才允许采用调整底图，并说明实际改变。不能用“替换”措辞绕过添加时的客户端吸附逻辑。
透明Logo用原透明素材；纯色底/复杂底用旧包已支持的background=auto尽力去底，二维码保留底色与留白。不要编造抠图、遮挡检查或最终像素验收结果；只有收到实际工具成功才说完成。该规则不会新增工具或让旧包获得新的抠图算法。`;

function enabledFor(policy, accountId) {
  let value = policy;
  if (typeof value === "string") {
    if (value.length > 6000) return false;
    try { value = JSON.parse(value); } catch { return false; }
  }
  if (!value || typeof value !== "object" || Array.isArray(value) || value.enabled !== true) return false;
  // Public rollout must be explicit; the caller is still an authenticated member.
  if (typeof accountId !== "string" || !accountId) return false;
  if (value.audience === "all") return true;
  if (!Array.isArray(value.accountIds) || value.accountIds.length > 100) return false;
  return value.accountIds.some(id => typeof id === "string" && id !== "*" && id === accountId);
}

function injectLegacyBrandGuidance({ messages, tools, policy, accountId }) {
  if (!enabledFor(policy, accountId) || !Array.isArray(messages) || !Array.isArray(tools)) return messages;
  const edit = tools.find(tool => tool?.type === "function" && tool.function?.name === "image_edit");
  const properties = edit?.function?.parameters?.properties;
  // The tool definitions come from the actual phone, not a version guessed by us.
  if (!properties || !properties.prompt || !properties.source_index || !properties.source_indexes ||
      !properties.reference_roles || !properties.library_refs ||
      !properties.structured?.properties?.preserve_assets || !properties.structured.properties.text || !properties.source ||
      !Array.isArray(properties.source.enum) || !properties.source.enum.includes("both")) return messages;
  const last = [...messages].reverse().find(message => message?.role === "user");
  const text = typeof last?.content === "string" ? last.content : Array.isArray(last?.content)
    ? last.content.filter(part => part?.type === "text").map(part => part.text || "").join("\n") : "";
  if (!/logo|标识|标志|商标|徽标|二维码/i.test(text) ||
      !/添加|加上|加到|放到|放在|放上|贴|替换|换|抠|去底|去背景|透明|提取|搜索|查找/i.test(text)) return messages;
  if (messages.some(message => message?.role === "system" && typeof message.content === "string" && message.content.includes(VERSION))) return messages;
  const intent = uploadedLogoAddition(messages, require('./verbatim-image-prompt').authoredText(messages));
  const guidance = intent?.style
    ? '用一次 image_edit。按本轮附件顺序区分原海报和Logo，保留原海报的阅读顺序和文案。按用户指定风格设计，不写新标题。' +
      (intent.composeExact ? '在底图上测量不遮挡内容的小框，填入 preserve_assets。' : '')
    : RULE;
  return [...messages, { role: "system", content: guidance }];
}

function uploadedLogoAddition(messages, text) {
  const direct = /^(?:请)?在(?:这张|上一张|刚才的|原)?海报(?:上|里)(?:加上|加|添加|贴上|放上)(?:这个|这张|我上传的)?\s*(?:logo|标识|标志|商标|徽标)[。！! ]*$/i.test(text.trim());
  const correction = /(?:我|其实|还是|就)?只(?:是想|需要|要|想|需)?\s*(?:在(?:原图|原海报|海报)上)?(?:加上|加|添加|贴上|放上)(?:之前的|那个|这个|公司)?\s*(?:logo|标识|标志|徽标)[。！!？? ]*$/i.test(text.trim());
  // Only bind a pure restyle + numbered logo addition. A request to change copy,
  // canvas, logo placement or other content must keep its full planning path.
  const styleEdit = /^(?:请)?(?:把(?:这张|原)?(?:海报|图[一二12])|将(?:海报|图[一二12]))?(?:换成|改成|改为|换为)([^，。；、\n]{1,24}?风(?:格)?)(?:的)?[，, ]*(?:并且|同时|然后|并|再)?(?:加上|添加|贴上|放上)(?:第([一二12])张(?:图)?|图([一二12]))(?:中|上)?的\s*(?:logo|标志|标识|徽标)[。！! ]*$/iu.exec(text.trim());
  if (!direct && !correction && !styleEdit) return null;
  const { isHistoryPreview } = require('./image-delivery');
  const parts = messages.findLast(message => message?.role === 'user' && !isHistoryPreview(message))?.content;
  if (!Array.isArray(parts)) return correction ? {base:false} : null;
  const base = parts[0]?.text?.startsWith('【本次编辑前生成图预览】') && parts[1]?.type === 'image_url'
      && parts[2]?.text === '【以下是用户本轮输入与上传附件，source_index仍按原附件顺序从1计数】';
  const uploads = (base ? parts.slice(3) : parts).filter(part => part?.type === 'image_url');
  if (styleEdit && uploads.length === 2) {
    const logoIndex = /[一1]/.test(styleEdit[2] || styleEdit[3]) ? 1 : 2;
    // Older app builds treat “换 … 这张 … Logo” as requiring exact local composition.
    // Keep that transport contract while allowing the unambiguous restyle to co-design its logo.
    return {base: true, style: styleEdit[1], indices: [3 - logoIndex, logoIndex], composeExact: /这张|原图/.test(text)};
  }
  if (styleEdit) return null;
  if (correction && (!base || !parts[0].text.startsWith('【本次编辑前生成图预览】已回到上次贴标前的原海报。'))) return {base:false};
  return uploads.length === 1 ? { base: Boolean(base) } : correction ? {base:false} : null;
}

function finalizeUploadedLogoAddition(calls, intent) {
  if (!intent) return calls;
  return calls.map(call => {
    if (!['image_generate', 'image_edit', 'image_series', 'generate_image'].includes(call?.function?.name)) return call;
    const reject = () => {
      throw Object.assign(Error('BRAND_PLAN_CONFLICT'), { code: 'BRAND_PLAN_CONFLICT' });
    };
    if (!intent.base || call.function.name !== 'image_edit') reject();
    const args = JSON.parse(call.function.arguments);
    if (intent.style && !intent.composeExact) {
      return { ...call, function: { ...call.function, arguments: JSON.stringify({
        source: 'attached', source_indexes: intent.indices, reference_roles: ['原海报', 'Logo原件'],
        prompt: '图1是要调整风格的原海报，图2是必须使用的原Logo。保留图1的标题、日期、原文、各栏目、图文关系和阅读顺序。换成' +
          intent.style + '。按题材选合适的色彩与媒介。适合亮色时，让清亮高饱和的主题色贯穿主视觉、区块和背景，用主题相关场景、纹理或光线建立层次，让正文易读。' +
          '将图2放入一个与文字、边距和光线自然呼应的小位置，去除外圈白底，保留完整标志形状和色彩，只出现一次。画面只保留原稿文字。',
        structured: { text: [] }
      }) } };
    }
    const asset = args.structured?.preserve_assets?.[0];
    const validBox = asset?.box && ['x','y','width','height'].every(key => Number.isFinite(asset.box[key]));
    if (!validBox || args.structured.preserve_assets.length !== 1) reject();
    const {x,y,width,height} = asset.box;
    if (x < 0 || y < 0 || width <= 0 || height <= 0 || x + width > 1 || y + height > 1 || width * height > 0.35) reject();
    if (intent.style) {
      const color = ' ' + require('./poster-delivery').DEFAULT_COLOR_DIRECTION;
      return { ...call, function: { ...call.function, arguments: JSON.stringify({
        source: 'attached', source_indexes: intent.indices, reference_roles: ['原海报', 'Logo原件'],
        prompt: '以底图原海报为准。仅将视觉表现调整为' + intent.style + '。沿用原稿标题、日期、栏目及每段原文。只改变配色、材质与无字装饰，保持文字清晰可读。' + color,
        structured: { text: [], preserve_outside: false, exact_logo_addition: true, preserve_assets: [
          {reference_index: 2, kind: 'logo', background: 'auto', box: {x,y,width,height}}
        ] }
      }) } };
    }
    return { ...call, function: { ...call.function, arguments: JSON.stringify({
      source: 'both', source_index: 1, prompt: '在原海报上加上本轮上传的Logo。保持原图比例、标题、正文、插画和布局。',
      structured: { text: [], preserve_outside: true, exact_logo_addition: true,
        preserve_assets: [{ reference_index: 2, kind: 'logo', background: 'auto', box: {x,y,width,height} }] }
    }) } };
  });
}

function requestsMultipleBrandOutputs(text) {
  // Count target works, not input references: two photos can still make ONE poster.
  return /(?:每张|每一张|各张)(?:海报|图片|图)|(?:两张|三张|这些|这几张|所有)(?:海报|图片|图)[^，。\n]{0,12}(?:都|各|分别)|分别(?:给|为)[^，。\n]{0,16}(?:添加|加上|替换)/.test(String(text || ""));
}

function guardBrandCalls(calls, observe = () => {}, userText = "") {
  if (requestsMultipleBrandOutputs(userText)) return calls;
  const imageNames = new Set(["image_edit", "image_generate", "image_series", "image_decompose", "generate_image"]);
  const imageCalls = calls.filter(call => imageNames.has(call?.function?.name));
  if (imageCalls.length < 2) return calls;
  const stable = value => Array.isArray(value) ? value.map(stable) : value && typeof value === "object"
    ? Object.fromEntries(Object.keys(value).sort().map(key => [key, stable(value[key])])) : value;
  const identity = call => JSON.stringify([call.function.name, stable(JSON.parse(call.function.arguments))]);
  const first = identity(imageCalls[0]);
  // Only byte-equivalent execution data (ignoring object key order) can be merged.
  // Different positions/sources/prompts require a new plan, never silently choose one.
  if (imageCalls.some(call => identity(call) !== first)) {
    observe({ event: "brand_plan_conflict", imageCallCount: imageCalls.length });
    const error = new Error("BRAND_PLAN_CONFLICT"); error.code = "BRAND_PLAN_CONFLICT"; throw error;
  }
  let kept = false;
  const output = calls.filter(call => {
    if (!imageNames.has(call?.function?.name)) return true;
    if (kept) return false;
    kept = true; return true;
  });
  observe({ event: "brand_duplicate_calls_removed", removed: imageCalls.length - 1 });
  return output;
}

module.exports = { VERSION, RULE, enabledFor, injectLegacyBrandGuidance, guardBrandCalls, requestsMultipleBrandOutputs, uploadedLogoAddition, finalizeUploadedLogoAddition };
