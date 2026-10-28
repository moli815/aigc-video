// Compatibility probe: no production-account mutation and no customer images.
// Synthetic previews exercise the existing chat transport, not an iOS simulator.
const fs = require('node:fs'), path = require('node:path'), crypto = require('node:crypto');
const zlib = require('node:zlib'), assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const sdk = require(path.join(root, 'cloudfunctions/bf-api/node_modules/@cloudbase/node-sdk'));
const { enabledFor, injectLegacyBrandGuidance } = require('../cloudfunctions/shared/image-legacy-brand');
const credential = JSON.parse(fs.readFileSync(path.join(process.env.USERPROFILE, '.config/.cloudbase/auth.json'), 'utf8')).credential;
const app = sdk.init({ env: 'xmy-test-d5g8c0xcifcefcfd5', region: 'ap-shanghai', secretId: credential.tmpSecretId,
  secretKey: credential.tmpSecretKey, sessionToken: credential.tmpToken });
const db = app.database(), host = 'https://xmy-test-d5g8c0xcifcefcfd5-1449098021.ap-shanghai.app.tcloudbase.com';
const id = 'legacy-compat-' + crypto.randomBytes(6).toString('hex'), username = id.replaceAll('-', '_');
const liveEnabled = process.argv.includes('--live-enabled');
const account = db.collection('bf_accounts').doc(id), report = { at: new Date().toISOString(), checks: [], paidImageCalls: 0 };
let created = false, token = '';
function check(name, fields = {}) { const row = { name, ...fields }; report.checks.push(row); console.log(JSON.stringify(row)); }
async function request(route, body, expected = 200) {
  const started = Date.now();
  const response = await fetch(host + route, { method: body === undefined ? 'GET' : 'POST',
    headers: { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(190000) });
  const raw = await response.text(); let value; try { value = JSON.parse(raw); } catch { value = { raw }; }
  assert.equal(response.status, expected, `${route}: ${response.status}`);
  return { value, ms: Date.now() - started };
}
function png(width, height, pixel) {
  function crc(bytes) { let n = -1; for (const b of bytes) { n ^= b; for (let i = 0; i < 8; i++) n = (n >>> 1) ^ ((n & 1) ? 0xedb88320 : 0); } return (n ^ -1) >>> 0; }
  function chunk(type, bytes) { const t = Buffer.from(type), out = Buffer.alloc(bytes.length + 12); out.writeUInt32BE(bytes.length); t.copy(out, 4); bytes.copy(out, 8); out.writeUInt32BE(crc(Buffer.concat([t, bytes])), bytes.length + 8); return out; }
  const header = Buffer.alloc(13); header.writeUInt32BE(width); header.writeUInt32BE(height, 4); header[8] = 8; header[9] = 2;
  const raw = Buffer.alloc((width * 3 + 1) * height);
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
    const color = pixel(x, y), offset = y * (width * 3 + 1) + 1 + x * 3;
    for (let k = 0; k < 3; k++) raw[offset + k] = color[k];
  }
  return 'data:image/png;base64,' + Buffer.concat([Buffer.from('89504e470d0a1a0a', 'hex'), chunk('IHDR', header),
    chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]).toString('base64');
}
const textItem = { type: 'object', properties: { key: { type: 'string' }, role: { type: 'string', enum: ['title', 'subtitle', 'body', 'label', 'contact', 'footer'] }, text: { type: 'string' } }, required: ['key', 'role', 'text'] };
const box = { type: 'object', properties: Object.fromEntries(['x', 'y', 'width', 'height'].map(k => [k, { type: 'number' }])), required: ['x', 'y', 'width', 'height'] };
const editTool = { type: 'function', function: { name: 'image_edit', description: '编辑现有图片；上传Logo原样合成。', parameters: {
  type: 'object', properties: { prompt: { type: 'string' }, source: { type: 'string', enum: ['last', 'attached', 'both'] },
    source_index: { type: 'integer' }, source_indexes: { type: 'array', items: { type: 'integer' } }, reference_roles: { type: 'array', items: { type: 'string' } },
    library_refs: { type: 'array', items: { type: 'string' } }, structured: { type: 'object', properties: {
      preserve_outside: { type: 'boolean' }, text: { type: 'array', items: textItem }, preserve_assets: { type: 'array', items: {
        type: 'object', properties: { reference_index: { type: 'integer' }, kind: { type: 'string', enum: ['logo', 'qr', 'image'] },
          background: { type: 'string', enum: ['auto', 'keep', 'remove'] }, box }, required: ['reference_index', 'box'] } } } } }, required: ['prompt', 'source'] } } };

(async () => {
  try {
    const runtime = (await db.collection('bf_config').doc('runtime').get()).data[0]?.data || {};
    let policy = runtime.IMAGE_LEGACY_BRAND_POLICY;
    if (typeof policy === 'string') { try { policy = JSON.parse(policy); } catch { policy = null; } }
    if (liveEnabled) {
      assert.equal(enabledFor(runtime.IMAGE_LEGACY_BRAND_POLICY, id), true);
      assert.equal(policy.audience, 'all');
      check('live Logo planning is enabled for existing members; verifier changed no runtime policy');
    } else {
      assert.notEqual(policy?.enabled, true, 'use --live-enabled when the feature has been opened');
      assert.equal(enabledFor(runtime.IMAGE_LEGACY_BRAND_POLICY, id), false);
      check('new Logo planning remains closed; no runtime policy was changed');
    }
    const health = await request('/api/health'); assert.equal(health.value.ok, true); check('existing health endpoint');
    const models = await request('/img/models'); assert.equal(models.value.routingMode, 'auto'); assert.equal(models.value.autoPolicy.defaultTier, 'fast'); check('Flash-first auto policy remains unchanged');
    const password = crypto.randomBytes(24).toString('hex'), salt = crypto.randomBytes(16).toString('hex'), now = new Date();
    await account.set({ username, displayName: '旧包兼容临时验证', tier: 'ultra', status: 'active', expiresAt: new Date(Date.now() + 3600000), createdAt: now, cycleAnchorAt: now,
      quotaOverrideCny: 20, passwordHash: 'scrypt$' + salt + '$' + crypto.scryptSync(password, salt, 64).toString('hex'), pwv: 0, sv: 0, chatUsedCny: 0, imageUsedCny: 0, failedAttempts: 0, lockUntil: null });
    created = true; token = (await request('/api/login', { username, password })).value.token; assert.ok(token);
    const me = (await request('/api/me')).value; assert.ok(me.appBehavior); assert.ok(me.appBehavior.imageTimeout >= 300);
    assert.ok(!Object.hasOwn(me.appBehavior, 'imageLegacyBrandPolicy')); check('legacy login and /me config shapes; private policy not sent to phone');
    const basic = await request('/api/chat', { chatMode: 'standard', stream: false, max_tokens: 120,
      messages: [{ role: 'user', content: '这是一条连通性检查，请只回复：连接正常。' }] });
    assert.ok(basic.value.choices?.[0]?.message?.content); check('ordinary legacy non-stream chat', { ms: basic.ms });

    const logo = png(128, 128, (x, y) => (x > 20 && x < 108 && y > 20 && y < 108 && (x < 42 || y > 86)) ? [20, 110, 70] : [255, 255, 255]);
    const base = png(480, 640, (x, y) => (x > 110 && x < 400 && y > 220 && y < 260) ? [25, 40, 90] : [245, 245, 242]);
    const input = [{ role: 'system', content: '只使用已开放工具；原图和Logo均为合成测试夹具，不涉及客户图片。' },
      { role: 'assistant', content: '刚才的海报已生成。' }, { role: 'user', content: [
        { type: 'text', text: '在你刚生成的海报左上角加上我们的Logo，不动其他版式，不覆盖原内容。上传附件1是Logo。' },
        { type: 'image_url', image_url: { url: logo } },
        { type: 'text', text: '【本次编辑前生成图预览】这是底图预览，不是用户附件，不计入source_index。both时为第1张底图。' },
        { type: 'image_url', image_url: { url: base } }] }];
    // Live mode sends the unmodified phone-style request, exercising server-side
    // admission and injection instead of manually adding guidance to the probe.
    const planned = liveEnabled ? input : injectLegacyBrandGuidance({ messages: input, tools: [editTool], policy: { enabled: true, accountIds: [id] }, accountId: id });
    assert.equal(planned.length, input.length + (liveEnabled ? 0 : 1));
    for (const stream of [false, true]) {
      const response = await request('/api/chat', { chatMode: 'standard', stream, max_tokens: 1800, messages: planned,
        tools: [editTool], tool_choice: { type: 'function', function: { name: 'image_edit' } } });
      let calls = response.value.choices?.[0]?.message?.tool_calls || [];
      if (stream) for (const line of String(response.value.raw || '').split('\n')) {
        if (!line.startsWith('data: ') || line === 'data: [DONE]') continue;
        const frame = JSON.parse(line.slice(6)); assert.ok(!frame.error);
        for (const choice of frame.choices || []) calls.push(...(choice.delta?.tool_calls || []));
      }
      if (calls.length !== 1) {
        report.unexpectedCalls = calls.map(call => {
          let args; try { args = JSON.parse(call.function.arguments); } catch { args = {}; }
          return { name: call.function.name, source: args.source, sourceIndex: args.source_index,
            sourceIndexes: args.source_indexes, placements: args.structured?.preserve_assets, visibleTextCount: args.structured?.text?.length };
        });
        console.log(JSON.stringify({ unexpectedCalls: report.unexpectedCalls }));
      }
      assert.equal(calls.length, 1); const args = JSON.parse(calls[0].function.arguments), fields = args.structured;
      const plannedFields = { stream, tool: calls[0].function.name, source: args.source, sourceIndex: args.source_index,
        sourceIndexes: args.source_indexes, assets: fields?.preserve_assets, preserveOutside: fields?.preserve_outside,
        textCount: fields?.text?.length };
      report.planningOutputs = [...(report.planningOutputs || []), plannedFields];
      console.log(JSON.stringify({ plannedFields }));
      assert.equal(calls[0].function.name, 'image_edit'); assert.equal(args.source, 'both');
      assert.equal(args.source_indexes, undefined); assert.equal(args.reference_roles, undefined);
      assert.equal(args.source_index ?? 1, 1); assert.equal(fields.preserve_outside, true); assert.deepEqual(fields.text, []);
      assert.equal(fields.preserve_assets.length, 1); const asset = fields.preserve_assets[0]; assert.equal(asset.reference_index, 2); assert.equal(asset.kind, 'logo');
      const b = asset.box; assert.ok(['x', 'y', 'width', 'height'].every(k => typeof b[k] === 'number' && Number.isFinite(b[k])));
      assert.ok(b.x >= 0 && b.y >= 0 && b.width > 0 && b.height > 0 && b.x + b.width <= 1 && b.y + b.height <= 1 && b.width * b.height <= 0.35);
      check(stream ? 'Logo guidance: real SSE, old-package executable fields' : 'Logo guidance: real JSON, old-package executable fields',
        { ms: response.ms, syntheticOnly: true, serverInjected: liveEnabled, box: b });
    }
    const after = (await account.get()).data[0]; assert.equal(after.imageUsedCny, 0); check('planning made zero image-model calls');
    report.ok = true;
  } catch (error) { report.ok = false; report.error = String(error.message || error).replace(/https?:\/\/\S+/g, '[url]').slice(0, 250);
    report.errorLocation = String(error.stack || '').split('\n').find(line => line.includes('verify-legacy-image-compat.cjs:'))?.trim(); throw error; }
  finally {
    if (created) { assert.ok(id.startsWith('legacy-compat-')); await account.remove(); report.temporaryAccountDeleted = true; }
    fs.writeFileSync(path.join(root, 'outputs/legacy-image-compat-verification.json'), JSON.stringify(report, null, 2));
    fs.writeFileSync(path.join(root, 'outputs/legacy-image-compat-' + report.at.replace(/[:.]/g, '-') + '.json'), JSON.stringify(report, null, 2));
  }
})().catch(error => { console.error(String(error.message || error).replace(/https?:\/\/\S+/g, '[url]').slice(0, 250)); process.exitCode = 1; });
