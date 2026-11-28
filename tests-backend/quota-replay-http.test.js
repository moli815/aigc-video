'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const { harness } = require('./reference-http-fixture.cjs');

const input = { requestId: 'stable-mobile-turn', prompt: '制作设备接入示意图', size: '1536x1536' };
function rejectSpending(h) {
  vm.runInContext('quotaExhausted = async () => ({ exhausted: true })', h.context);
}

test('a member can retrieve the completed image after spending the final balance', async () => {
  const h = await harness();
  const first = await h.request('/image', input);
  assert.equal(first.status, 200);
  rejectSpending(h);
  const retry = await h.request('/image', input);
  assert.equal(retry.status, 200);
  assert.equal(retry.body.cached, true);
  assert.equal(retry.body.cost, 0);
  assert.equal(retry.body.url, first.body.url);
  const fresh = await h.request('/image', { ...input, requestId: 'another-turn' });
  assert.equal(fresh.body.error, 'POOL_EXHAUSTED');
  assert.equal((await h.db.collection('bf_image_jobs').get()).data.length, 1);
  assert.equal(h.calls.length, 1);
  assert.equal(h.charges.length, 1);
});

test('a reserved group can be recovered without reserving again', async () => {
  const h = await harness();
  const body = { ...input, requested_count: 2 };
  const first = await h.request('/series/start', body);
  assert.equal(first.status, 200);
  rejectSpending(h);
  const replay = await h.request('/series/start', body);
  assert.equal(replay.status, 200);
  assert.equal(replay.body.taskId, first.body.taskId);
  assert.equal(replay.body.idempotent, true);
  assert.equal((await h.request('/series/start', { ...body, requestId: 'new-group' })).body.error, 'POOL_EXHAUSTED');
  assert.equal(h.reservations.length, 1);
  assert.equal(h.calls.length, 0);
});

test('quota-only recovery cannot resume a failed or partially prepared paid job', async () => {
  const h = await harness();
  h.failNext();
  assert.equal((await h.request('/image', input)).status, 502);
  rejectSpending(h);
  const job = (await h.db.collection('bf_image_jobs').get()).data[0];
  const ref = h.db.collection('bf_image_jobs').doc(job._id);
  assert.equal((await h.request('/image', input)).body.error, 'POOL_EXHAUSTED');
  assert.equal((await ref.get()).data[0].state, 'failed');
  await ref.update({ state: 'processing' });
  assert.equal((await h.request('/image', input)).body.error, 'IN_PROGRESS');
  assert.equal(h.calls.length, 1);
  assert.equal(h.charges.length, 0);
});

test('a denied membership or unavailable quota never returns an image on replay', async () => {
  const h = await harness();
  assert.equal((await h.request('/image', input)).status, 200);
  for (const [quota, status] of [[{ denied: 403 }, 403], [{ unavailable: true }, 503]]) {
    vm.runInContext('quotaExhausted = async () => (' + JSON.stringify(quota) + ')', h.context);
    assert.equal((await h.request('/image', input)).status, status);
  }
  assert.equal(h.calls.length, 1);
});

function observeTextReview(h) {
  const original = h.context.require;
  let reads = 0;
  h.context.require = name => {
    const mod = original(name);
    if (name !== './shared/number-audit') return mod;
    return { ...mod, transcribe: async () => (++reads === 1 ? '读取到正文' : '记录海报') };
  };
  vm.runInContext("nativeVisionConfig = async () => ({}); RT.STRUCT_AUDIT_MODE = 'on'", h.context);
  return () => reads;
}

test('a text review cannot render a second version after the first was saved and charged', async () => {
  const h = await harness();
  const reads = observeTextReview(h);
  const poster = { ...input, prompt: '制作海报，主标题「记录海报」' };
  const first = await h.request('/image', poster);
  const second = await h.request('/image', poster);
  assert.equal(first.status, 200);
  assert.equal(second.body.url, first.body.url);
  assert.equal(h.calls.length, 1);
  assert.equal(h.charges.length, 1);
  assert.equal(reads(), 1);
});

test('an illustration with no text to validate skips the transcription call', async () => {
  const h = await harness();
  const reads = observeTextReview(h);
  assert.equal((await h.request('/image', { ...input, prompt: '雨中的花园插画' })).status, 200);
  assert.equal(reads(), 0);
});

test('a funded series consumes its own active reservation at the spending limit', async () => {
  const h = await harness();
  const group = await h.request('/series/start', { ...input, requested_count: 2 });
  const taskId = group.body.taskId;
  assert.equal(group.status, 200);
  const cap = h.reservations[0].cost;
  await h.db.collection('bf_accounts').doc('A').set({status:'active', imageBudgetReservedCny:cap});
  await h.db.collection('bf_quota_reservations').doc(taskId).set({accountId:'A', state:'active', kind:'image_budget', amountCny:cap});
  vm.runInContext(`RT.IMAGE_PRICE_MULTIPLIER = 1; quotaExhausted = async () => {
    const ctx = reqStore.getStore(); ctx.quotaCapCny = ${cap};
    const held = await activeReservedCny('A', false, ctx.excludedReservationId);
    return {exhausted: held >= ${cap}, capCny:${cap}, remainingCny: ${cap} - held};
  }`, h.context);
  const step = await h.request('/series/step', {taskId, index:1});
  assert.equal(step.status, 200);
  assert.equal(step.body.succeeded, 1);
  assert.equal(h.calls.length, 1);
  const holds = (await h.db.collection('bf_quota_reservations').where({accountId:'A',state:'active'}).get()).data;
  assert.equal(holds.length, 2);
  assert.equal(holds.reduce((n,r) => n+r.amountCny, 0), cap);
});
