"use strict";
// 2026-11-22 回归：参考契约冲突必须收敛，不能中断整轮回复；素材超限必须给出可执行文案。
// 背景（线上 09:21 实例）：模型在 image_series 里同时填了 4 张历史原图和 source=attached，
// 旧实现抛 IMAGE_REFERENCE_CONFLICT → SSE 直接结束 → 用户看到「输出尚未完成」，一张图都没有。
const test = require("node:test");
const assert = require("node:assert/strict");
const path = require("path");

const ROOT = path.join(__dirname, "..");
const SERIES = path.join(ROOT, "worktree/bf-api-stage2/image-series-reference-guidance.js");
const STORE = path.join(ROOT, "worktree/bf-api-stage2/shared/asset-store.js");
const FOUNDATION = path.join(ROOT, "worktree/bf-api-stage2/domains/foundation.js");

const IDS = [
  "AAAAAAAA-1111-4111-8111-111111111111",
  "BBBBBBBB-2222-4222-8222-222222222222",
  "CCCCCCCC-3333-4333-8333-333333333333",
  "DDDDDDDD-4444-4444-8444-444444444444",
];

function messagesWithRecall() {
  return [
    { role: "user", content: "把这四张原图合成一组新品图" },
    {
      role: "assistant",
      content: "",
      tool_calls: [{ id: "call_recall", type: "function", function: { name: "recall_history", arguments: "{}" } }],
    },
    {
      role: "tool",
      tool_call_id: "call_recall",
      content: IDS.map((id, i) => `图片${i + 1}\n图片ID：${id}`).join("\n"),
    },
    { role: "user", content: [{ type: "image_url", image_url: { url: "data:image/jpeg;base64,AAAA" } }] },
  ];
}

const TOOLS = [{ type: "function", function: { name: "image_series", parameters: { type: "object", properties: { structured: { type: "object", properties: {} } } } } }];
const referenceStore = { prepare: async () => ({ ok: true }) };

function seriesArgs(over) {
  return JSON.stringify({
    prompt: "秋季新品组图",
    source: "attached",
    source_indexes: [1],
    structured: {
      text: [{ role: "title", text: "栗香上市" }],
      image_references: { version: 1, mode: "replace", items: IDS.map((id, i) => ({ kind: "library", id, role: `素材${i + 1}` })) },
    },
    ...over,
  });
}

async function prep() {
  const { prepareSeriesReferenceGuidance } = require(SERIES);
  return prepareSeriesReferenceGuidance({ messages: messagesWithRecall(), tools: TOOLS, owner: "acct", referenceStore });
}

test("历史原图 + 本轮附件同时出现：收敛为「附件优先」，不抛错", async () => {
  const ctx = await prep();
  const calls = [{ id: "c1", type: "function", function: { name: "image_series", arguments: seriesArgs({}) } }];
  const out = ctx.finalize(calls); // 旧实现这里会 throw IMAGE_REFERENCE_CONFLICT
  const args = JSON.parse(out[0].function.arguments);
  assert.equal(args.structured.image_references, undefined, "历史引用应被丢弃");
  assert.deepEqual(args.source_indexes, [1], "本轮附件索引必须保留");
  assert.equal(args.source, "attached", "附件来源必须保留");
  assert.equal(args.structured.text[0].text, "栗香上市", "文案不能被牵连删除");
});

test("只用历史原图（source=none）：契约照常下发，不误伤", async () => {
  const ctx = await prep();
  const calls = [{ id: "c2", type: "function", function: { name: "image_series", arguments: seriesArgs({ source: "none", source_indexes: undefined }) } }];
  const out = ctx.finalize(calls);
  const args = JSON.parse(out[0].function.arguments);
  assert.equal(args.structured.image_references.items.length, 4, "合法历史引用必须保留");
  assert.equal(args.structured.image_references.mode, "replace");
});

test("引用了未签发编号：降级丢弃而不是中断", async () => {
  const ctx = await prep();
  const bogus = { version: 1, mode: "replace", items: [{ kind: "library", id: "FFFFFFFFFF-9999-4999-8999-999999999999", role: "素材" }] };
  const calls = [{ id: "c3", type: "function", function: { name: "image_series", arguments: seriesArgs({ source: "none", source_indexes: undefined, structured: { image_references: bogus } }) } }];
  const out = ctx.finalize(calls);
  const args = JSON.parse(out[0].function.arguments);
  assert.equal(args.structured.image_references, undefined, "未签发引用应被丢弃");
});

test("素材超限：错误里带实际体积与上限", () => {
  const { assetSpec } = require(STORE);
  const sha = "a".repeat(64);
  assert.throws(
    () => assetSpec({ sha256: sha, byteCount: 32 * 1024 * 1024, mime: "image/jpeg" }),
    (e) => e.message === "ASSET_SIZE_LIMIT" && e.limitBytes === 24 * 1024 * 1024 && e.actualBytes === 32 * 1024 * 1024
  );
});

test("素材超限：接口层返回「约 32MB，超过 24MB」而不是笼统提示", async () => {
  const { createFoundationHandler } = require(FOUNDATION);
  let captured = null;
  const handler = createFoundationHandler({
    requireMember: async () => ({ sub: "acct" }),
    readJsonBody: async () => ({ sha256: "a".repeat(64), byteCount: 32 * 1024 * 1024, mime: "image/jpeg" }),
    syncV2: {}, eventService: {},
    assetStore: {
      prepare: async () => {
        const error = new Error("ASSET_SIZE_LIMIT");
        error.limitBytes = 24 * 1024 * 1024;
        error.actualBytes = 32 * 1024 * 1024;
        throw error;
      },
      commit: async () => ({}), sign: async () => [],
    },
    sendJson: () => {},
    sendError: (res, status, code, message) => { captured = { status, code, message }; },
    logSafe: () => {},
    currentRequestId: () => "test-req",
  });
  await handler({ method: "POST", headers: {} }, {}, new URL("https://x/api/assets/prepare"));
  assert.equal(captured.status, 422);
  assert.match(captured.message, /32MB/);
  assert.match(captured.message, /24MB/);
  assert.match(captured.message, /压缩/);
});
