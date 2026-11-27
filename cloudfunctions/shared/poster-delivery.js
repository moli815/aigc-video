"use strict";

const { compileDesignBrief } = require('./image-design-brief');

const POSTER = /海报|招贴|宣传图|活动展架|易拉宝|宣传单|价目表|\b(?:poster|flyer)\b/i;
const LOCAL_CHANGE = /只(?:需|要)?(?:改|加|换|删)(?:动|修|除)?(?:其中|局部|一下|这个|那块)?(?:logo|标识|二维码|错字|电话|标题|背景|底色|文案|价格|水印|一处)|只改局部|其余.{0,6}(?:不变|别动)/i;
const SPARSE = /极简|少字|只(?:写|印|放)(?:一个)?(?:主)?标题|大面积留白|纯(?:白|黑|色)(?:底|背景)/;
const NO_COPY = /不要(?:任何)?(?:文字|文案)|无字(?:底图|海报|背景图)|不(?:写|印|要)(?:任何)?字/;
const DESIGN_WORDS = /风格|版式|布局|构图|画风|配色|色调|插画|手绘|水彩|极简|留白|复古|摄影|杂志|色(?:底|背景)|(?:不要|别|不用|不加|禁用|不做).{0,8}(?:图标|卡片|文字|装饰|渐变|照片|纯色|背景)/;
const DELEGATED_DESIGN = /^(?:(?:画面)?(?:的)?(?:风格|版式|排版|布局|构图|配色|色调)[与和、及]?)+(?:由你|交给你|让你|你)?(?:来|自己|自行|自由|随意|看着|灵活|按内容|根据内容)*(?:决定|定|设计|选择|选|安排|发挥|调整|来)?(?:就好|即可|就行)?$/;
const ROLES = new Set(['title', 'subtitle', 'label', 'body', 'contact', 'footer']);
const LEGACY_COMPILED = /(?:^|\n)以下文字逐字照写、不得改动；画面不出现其它文字、伪字或乱码：/;
const DEFAULT_COLOR_DIRECTION = '按主题、用途和受众选择媒介和配色。适合鲜明视觉时，默认用与内容相配的高饱和主色或强调色贯穿主视觉、背景细节与重点。正文区保持清楚的对比。用户指定的风格、配色和品牌视觉优先，并保留水墨等媒介本身的色彩特点。';
const PLANNER_GUIDANCE = [
  DEFAULT_COLOR_DIRECTION,
  '【海报设计简报】按本轮要交付的成品、受众、主题及已确认事实构思。优先执行用户明确指定的媒介、色彩、构图、留白、信息量与禁止项；其次是本轮选定的风格参考，同主题、同项目且用户确认的偏好仅补空缺。新主题由本轮内容决定美术，不把旧项目的漫画、卡通或色系当作跨项目默认，也不因为Logo自身是插画就沿用到整张图。科技新闻以当期真实内容选择编辑式排版、信息图及相关科技场景，其他主题按自身素材决定。品牌和参考原件按用途绑定。',
  '默认商业海报以主视觉统领整页。标题与主题场景、插画或材质呼应；挑适合可视化的栏目，给它们各自相关的业务细节。用与业务有关的环境、材质或图形语言衔接标题区、边缘和区块间；通过前中后景、统一色彩与明暗层次建立完整画面，正文背后降低纹理细节、保持高对比。用已确认的功能用途承载信息密度，保留原件、数字和图文对应。这些视觉内容和选用的媒介写进简报。不要因字多自行禁用照片或配图、留大片空底，也不强制固定栏数或同款卡片。用户要求的极简、留白、无配图和纯摄影照做。',
  'prompt 写简短自然的视觉委托，交代主体、场景、表现手法及必要约束，约300字以内；已提供的图片只说明编号与作用。定稿全部放 structured.text，视觉简报不再重列标签、编号和文案，也不单独重排同一栏目。仅有真实先后关系时画流程。在 design_brief.visual_map 里按正文 key 对应表现形式，用具体的主题场景、细节或图解说明怎么表达。整图改款保留原稿主体、定稿和用户未要求改变的内容关系。',
].join('\n');

function sparseRequested(request) {
  return [...request.matchAll(new RegExp(SPARSE.source, 'g'))].some(match =>
    !/(?:不要|别|不用|无需|不必|避免|拒绝)[^，。；\n]{0,8}$/.test(request.slice(Math.max(0,match.index-12),match.index)));
}

function userDesignOf(request) {
  const hasDirection=clause=>clause.split(/[，,。！？；\n]+/).some(part=>{
    const text=part.trim();
    return DESIGN_WORDS.test(text)&&!DELEGATED_DESIGN.test(text);
  });
  if (request.length<=300) return hasDirection(request)?request:'';
  // A long turn often includes a handoff or literal copy before the actual
  // design direction. Carry its short visual clauses, not its entire text.
  const clauses=request.split(/[。！？；\n]+/).map(clause=>clause.trim());
  const selected=new Set();
  let remaining=300;
  for (const clause of clauses.reverse()) {
    if (!clause || clause.length>remaining || selected.has(clause) || !hasDirection(clause)) continue;
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

function exactCopyRequested(request) {
  return String(request || '').split(/[，。；,;！？\n]/u).some(clause =>
    !/(?:不用|不必|无需|不要|不要求).{0,6}(?:逐字|原样|一字不差)/u.test(clause)
    && /(?:逐字|一字不差|原样)(?:照写|印刷|照印|排印|印上|印在(?:海报|画面|图)上|上图|呈现|保留(?:全部|所有)?(?:文案|文字))|(?:文案|正文|文字)(?:必须|需要|要求)?一字不差/u.test(clause));
}

function mark(structured, userText, { referenceRedesign = false } = {}) {
  const request=String(userText||'').trim();
  const userDirection=userDesignOf(request);
  return { ...structured, poster_delivery: { version: 1, density: sparseRequested(request) ? 'sparse' : 'dense',
    ...(userDirection ? {user_direction:userDirection}: {}),
    ...(exactCopyRequested(request) ? {exact_copy:true}: {}),
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
  const explicit=typeof userDirection==='string' && userDirection.length<=300 && userDesignOf(userDirection);
  const priority=explicit
    ? '最高优先级是本轮用户明确的风格、元素和版式要求，原话：'+JSON.stringify(userDirection)
    : '当前明确要求优先，其次使用本轮选定的参考；同品牌已确认偏好才用于补默认。布局与美术由你决定。';
  const design = density === 'sparse' ? '按用户要求留白，保持文字清晰。' : explicit
    ? '按指定视觉要求呈现全部定稿；视觉解释只用用户允许的形式。'
    : '做成主题鲜明的商业图文成品。把标题融入主视觉，用呼应主题的画面、纹理或形状带出标题层次；让关键分区各自用相关实景、物件细节或图解帮助读懂内容。把场景细节或无字装饰延续到大块空底和分区之间，保持正文区域清楚。配色、媒介、构图由你按内容决定。';
  const polished=visual.replace(/(?:不要|不)(?:出现|绘制|添加)(?:任何)?(?:文字|文案)[。.!！]?(?=$|\s)/g,'').trim();
  const reference=structured?.poster_delivery?.reference_redesign
    ? '图1是需要换风格的原稿。保留原图主标题、主体、关系和全部栏目，以本轮确认的改动为准。未经确认不新增电话、地址、网址、二维码、价格、品牌或宣传承诺。' : '';
  // For whole-artwork restyling, artwork is the authoritative visual input.
  // The planner's invented aesthetic restrictions must not overrule it.
  const direction=reference?reference:polished||brief;
  const color = density === 'dense' && !explicit ? DEFAULT_COLOR_DIRECTION : '';
  const planned = density === 'dense' && !reference && Array.isArray(structured.design_brief?.visual_map)
    ? compileDesignBrief(structured.design_brief, { visualExecution: true, items: rows })
    : '';
  if (planned) return [priority, design, color, polished, planned].filter(Boolean).join('\n');
  return [priority, design, color, direction,
    '以下引号内是全部可见文案；中文和英文都以清单为准，留白处只画相关实物或图形。不要自行做英文副标、口号、页眉或页脚。每个栏目标题和它的说明合在唯一一处，逐字印刷一次。末栏若有行动信息就在该栏呈现，不另抄到底栏。装饰、图示和非原件小插画仅用无字图形，不加清单外的编号、词句、数字或占位文字。', ...copy]
    .filter(Boolean).join('\n');
}

module.exports = { PLANNER_GUIDANCE, DEFAULT_COLOR_DIRECTION, posterRequested, nativePoster, normalizeRows, copyOf, mark, modeFor, compile };
