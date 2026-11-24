"use strict";

const POSTER = /海报|招贴|宣传图|活动展架|易拉宝|宣传单|价目表|\b(?:poster|flyer)\b/i;
const LOCAL_CHANGE = /只(?:需|要)?(?:改|加|换|删)(?:动|修|除)?(?:其中|局部|一下|这个|那块)?(?:logo|标识|二维码|错字|电话|标题|背景|底色|文案|价格|水印|一处)|只改局部|其余.{0,6}(?:不变|别动)/i;
const SPARSE = /极简|少字|只(?:写|印|放)(?:一个)?(?:主)?标题|大面积留白|纯(?:白|黑|色)(?:底|背景)/;
const NO_COPY = /不要(?:任何)?(?:文字|文案)|无字(?:底图|海报)?|不(?:写|印|要)(?:任何)?字/;
const DESIGN_WORDS = /风格|版式|布局|构图|画风|配色|色调|插画|手绘|水彩|极简|留白|复古|摄影|杂志|色(?:底|背景)|(?:不要|别|不用|不加|禁用|不做).{0,8}(?:图标|卡片|文字|装饰|渐变|照片|纯色|背景)/;
const ROLES = new Set(['title', 'subtitle', 'label', 'body', 'contact', 'footer']);
const LEGACY_COMPILED = /(?:^|\n)以下文字逐字照写、不得改动；画面不出现其它文字、伪字或乱码：/;
const PLANNER_GUIDANCE = [
  '【海报设计简报】按本轮要交付的成品、受众、主题及已确认事实构思。优先执行用户明确指定的媒介、色彩、构图、留白、信息量与禁止项；其次是本轮选定的风格参考，同项目确认过的偏好仅补空缺。品牌和参考原件按用途绑定。',
  '默认商业海报先确定一个主视觉，再按真实的信息关系组织分区。把关键内容变成能读懂的实景、细节或关系图，让配图也传达信息；资料充足时保留必要解释，避免段落或同款卡片铺满。色彩、媒介、背景、装饰和栏数由本轮内容与构图决定。极简、留白、无配图和纯摄影按用户当前要求执行。',
  'prompt 写简短自然的视觉委托，交代主体、场景、表现手法及必要约束，视觉说明尽量不超过约300字；已有图片只说明编号和作用，省去逐件复述。structured.text 保留完整定稿。仅有真实先后关系时画流程，并列内容不补步骤编号。没有依据的名称、数字与承诺不补。整图改款保留原稿主体和用户未要求改变的内容关系。',
].join('\n');

function sparseRequested(request) {
  return [...request.matchAll(new RegExp(SPARSE.source, 'g'))].some(match =>
    !/(?:不要|别|不用|无需|不必|避免|拒绝)[^，。；\n]{0,8}$/.test(request.slice(Math.max(0,match.index-12),match.index)));
}

function userDesignOf(request) {
  if (request.length<=300) return DESIGN_WORDS.test(request)?request:'';
  // A long turn often includes a handoff or literal copy before the actual
  // design direction. Carry its short visual clauses, not its entire text.
  const clauses=request.split(/[。！？；\n]+/).map(clause=>clause.trim());
  const selected=new Set();
  let remaining=300;
  for (const clause of clauses.reverse()) {
    if (!clause || clause.length>remaining || selected.has(clause) || !DESIGN_WORDS.test(clause)) continue;
    selected.add(clause);
    remaining-=clause.length+1;
  }
  return [...selected].reverse().join('。');
}

function posterRequested(renderIntent, prompt, userText) {
  return ['poster', 'flyer', 'advertisement', 'campaign'].includes(renderIntent)
    || POSTER.test(String(userText || '') + '\n' + String(prompt || ''));
}

function excluded(structured, textMode, layerDecomposition) {
  const plan = structured?.image_plan;
  return textMode === 'overlay' || layerDecomposition === true || structured?.poster_reformat
    || structured?.preserve_assets?.length || plan?.typography === 'typeset'
    || ['redesign','local_edit'].includes(plan?.intent) || plan?.protected_references?.length;
}

function nativePoster(args, userText, { referenceDesign = false } = {}) {
  if (args.render_intent === 'mockup' || ['edit', 'series'].includes(args.task_kind)) return false;
  return !excluded(args.structured, args.text_mode, args.layer_decomposition)
    && !['last', 'both'].includes(args.source)
    && !LOCAL_CHANGE.test(String(userText || ''))
    && !NO_COPY.test(String(userText || ''))
    && (referenceDesign || posterRequested(args.render_intent, args.prompt, userText));
}

function normalizeRows(value) {
  if (!Array.isArray(value)) return value;
  return value.map((entry, index) => {
    if (typeof entry === 'string') return { key: `copy_${index + 1}`, role: 'body', text: entry };
    if (!entry || typeof entry !== 'object' || Array.isArray(entry)) return entry;
    const text = entry.text ?? entry.content ?? entry.value;
    if (typeof text !== 'string') return entry;
    const role = entry.role ?? entry.type;
    return { ...entry, key: entry.key || `copy_${index + 1}`, role: ROLES.has(role) ? role : 'body', text };
  });
}

function copyOf(structured) {
  const copy = structured?.text;
  if (Array.isArray(copy) && copy.length) return normalizeRows(copy);
  if (typeof copy === 'string' && copy.trim()) {
    return normalizeRows(copy.split(/\r?\n/).filter(line => line.trim()));
  }
  const fields = copy && typeof copy === 'object' ? copy : structured;
  if (!fields) return [];
  const rows = [];
  const add = (role, text) => {
    if ((typeof text === 'string' && text.trim()) || (typeof text === 'number' && Number.isFinite(text))) {
      rows.push({ key: `copy_${rows.length + 1}`, role, text: String(text) });
    }
  };
  add('title', fields.title ?? fields.headline ?? fields.main_title);
  add('subtitle', fields.subtitle ?? fields.sub_title ?? fields.tagline);
  const products = fields.products ?? fields.items;
  if (Array.isArray(products)) for (const item of products) {
    if (typeof item === 'string') { add('body', item); continue; }
    if (!item || typeof item !== 'object') continue;
    add('label', item.name ?? item.title ?? item.label);
    add('body', item.body ?? item.desc ?? item.description ?? item.spec);
    add('body', item.price);
  }
  const labels = Array.isArray(fields.labels) ? fields.labels : [];
  const bodies = Array.isArray(fields.bodies) ? fields.bodies : [];
  for (let i = 0; i < Math.max(labels.length, bodies.length); i++) {
    add('label', labels[i]);
    add('body', bodies[i]);
  }
  for (const key of ['craft', 'member', 'points', 'features', 'selling_points', 'services']) {
    if (Array.isArray(fields[key])) for (const item of fields[key]) add('body', item?.text ?? item?.name ?? item?.title ?? item);
  }
  add('body', fields.allergen);
  add('contact', fields.contact);
  add('footer', fields.footer);
  return rows;
}

function mark(structured, userText, { referenceRedesign = false } = {}) {
  const request=String(userText||'').trim();
  const userDirection=userDesignOf(request);
  return { ...structured, poster_delivery: { version: 1, density: sparseRequested(request) ? 'sparse' : 'dense',
    ...(userDirection ? {user_direction:userDirection}: {}),
    ...(referenceRedesign ? {reference_redesign:true}: {}) } };
}

function modeFor({ structured, prompt, renderIntent, taskKind, textMode, layerDecomposition, selectedModel }) {
  if (!/^doubao-seedream-5-5-/.test(selectedModel) || !['generate', 'reference', ''].includes(taskKind || '')
    || renderIntent === 'mockup' || excluded(structured, textMode, layerDecomposition) || LEGACY_COMPILED.test(prompt)
    ) return null;
  const delivery = structured?.poster_delivery;
  if(delivery?.version!==1 && (NO_COPY.test(prompt)||LOCAL_CHANGE.test(prompt)))return null;
  if (delivery?.version !== 1 && !posterRequested(renderIntent, prompt)) return null;
  if (!copyOf(structured).some(row => typeof row?.text === 'string' && row.text.trim())) return null;
  return delivery?.density === 'sparse' || (!delivery && sparseRequested(prompt)) ? 'sparse' : 'dense';
}

function compile({ visual, structured, density }) {
  const roles = {title:'主标题',subtitle:'副标题',label:'分区标题',body:'说明',contact:'联系方式',footer:'署名'};
  const rows = copyOf(structured).filter(row => typeof row?.text === 'string' && row.text.trim());
  const brief = typeof structured.design_brief?.visual_approach === 'string' ? structured.design_brief.visual_approach.trim() : '';
  const copy = rows.map(row => `${roles[row.role] || roles.body}：${row.text.split(/\r?\n/).map(line => JSON.stringify(line)).join('\n')}`);
  const userDirection=structured?.poster_delivery?.user_direction;
  const explicit=typeof userDirection==='string' && userDirection.trim() && userDirection.length<=300;
  const priority=explicit
    ? '最高优先级是本轮用户明确的风格、元素和版式要求，原话：'+JSON.stringify(userDirection)
    : '当前明确要求优先，其次使用本轮选定的参考；同品牌已确认偏好才用于补默认。布局与美术由你决定。';
  const design = density === 'sparse' ? '按用户要求留白，保持文字清晰。' : explicit
    ? '按指定视觉要求呈现全部定稿；视觉解释只用用户允许的形式。'
    : '确立一个主视觉，让实物、环境细节或图解帮助读懂内容关系。按信息自然组织分区与阅读节奏，背景与主体有层次。完整呈现定稿，配色、媒介和布局按主题自由设计。';
  const polished=visual.replace(/(?:不要|不)(?:出现|绘制|添加)(?:任何)?(?:文字|文案)[。.!！]?(?=$|\s)/g,'').trim();
  const reference=structured?.poster_delivery?.reference_redesign
    ? '图1是需要换风格的原稿。保留原图主标题、主体、关系和全部栏目，以本轮确认的改动为准。未经确认不新增电话、地址、网址、二维码、价格、品牌或宣传承诺。' : '';
  // For whole-artwork restyling, artwork is the authoritative visual input.
  // The planner's invented aesthetic restrictions must not overrule it.
  const direction=reference?reference:polished||brief;
  return [priority, design, direction,
    '以下为全部印刷文字。原样印刷，每项只出现一次，保持与所属图解或分区对应。原稿主标题只放一个主标题位。不得另加清单外的词、数字或占位文字。', ...copy]
    .filter(Boolean).join('\n');
}

module.exports = { PLANNER_GUIDANCE, posterRequested, nativePoster, normalizeRows, copyOf, mark, modeFor, compile };
