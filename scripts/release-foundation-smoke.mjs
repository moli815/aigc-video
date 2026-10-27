// Run only against the dedicated temporary release account; credentials stay in TEMP.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
const {imageInfo} = createRequire(import.meta.url)('../cloudfunctions/shared/asset-store.js');
const account = JSON.parse(fs.readFileSync(path.join(process.env.TEMP, 'bossai-release-canary.json'), 'utf8'));
assert.match(account.id, /^release-20261027-/);
const host = 'https://xmy-test-d5g8c0xcifcefcfd5-1449098021.ap-shanghai.app.tcloudbase.com';
const checks = [];
async function call(route, body, method = body === undefined ? 'GET' : 'POST', expected = 200) {
  const response = await fetch(host + '/api' + route, {method,
    headers: {Authorization: 'Bearer ' + account.token, 'Content-Type': 'application/json'},
    body: body === undefined ? undefined : JSON.stringify(body)});
  const data = await response.json();
  assert.equal(response.status, expected, `${route}: ${response.status}, ${data.error?.code || data.error || data.code}`);
  return data;
}
try {
  const initial = await call('/sync/v2/pull');
  const bytes = fs.readFileSync('outputs/release-native-pro-poster.png');
  const sha256 = crypto.createHash('sha256').update(bytes).digest('hex');
  const prepared = await call('/assets/prepare', {sha256, byteCount: bytes.length, mime: imageInfo(bytes).mime});
  assert.equal(prepared.ready, true); // Previously uploaded through the real signed PUT protocol.
  const asset = prepared.asset;
  const signed = await call('/assets/urls', {ids: [asset.id]});
  const restored = await fetch(signed.items[0].url);
  assert.equal(restored.status, 200);
  assert.equal(crypto.createHash('sha256').update(Buffer.from(await restored.arrayBuffer())).digest('hex'), sha256);
  checks.push('cloud image restore: exact SHA-256; content-addressed dedup');
  const cid = crypto.randomUUID().toUpperCase(), mid = crypto.randomUUID().toUpperCase();
  const rec = (kind, refId, data, baseVersion = 0) => ({kind, refId, payload: {id: refId, ...data}, baseVersion});
  const records = [rec('conversation', cid, {title:'release smoke'}), rec('message', mid, {conversationId:cid, text:'image restore', assets:[asset]})];
  const pushed = await call('/sync/v2/push', {records});
  assert.equal(pushed.acknowledged.length, 2);
  const replay = await call('/sync/v2/push', {records});
  assert.equal(replay.revision, pushed.revision);
  checks.push('transaction revisions monotonic; identical replay does not increment');
  const first = await call(`/sync/v2/pull?since=${initial.watermark}&limit=1`);
  assert.equal(first.items.length, 1); assert.equal(first.hasMore, true);
  const second = await call(`/sync/v2/pull?since=${initial.watermark}&watermark=${first.watermark}&after=${first.after}&limit=1`);
  assert.equal(second.items[0].refId, mid);
  assert.equal(JSON.parse(second.items[0].payload).assets[0].sha256, sha256);
  const stale = await call('/sync/v2/push', {records:[rec('message',mid,{conversationId:cid,text:'stale'})]});
  assert.equal(stale.conflicts.length,1); assert.equal(stale.revision,pushed.revision);
  checks.push('pinned-watermark pagination and stale-device conflict preservation');
  await call('/sync/conversations/'+cid, {}, 'DELETE');
  const late = await call('/sync/v2/push',{records:[rec('message',crypto.randomUUID().toUpperCase(),{conversationId:cid,text:'late'})]});
  assert.equal(late.acknowledged[0].discarded,'parent_deleted');
  const deleted = await call(`/sync/v2/pull?since=${pushed.revision}`);
  assert.ok(deleted.items.some(x=>x.refId===cid && x.deleted));
  checks.push('conversation tombstone blocks late child resurrection');
  const eventId = 'release_'+crypto.randomUUID().replaceAll('-','');
  const events=[{eventId,requestId:mid,domain:'release',stage:'save',prompt:'must_drop',token:'must_drop'}];
  assert.deepEqual((await call('/events',{events})).acceptedIds,[eventId]);
  assert.deepEqual((await call('/events',{events})).acceptedIds,[eventId]);
  const bad=await call('/sync/v2/push',{records:[{kind:'message',refId:'invalid',payload:{}}]},'POST',422);
  assert.equal(bad.error,'CLOUD_INPUT_INVALID');
  checks.push('durable event acknowledgement; stable public input error');
  fs.writeFileSync('outputs/release-foundation-smoke.json',JSON.stringify({ok:true,at:new Date().toISOString(),checks,eventId,accountId:account.id,sha256},null,2));
  console.log(JSON.stringify({ok:true,checks}));
} catch(error) {
  fs.writeFileSync('outputs/release-foundation-smoke.json',JSON.stringify({ok:false,at:new Date().toISOString(),checks,error:error.message},null,2));
  console.error(error.message); process.exitCode=1;
}
