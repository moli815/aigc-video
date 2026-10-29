// Change one non-secret runtime field; preserve billing, model IDs and customer data.
const fs = require('node:fs'), path = require('node:path'), assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const sdk = require(path.join(root, 'cloudfunctions/bf-api/node_modules/@cloudbase/node-sdk'));
const credential = JSON.parse(fs.readFileSync(path.join(process.env.USERPROFILE, '.config/.cloudbase/auth.json'), 'utf8')).credential;
const db = sdk.init({env:'xmy-test-d5g8c0xcifcefcfd5',region:'ap-shanghai',secretId:credential.tmpSecretId,
  secretKey:credential.tmpSecretKey,sessionToken:credential.tmpToken}).database();
const key = 'IMAGE_AUTO_POLICY', file = path.join(root, 'outputs/image-auto-quality-policy-rollout.json');
const mode = process.argv[2], candidate = JSON.stringify(require('../config/image-auto-quality-balanced.json'));
assert.ok(['--plan','--apply','--rollback'].includes(mode), 'expected --plan, --apply or --rollback');
function docOf(result) { return Array.isArray(result.data) ? result.data[0] : result.data; }
(async () => {
  if (mode === '--plan') {
    const current = docOf(await db.collection('bf_config').doc('runtime').get());
    assert.equal(current.data.IMAGE_ROUTING_MODE, 'auto', 'do not override operational routing modes');
    const report = {at:new Date().toISOString(),key,before:current.data[key] ?? null,after:candidate,revisionBefore:current.revision};
    fs.writeFileSync(file, JSON.stringify(report, null, 2)); console.log(JSON.stringify(report)); return;
  }
  const plan = JSON.parse(fs.readFileSync(file, 'utf8')); assert.equal(plan.key, key); assert.equal(plan.after, candidate);
  const expected = mode === '--apply' ? plan.before : plan.after;
  const replacement = mode === '--apply' ? plan.after : (plan.before ?? '{}');
  const result = await db.runTransaction(async tx => {
    const ref = tx.collection('bf_config').doc('runtime'), current = docOf(await ref.get());
    assert.equal(current.data.IMAGE_ROUTING_MODE, 'auto');
    assert.equal(current.data[key] ?? null, expected, 'runtime policy changed since plan; do not overwrite another operator');
    const now = new Date(), revision = String(now.getTime());
    await ref.update({['data.' + key]:replacement, revision, updatedAt:now,
      editLog:[{at:now,changes:[key+': balanced quality '+(mode === '--apply'?'enabled':'rolled back')]},...(current.editLog || [])].slice(0,20)});
    return {revision,at:now.toISOString()};
  });
  const readback = docOf(await db.collection('bf_config').doc('runtime').get());
  assert.equal(readback.data[key], replacement);
  const report = {...plan,[mode === '--apply'?'applied':'rolledBack']:{...result,readbackVerified:true}};
  fs.writeFileSync(file, JSON.stringify(report,null,2)); console.log(JSON.stringify(report));
})().catch(error => {console.error(String(error.message || error).replace(/https?:\/\/\S+/g,'[url]').slice(0,220));process.exitCode=1;});
