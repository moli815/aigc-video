"use strict";

const POSTER = /海报|宣传图|活动展架|易拉宝|宣传单|价目表|\b(?:poster|flyer)\b/i;
const LOCAL_CHANGE = /只(?:需|要)?(?:改|加|换|删)(?:动|修|除)?(?:其中|局部|一下|这个|那块)?(?:logo|标识|二维码|错字|电话|标题|背景|底色|文案|价格|水印|一处)|只改局部|其余.{0,6}(?:不变|别动)/i;
const SPARSE = /极简|少字|只(?:写|印|放)(?:一个)?(?:主)?标题|大面积留白|纯(?:白|黑|色)(?:底|背景)/;
const NO_COPY = /不要(?:任何)?(?:文字|文案)|无字(?:底图|海报)?|不(?:写|印|要)(?:任何)?字/;
const ROLES = new Set(['title', 'subtitle', 'label', 'body', 'contact', 'footer']);
const LEGACY_COMPILED = /(?:^|\n)以下文字逐字照写、不得改动；画面不出现其它文字、伪字或乱码：/;

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
  const explicitDesign=request.length<=300 && /风格|版式|构图|画风|配色|色调|手绘|插画|极简|留白|横版|竖版|复古|摄影|不要.{0,8}(?:图标|文字|装饰)/.test(request);
  return { ...structured, poster_delivery: { version: 1, density: SPARSE.test(request) ? 'sparse' : 'dense',
    ...(explicitDesign ? {user_direction:request}: {}),
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
  return delivery?.density === 'sparse' || (!delivery && SPARSE.test(prompt)) ? 'sparse' : 'dense';
}

function compile({ visual, structured, density }) {
  const roles = {title:'主标题',subtitle:'副标题',label:'分区标题',body:'说明',contact:'联系方式',footer:'署名'};
  const rows = copyOf(structured).filter(row => typeof row?.text === 'string' && row.text.trim());
  const design = density === 'dense' ?
    '根据主题、产品、文案关系和品牌资料决定视觉语言。完整表达内容；用主题相关的空间、实物、光影、材质或图解做背景和点缀，让标题与内容层级清楚。配色、装饰、构图随题材变化。' :
    '遵循用户指定的留白与简洁程度，保持文字清晰。';
  const brief = typeof structured.design_brief?.visual_approach === 'string' ? structured.design_brief.visual_approach.trim() : '';
  const copy = rows.map(row => `${roles[row.role] || roles.body}：${row.text.split(/\r?\n/).map(line => JSON.stringify(line)).join('\n')}`);
  const userDirection=structured?.poster_delivery?.user_direction;
  const priority=typeof userDirection==='string' && userDirection.trim() && userDirection.length<=300
    ? '最高优先级是本轮用户明确的风格、元素和版式要求，原话：'+JSON.stringify(userDirection)
    : '当前明确要求优先，其次使用本轮选定的参考；同品牌已确认偏好才用于补默认。布局与美术由你决定。';
  const polished=visual.replace(/(?:不要|不)(?:出现|绘制|添加)(?:任何)?(?:文字|文案)[。.!！]?(?=$|\s)/g,'').trim();
  const reference=structured?.poster_delivery?.reference_redesign
    ? '图1是整张需要换风格的原稿。保留原图主标题、主体、关系和全部栏目，设计一个清楚的主视觉。背景和点缀从主题、真实使用场景及产品特征取材，维持原图信息量。只保留原稿与本轮确认的内容。无明确授权时不要新增任何电话、地址、网址、二维码、价格、联系栏、品牌或宣传承诺。' : '';
  // For whole-artwork restyling, artwork is the authoritative visual input.
  // The planner's invented aesthetic restrictions must not overrule it.
  const direction=reference?reference:[polished,brief&&!visual.includes(brief)&&brief].filter(Boolean).join('\n');
  return [priority, design, direction,
    '以下为全部印刷文字。原样印刷，每项只出现一次，保持与所属图解或分区对应。原稿主标题只放一个主标题位。不得另加清单外的词、数字或占位文字。', ...copy]
    .filter(Boolean).join('\n');
}

module.exports = { posterRequested, nativePoster, normalizeRows, copyOf, mark, modeFor, compile };
