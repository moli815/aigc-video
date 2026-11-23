"use strict";
const test=require('node:test'),assert=require('node:assert/strict'),{publicError}=require('../cloudfunctions/shared/error-catalog');
test('failed image text acceptance cannot suggest replaying the same terminal job',()=>{
 const r=publicError('IMAGE_TEXT_REVIEW_REQUIRED');assert.equal(r.error,'IMAGE_TEXT_REVIEW_REQUIRED');assert.equal(r.errorDetail.retryable,false);assert.equal(r.errorDetail.category,'input');assert.ok(!r.actions.includes('retry'));assert.ok(r.actions.includes('edit_request'));
});
test('unavailable preflight keeps a distinct retryable code without claiming a rejected image',()=>{
 const r=publicError('IMAGE_TEXT_REVIEW_UNAVAILABLE');assert.equal(r.errorDetail.retryable,true);assert.deepEqual(r.actions,['retry']);assert.match(r.message,/尚未生成或扣费/);
});
