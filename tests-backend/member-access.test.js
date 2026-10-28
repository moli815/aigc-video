const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { membershipExpired } = require('../cloudfunctions/bf-api/domains/member-access');
const { publicError } = require('../cloudfunctions/shared/error-catalog');

test('membership: missing, malformed and exact expiry all deny; a valid future allows', () => {
  const now = Date.parse('2026-10-28T04:00:00Z');
  for (const value of [null, undefined, '', false, true, {}, [], 'not-a-date', new Date(NaN), now - 1, now]) {
    assert.equal(membershipExpired(value, now), true, String(value));
  }
  for (const value of [now + 1, new Date(now + 1), new Date(now + 1).toISOString()]) {
    assert.equal(membershipExpired(value, now), false);
  }
});

test('membership: login, token guard and chat recheck all use the expiry policy', () => {
  const src = fs.readFileSync(require.resolve('../cloudfunctions/bf-api/index.js'), 'utf8');
  assert.equal((src.match(/if \(membershipExpired\((?:acc|account)\.expiresAt/g) || []).length, 3);
});

test('quota exhaustion is actionable billing, not retryable internal failure', () => {
  const envelope = publicError('POOL_EXHAUSTED', { requestId: 'quota-check' });
  assert.equal(envelope.error, 'POOL_EXHAUSTED');
  assert.equal(envelope.errorDetail.category, 'billing');
  assert.equal(envelope.errorDetail.retryable, false);
  assert.deepEqual(envelope.actions, ['view_quota', 'renew']);
});

const image = fs.readFileSync(require.resolve('../cloudfunctions/bf-image/index.js'), 'utf8');
const quotaFn = image.slice(image.indexOf('async function quotaExhausted'), image.indexOf('/** 会员侧拒绝'));
async function quota(body, status = 200, reserved = 0) {
  const context = { AbortController, setTimeout, clearTimeout, BF_API_BASE: 'https://example.invalid',
    bearer: () => 'test', authSubOf: () => 'canary', logStage: () => {},
    activeReservedCny: async () => reserved,
    fetch: async () => ({ ok: status === 200, status, json: async () => body }) };
  vm.runInNewContext(quotaFn, context);
  return context.quotaExhausted({});
}
const snapshot = (used = 0, pct = 100) => ({ ok: true, limits: { month: { enabled: true, remainingPct: pct } },
  usage: { pool: { capCny: 10, usedCny: used } } });

test('image quota: expired and suspended pass through; network service failure stays closed', async () => {
  for (const code of ['MEMBERSHIP_EXPIRED', 'ACCOUNT_SUSPENDED']) {
    const result = await quota({ error: code, message: '会员暂不可用' }, 403);
    assert.equal(result.denied, 403); assert.equal(result.code, code);
  }
  assert.equal((await quota({}, 503)).unavailable, true);
});

test('image quota: full pool/reservations deny, remaining budget allows', async () => {
  assert.equal((await quota(snapshot(10, 0))).exhausted, true);
  assert.equal((await quota(snapshot(9.99, 0))).exhausted, true);
  assert.equal((await quota(snapshot(9, 10), 200, 1)).exhausted, true);
  assert.equal((await quota(snapshot(1, 90))).exhausted, false);
});

test('image quota: malformed cost/percentage response cannot permit free generation', async () => {
  for (const body of [{}, {ok: false}, snapshot(NaN), snapshot(-1), snapshot(0, NaN),
                      { ...snapshot(), usage: {pool: {capCny: 0, usedCny: 0}} }]) {
    const result = await quota(body);
    assert.equal(result.exhausted, true); assert.equal(result.unavailable, true);
  }
});
