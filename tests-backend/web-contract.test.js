"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const root = path.join(__dirname, "..");
const admin = fs.readFileSync(path.join(root, "web/admin.html"), "utf8");
const staff = fs.readFileSync(path.join(root, "web/staff.html"), "utf8");

function between(source, start, end) { return source.slice(source.indexOf(start), source.indexOf(end)); }
function escFunction() { return admin.slice(admin.indexOf("function esc("), admin.indexOf("function toast(")); }

test("multiline starter editor preserves content byte-for-byte through collection", () => {
  const source = escFunction() + between(admin, "function starterRowHtml", "function collectExpViz") + "\nthis.helpers={starterRowHtml,collectStarters};";
  const context = {};
  vm.runInNewContext(source, context);
  const original = "第一行\n第二行｜含分隔符\n第三行 \"引号\"";
  const row = {
    querySelector(selector) {
      if (selector === "[data-starter-label]") return { value: "多行标签" };
      if (selector === "[data-starter-content]") return { value: original };
      throw new Error("unexpected selector");
    },
  };
  const card = { querySelectorAll: selector => selector === "[data-starter-row]" ? [row] : [] };
  const collected = context.helpers.collectStarters(card);
  assert.equal(collected.length, 1);
  assert.equal(collected[0].content, original);
  const html = context.helpers.starterRowHtml(collected[0]);
  assert.match(html, /多行标签/);
  assert.match(html, /第一行\n第二行｜含分隔符/);
  assert.doesNotMatch(html, /line\.split\(/);
});

test("notification opens only its linked delivery and never uses the latest unrelated password", async () => {
  const source = escFunction() + between(staff, "function openNotif", "function copyReady") + "\nthis.open=openNotif;";
  const ready = { innerHTML: "" };
  const calls = [];
  const context = {
    NOTIFS: [{ _id: "n1", type: "account_ready", refDeliveryId: "dlv_A" }],
    READY_DLY: null,
    q: () => ready,
    openM: () => {},
    api: url => {
      calls.push(url);
      if (url === "/admin/deliveries") return Promise.resolve({ list: [
        { id: "dlv_B", username: "b", password: "B_PASSWORD" },
        { id: "dlv_A", username: "a", password: "A_PASSWORD" },
      ] });
      return Promise.resolve({});
    },
    loadNotifs: () => {}, refreshAll: () => {}, fmtTime: () => "time",
  };
  vm.runInNewContext(source, context);
  context.open("n1");
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(context.READY_DLY.id, "dlv_A");
  assert.match(ready.innerHTML, /A_PASSWORD/);
  assert.doesNotMatch(ready.innerHTML, /B_PASSWORD/);
});

test("non-account and legacy unlinked notifications fail closed without password lookup", () => {
  const source = escFunction() + between(staff, "function openNotif", "function copyReady") + "\nthis.open=openNotif;";
  for (const notice of [
    { _id: "renew", type: "renew_ready", title: "续费完成", body: "已续费" },
    { _id: "old", type: "account_ready", title: "旧通知" },
  ]) {
    let deliveryCalled = false;
    const ready = { innerHTML: "" };
    const context = {
      NOTIFS: [notice], READY_DLY: null, q: () => ready, openM: () => {},
      api: url => { if (url === "/admin/deliveries") deliveryCalled = true; return Promise.resolve({}); },
      loadNotifs: () => {}, refreshAll: () => {},
    };
    vm.runInNewContext(source, context);
    context.open(notice._id);
    assert.equal(context.READY_DLY, null);
    assert.equal(deliveryCalled, false);
    assert.doesNotMatch(ready.innerHTML, /登录密码/);
  }
});

test("dynamic names no longer enter inline handlers and staff result follows instant", () => {
  assert.doesNotMatch(admin, /onclick="(?:viewStaffPwd|askDisableStaff)\(/);
  assert.doesNotMatch(staff, /onclick="renewFor\(/);
  assert.match(admin, /data-staff-act="pwd"/);
  assert.match(staff, /data-renew-id/);
  assert.match(staff, /j\.instant === true/);
  assert.doesNotMatch(staff, /已立即生效|已立即开通/);
  assert.match(admin, /payload\.expectedRevision=EXP_OBJ\.catalogRevision\|\|EXP_OBJ\.version/);
});
