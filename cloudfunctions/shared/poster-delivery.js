"use strict";

const POSTER = /海报|宣传图|活动展架|易拉宝|宣传单|价目表|\b(?:poster|flyer)\b/i;
const LOCAL_CHANGE = /只(?:需|要)?(?:改|加|换|删除)|(?:原图|底图|版式|比例).{0,6}(?:不变|保持|别动)|保留.{0,8}(?:原图|原版式)|换(?:个|一种)?风格|旧稿改版/;
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

function nativePoster(args, userText) {
  if (args.render_intent === 'mockup' || ['edit', 'series'].includes(args.task_kind)) return false;
  return !excluded(args.structured, args.text_mode, args.layer_decomposition)
    && !['last', 'both'].includes(args.source)
    && !LOCAL_CHANGE.test(String(userText || ''))
    && !NO_COPY.test(String(userText || ''))
    && posterRequested(args.render_intent, args.prompt, userText);
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

function mark(structured, userText) {
  return { ...structured, poster_delivery: { version: 1, density: SPARSE.test(String(userText || '')) ? 'sparse' : 'dense' } };
}

function modeFor({ structured, prompt, renderIntent, taskKind, textMode, layerDecomposition, selectedModel }) {
  if (!/^doubao-seedream-5-5-/.test(selectedModel) || !['generate', 'reference', ''].includes(taskKind || '')
    || renderIntent === 'mockup' || excluded(structured, textMode, layerDecomposition) || LEGACY_COMPILED.test(prompt)
    || NO_COPY.test(prompt) || LOCAL_CHANGE.test(prompt)) return null;
  const delivery = structured?.poster_delivery;
  if (delivery?.version !== 1 && !posterRequested(renderIntent, prompt)) return null;
  if (!copyOf(structured).some(row => typeof row?.text === 'string' && row.text.trim())) return null;
  return delivery?.density === 'sparse' || (!delivery && SPARSE.test(prompt)) ? 'sparse' : 'dense';
}

function compile({ visual, structured, density }) {
  const roles = {title:'主标题',subtitle:'副标题',label:'分区标题',body:'说明',contact:'联系方式',footer:'署名'};
  const rows = copyOf(structured).filter(row => typeof row?.text === 'string' && row.text.trim());
  const design = density === 'dense' ?
    '按内容组织高密度商业海报。场景、材质和光影共同建立有层次的背景。用相关实景、产品细节、图标或关系图承载各组信息，避免大块空白或纯色；按阅读顺序安排疏密。' :
    '遵循用户指定的留白与简洁程度，保持文字清晰。';
  const brief = typeof structured.design_brief?.visual_approach === 'string' ? structured.design_brief.visual_approach.trim() : '';
  const copy = rows.map(row => `${roles[row.role] || roles.body}：${row.text.split(/\r?\n/).map(line => JSON.stringify(line)).join('\n')}`);
  return [visual, brief && !visual.includes(brief) && brief, design,
    '以下为全部印刷文字。逐行照写，保持所属分区。不加清单以外的标题、数字、价格、标号、界面文字或占位文字。', ...copy]
    .filter(Boolean).join('\n');
}

module.exports = { nativePoster, normalizeRows, copyOf, mark, modeFor, compile };
