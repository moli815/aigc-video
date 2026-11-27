'use strict';

// Update the exact legacy prompt module shipped on November 26.
// Current source no longer imports this legacy module.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const [source, destination] = process.argv.slice(2);
const before = fs.readFileSync(source);
assert.equal(crypto.createHash('sha256').update(before).digest('hex'),
  '0bcf8974ee1c397c58b5ed52990c922e2000f6c4f158554573e047aa0886eac8',
  'Unexpected legacy prompt module');
const original = before.toString('utf8');
const start = original.indexOf('  // ① 带标注词的主/副标题');
const end = original.indexOf('  // ② 型号', start);
assert.ok(start >= 0 && end > start && original.slice(start, end).includes('const title ='));
const heading = String.raw`
  // Read quoted headings or explicit, standalone title fields.
  const quotedHeading = /(?<![副小])(主标题|大标题|副标题|小标题|副标|标题)\s*(?:改为|改成|换成|为|写作|写成)?\s*[:：]?\s*['"‘“「『]([^‘’'"“”「」『』\n]+)['"’”」』]/gu;
  const plainHeading = /^[ \t]*(主标题|大标题|副标题|小标题|副标|标题)[ \t]*[:：][ \t]*([^\r\n]+)$/gmu;
  const headingRoles = new Set();
  for (const match of [...text.matchAll(quotedHeading), ...text.matchAll(plainHeading)]) {
    const role = /^(副|小)/.test(match[1]) ? 'subtitle' : 'title';
    if (!headingRoles.has(role)) push(role, match[2]);
    headingRoles.add(role);
  }

`;
const fixed = original.slice(0, start) + heading + original.slice(end);
fs.writeFileSync(destination, fixed, { flag: 'wx' });

const live = require(path.resolve(source));
const candidate = require(path.resolve(destination));
for (const [brief, wrong] of [
  ['保持原标题和正文。', '和正文'],
  ['标题区加冷蓝色霓虹光效。', '区加冷蓝色霓虹光效'],
]) {
  assert.equal(live.extractCopy(brief)[0].text, wrong);
  assert.deepEqual(candidate.extractCopy(brief), []);
  assert.ok(!candidate.augment(brief).includes('标题「' + wrong + '」'));
}
assert.deepEqual(candidate.extractCopy('主标题“AI 热讯日报”，副标题「产品与应用」。'),
  [{ role: 'title', text: 'AI 热讯日报' }, { role: 'subtitle', text: '产品与应用' }]);
assert.deepEqual(candidate.extractCopy('标题：用户写的标题'), [{ role: 'title', text: '用户写的标题' }]);
assert.ok(candidate.augment('版式按原稿。', { structured: { text: [
  { role: 'title', text: '用户指定的新标题' },
] } }).includes('用户指定的新标题'));
