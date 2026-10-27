// ============================================================================
// DELETE /sync/conversations/:id —— 行为级测试（10-25）
//
// 为什么要这一层：契约测试只能证明"代码里写了 403"，证明不了"这条分支真的按预期走"。
// 而 403 分支在真实环境**几乎构造不出来**（查询条件永远绑 accountId，别人的行根本查不到），
// 所以这里把 index.js 里的真实处理器源码取出来，配一个内存假 DB 直接跑：
//   · 跑的是**线上同一份代码**（不是副本、不是重写）；
//   · 断言的是状态机行为：401/400/403/200/幂等/重放/并发撞车。
// ============================================================================

const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");

const ROOT = path.resolve(__dirname, "..");
const API = fs.readFileSync(path.join(ROOT, "cloudfunctions/bf-api/index.js"), "utf8");

function handlerSource() {
  const start = API.indexOf("async function handleSyncDeleteConversation");
  const end = API.indexOf("/** GET /sync/pull", start);
  assert.ok(start > 0 && end > start, "未能从 index.js 中定位 DELETE 处理器");
  return API.slice(start, end);
}

const UUID_A = "11111111-1111-4111-8111-111111111111";
const UUID_B = "22222222-2222-4222-8222-222222222222";

const detIdOf = (accountId, kind, refId) =>
  crypto.createHash("sha256").update(String(accountId) + "|" + kind + "|" + refId).digest("hex").slice(0, 40);

/** 造一个内存版 db + 捕获式 res，然后返回"跑真实处理器"的函数 */
function makeHarness({ rows = [], accountId = "acct-A", requestId = "rid-1", addThrows = false, getSequence = null } = {}) {
  let seqIndex = 0;
  const store = new Map();   // _id -> row
  for (const row of rows) store.set(row._id, { ...row });

  const captured = { json: [], errors: [], audits: [], logs: [] };

  const db = {
    collection() {
      return {
        doc(id) {
          return {
            get: async () => {
              // getSequence：按顺序返回指定结果（模拟"查询时还没有 / 并发写入后读回已有"）
              if (getSequence) {
                const next = seqIndex < getSequence.length ? getSequence[seqIndex++] : null;
                return { data: next ? [{ ...next }] : [] };
              }
              return { data: store.has(id) ? [{ ...store.get(id) }] : [] };
            },
            update: async (patch) => { if (store.has(id)) store.set(id, { ...store.get(id), ...patch }); },
            remove: async () => { store.delete(id); },
          };
        },
        where(cond) {
          return {
            limit() {
              return {
                get: async () => ({
                  data: [...store.values()].filter((r) =>
                    r.accountId === cond.accountId && r.kind === cond.kind && r.refId === cond.refId
                  ).map((r) => ({ ...r })),
                }),
              };
            },
          };
        },
        add: async (doc) => {
          if (addThrows) { const e = new Error("duplicate key"); e.name = "DupKey"; throw e; }
          store.set(doc._id, { ...doc });
          return { id: doc._id };
        },
      };
    },
  };

  const sendJson = (res, code, data) => {
    captured.json.push({ code, data });
    res.statusCode = code;
    res.body = data;
  };
  const sendError = (res, code, error, message) => {
    captured.errors.push({ code, error, message });
    res.statusCode = code;
    res.body = { error, message };
  };

  const factory = new Function(
    "db", "C", "crypto", "requireMember", "sendJson", "sendError", "nowMs",
    "currentRequestId", "logSafe", "tagId", "maskText", "auditLog", "syncV2",
    handlerSource() + "\nreturn handleSyncDeleteConversation;"
  );

  const handler = factory(
    db,
    { userData: "bf_user_data", audit: "bf_audit_logs" },
    crypto,
    async (req, res) => {   // requireMember 桩：accountId = null 表示未登录
      if (!accountId) { sendError(res, 401, "UNAUTHORIZED", "请重新登录"); return null; }
      return { sub: accountId, t: "member" };
    },
    sendJson,
    sendError,
    () => 1_800_000_000_000,
    () => requestId,
    (obj) => captured.logs.push(obj),
    (id) => "acct_x",
    (text) => String(text).slice(0, 8),
    async (actor, action, extra) => { captured.audits.push({ actor, action, extra }); },
    { async deleteConversation(owner, id) { captured.v2Delete = { owner, id }; } }
  );

  const run = async (refId) => {
    const res = {};
    await handler({}, res, refId);
    return { res, captured, store };
  };
  return { run, store, captured };
}

test("BE-01 未登录：401，且不写任何数据", async () => {
  const h = makeHarness({ accountId: null });
  const { res, captured, store } = await h.run(UUID_A);
  assert.equal(res.statusCode, 401);
  assert.equal(captured.errors[0].error, "UNAUTHORIZED");
  assert.equal(store.size, 0);
});

test("BE-02 非法 id：400 BAD_ID，且不写任何数据", async () => {
  const h = makeHarness();
  const { res, store } = await h.run("not-a-uuid");
  assert.equal(res.statusCode, 400);
  assert.equal(res.body.error, "BAD_ID");
  assert.equal(store.size, 0);
});

test("BE-03 自己的会话：200 + 墓碑（deleted=true、payload.isDeleted=true、消息不再留存）", async () => {
  const refId = UUID_A;
  const detId = detIdOf("acct-A", "conversation", refId);
  const payload = JSON.stringify({ id: refId, title: "机密标题", messages: [{ text: "机密正文" }, { text: "第二段" }] });
  const h = makeHarness({
    rows: [{ _id: detId, accountId: "acct-A", kind: "conversation", refId, payload, updatedAt: 1, deleted: false }],
  });
  const { res, store, captured } = await h.run(refId);

  assert.equal(res.statusCode, 200);
  assert.equal(res.body.ok, true);
  assert.equal(res.body.alreadyDeleted, false);
  const row = store.get(detId);
  assert.equal(row.deleted, true, "必须写行级墓碑");
  assert.equal(JSON.parse(row.payload).isDeleted, true, "payload 必须是墓碑");
  assert.ok(!row.payload.includes("机密正文"), "消息正文不得留在云端");
  assert.ok(!JSON.stringify(res.body).includes("机密"), "响应不得回显内容");

  // 审计：只记数量与结果，不记正文
  assert.equal(captured.audits.length, 1);
  assert.equal(captured.audits[0].action, "conversation_delete");
  assert.equal(captured.audits[0].extra.result, "tombstoned");
  assert.equal(captured.audits[0].extra.messagesRemoved, 2);
  assert.ok(!JSON.stringify(captured.audits).includes("机密正文"));
});

test("BE-04 重复删除：第二次 200 且 alreadyDeleted=true（幂等）", async () => {
  const refId = UUID_A;
  const h = makeHarness();
  await h.run(refId);
  const { res } = await h.run(refId);
  assert.equal(res.statusCode, 200);
  assert.equal(res.body.alreadyDeleted, true);
});

test("BE-05 云端从来没有这条：补写墓碑 + 200 幂等", async () => {
  const h = makeHarness();
  const { res, store } = await h.run(UUID_A);
  assert.equal(res.statusCode, 200);
  assert.equal(res.body.alreadyDeleted, true);
  assert.equal(res.body.created, true);
  const row = [...store.values()][0];
  assert.equal(row.deleted, true);
  assert.equal(row.accountId, "acct-A");
});

test("BE-06 归属不符：403 FORBIDDEN，且**不改动**别人的行", async () => {
  const refId = UUID_B;
  // 模拟"查到了不属于当前账号的行"（数据异常/查询被放宽）：处理器必须拒绝
  const foreignRow = {
    _id: detIdOf("acct-A", "conversation", refId),   // 落到当前账号的确定性 _id 上
    accountId: "acct-OTHER", kind: "conversation", refId,
    payload: JSON.stringify({ id: refId, messages: [{ text: "别人的正文" }] }),
    updatedAt: 1, deleted: false,
  };
  const h = makeHarness({ rows: [foreignRow], accountId: "acct-A" });
  const { res, store } = await h.run(refId);

  assert.equal(res.statusCode, 403);
  assert.equal(res.body.error, "FORBIDDEN");
  const row = store.get(foreignRow._id);
  assert.equal(row.deleted, false, "别人的会话绝不能被标记删除");
  assert.ok(row.payload.includes("别人的正文"), "别人的数据不得被清空");
});

test("BE-07 跨账号删除的真实语义：A 删 B 的 id → A 侧幂等成功，B 的行毫发无损", async () => {
  const refIdB = UUID_B;
  const detIdB = detIdOf("acct-B", "conversation", refIdB);
  const bRow = {
    _id: detIdB, accountId: "acct-B", kind: "conversation", refId: refIdB,
    payload: JSON.stringify({ id: refIdB, messages: [{ text: "B 的正文" }] }), updatedAt: 1, deleted: false,
  };
  const h = makeHarness({ rows: [bRow], accountId: "acct-A" });
  const { res, store } = await h.run(refIdB);

  // 查询永远绑 accountId，所以 A 看不到 B 的行 → 按"自己没有这条"处理：幂等 200
  assert.equal(res.statusCode, 200);
  assert.equal(res.body.alreadyDeleted, true);
  const stillB = store.get(detIdB);
  assert.equal(stillB.deleted, false, "B 的会话不能被 A 删掉");
  assert.ok(stillB.payload.includes("B 的正文"));
});

test("BE-08 requestId 幂等：同一请求重放返回 replayed=true，不重复写审计", async () => {
  const refId = UUID_A;
  const detId = detIdOf("acct-A", "conversation", refId);
  const h = makeHarness({
    requestId: "same-rid",
    rows: [{
      _id: detId, accountId: "acct-A", kind: "conversation", refId,
      payload: JSON.stringify({ id: refId, messages: [{ text: "正文" }] }), updatedAt: 1, deleted: false,
    }],
  });

  const first = await h.run(refId);
  const second = await h.run(refId);

  assert.equal(first.res.body.alreadyDeleted, false);
  assert.equal(first.res.body.replayed, false);
  assert.equal(second.res.statusCode, 200);
  assert.equal(second.res.body.replayed, true, "同 requestId 必须走重放短路");
  const tombstoned = h.captured.audits.filter((a) => a.extra.result === "tombstoned");
  assert.equal(tombstoned.length, 1, "重放不得重复写审计");
});

test("BE-09 并发撞车（add 报重复键）：读回墓碑照常 200，读不回才 500", async () => {
  const refId = UUID_A;
  const detId = detIdOf("acct-A", "conversation", refId);
  const tombstoneRow = {
    _id: detId, accountId: "acct-A", kind: "conversation", refId,
    payload: JSON.stringify({ id: refId, isDeleted: true }), updatedAt: 1, deleted: true,
  };

  // ① 初次查询为空 → add 撞车 → 读回拿到墓碑：按幂等成功处理（created=false）
  const h1 = makeHarness({ addThrows: true, getSequence: [null, tombstoneRow] });
  const r1 = await h1.run(refId);
  assert.equal(r1.res.statusCode, 200);
  assert.equal(r1.res.body.alreadyDeleted, true);
  assert.equal(r1.res.body.created, false, "不是本次创建的，不能谎报 created");

  // ② 初次查询为空 → add 撞车 → 读回仍为空：必须明确 500，不能伪造成功
  const h2 = makeHarness({ addThrows: true, getSequence: [null, null] });
  const r2 = await h2.run(refId);
  assert.equal(r2.res.statusCode, 500);
  assert.equal(r2.res.body.error, "SYNC_FAILED");
});
