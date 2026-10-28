// Changes one non-secret runtime key using the existing management login.
// Does not change model routes, customer membership or any client configuration.
const fs = require('node:fs'), path = require('node:path'), assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const sdk = require(path.join(root, 'cloudfunctions/bf-api/node_modules/@cloudbase/node-sdk'));
const credential = JSON.parse(fs.readFileSync(path.join(process.env.USERPROFILE, '.config/.cloudbase/auth.json'), 'utf8')).credential;
const app = sdk.init({ env: 'xmy-test-d5g8c0xcifcefcfd5', region: 'ap-shanghai', secretId: credential.tmpSecretId,
  secretKey: credential.tmpSecretKey, sessionToken: credential.tmpToken });
const db = app.database(), key = 'IMAGE_LEGACY_BRAND_POLICY';
const action = process.argv[2];
assert.ok(['--enable', '--disable'].includes(action), 'expected explicit --enable or --disable');
const value = JSON.stringify(action === '--enable' ? { enabled: true, audience: 'all' } : { enabled: false });
(async () => {
  const changed = await db.runTransaction(async tx => {
    const ref = tx.collection('bf_config').doc('runtime');
    const response = await ref.get();
    const current = Array.isArray(response.data) ? response.data[0] : response.data; assert.ok(current?.data);
    const before = current.data[key] ?? null;
    if (before === value) return { changed: false, before, after: value, revision: current.revision };
    const now = new Date(), revision = String(now.getTime());
    await ref.update({ ['data.' + key]: value, revision, updatedAt: now,
      editLog: [{ at: now, changes: [key + ': ' + (before || 'builtin-off') + ' → ' + value] }, ...(current.editLog || [])].slice(0, 20) });
    return { changed: true, before, after: value, revision };
  });
  const readback = (await db.collection('bf_config').doc('runtime').get()).data[0];
  assert.equal(readback.data[key], value);
  const report = { at: new Date().toISOString(), key, ...changed, readbackVerified: true };
  fs.writeFileSync(path.join(root, 'outputs/legacy-brand-rollout.json'), JSON.stringify(report, null, 2));
  console.log(JSON.stringify(report));
})().catch(error => { console.error(String(error.message || error).replace(/https?:\/\/\S+/g, '[url]').slice(0, 200)); process.exitCode = 1; });
