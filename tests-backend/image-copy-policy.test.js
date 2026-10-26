const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../cloudfunctions/bf-image/index.js'), 'utf8');
const start = source.indexOf('function assembleStructured(');
const end = source.indexOf('/**', source.indexOf('function visibleCopyValues(', start));
const context = {};
vm.runInNewContext(source.slice(start, end), context);

test('overlay fallback never reintroduces visible copy when the visual prompt is absent', () => {
  const structured = { subject: '城市插画', text: [{ role: 'title', text: '精确客户标题' }] };
  assert.equal(context.assembleStructured(structured, false), '城市插画。');
  assert.ok(context.assembleStructured(structured).includes('精确客户标题'));
});

test('malformed structured values never become object-object or invented visible copy', () => {
  assert.equal(context.assembleStructured({ subject: { text: 'wrong' }, text: [{ text: {} }] }), '');
});
