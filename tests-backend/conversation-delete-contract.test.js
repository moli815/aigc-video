// ============================================================================
// 历史会话删除契约（10-25）
//
// 锁住四件事，任何一条破了都会变成线上事故：
//   1. 云端存在 DELETE /sync/conversations/:id，且必须走会员鉴权；
//   2. 归属校验：查询绑 accountId，删除前再校验一次，别人的会话一律 404；
//   3. 幂等：云端没有 / 已是墓碑 / 并发重复调用 都返回 200，不报错、不产生第二条记录；
//   4. 客户端：本地级联删 + 离线补删队列 + 拉取时不许复活。
// ============================================================================

const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.resolve(__dirname, "..");
const API = fs.readFileSync(path.join(ROOT, "cloudfunctions/bf-api/index.js"), "utf8");
const HOSTED = fs.readFileSync(path.join(ROOT, "BossAI/Services/HostedAccount.swift"), "utf8");
const SYNC = fs.readFileSync(path.join(ROOT, "BossAI/Services/SyncService.swift"), "utf8");
const DELETION = fs.readFileSync(path.join(ROOT, "BossAI/Services/ConversationDeletionService.swift"), "utf8");
const VM_DELETION = fs.readFileSync(path.join(ROOT, "BossAI/ViewModels/ChatViewModel+Deletion.swift"), "utf8");
const STREAMING = fs.readFileSync(path.join(ROOT, "BossAI/ViewModels/ChatViewModel+Streaming.swift"), "utf8");
const MAINVIEW = fs.readFileSync(path.join(ROOT, "BossAI/Views/MainView.swift"), "utf8");

// ── 云端 ────────────────────────────────────────────────────────────────────

test("DEL-01 路由已注册（DELETE /api/sync/conversations/:id）", () => {
  assert.match(API, /m === "DELETE" && p\.startsWith\("\/api\/sync\/conversations\/"\)/,
    "缺少 DELETE /api/sync/conversations/:id 路由");
  assert.match(API, /function handleSyncDeleteConversation\(/, "缺少处理器实现");
});

test("DEL-02 处理器必须走会员鉴权（不能是公开接口）", () => {
  const fn = API.slice(API.indexOf("async function handleSyncDeleteConversation"));
  const head = fn.slice(0, 400);
  assert.match(head, /requireMember\(req, res\)/, "删除接口未做会员鉴权");
});

test("DEL-03 路径 id 只接受 UUID（防呆，不把任意路径写进库）", () => {
  const fn = API.slice(API.indexOf("async function handleSyncDeleteConversation"));
  assert.match(fn.slice(0, 1200), /UUID_RE\.test\(refId\)/, "缺少 UUID 校验");
  assert.match(fn.slice(0, 1400), /sendError\(res, 400, "BAD_ID"/, "非法 id 未返回 400");
});

test("DEL-04 归属校验：查询绑 accountId，删除前再校验一次（别人的会话 403）", () => {
  const fn = API.slice(API.indexOf("async function handleSyncDeleteConversation"));
  const body = fn.slice(0, fn.indexOf("/** GET /sync/pull"));
  assert.match(body, /where\(\{ accountId: auth\.sub, kind, refId \}\)/, "兼容查询未绑 accountId");
  assert.match(body, /String\(row\.accountId \|\| ""\) !== String\(auth\.sub\)[\s\S]{0,200}403/,
    "缺少删除前的归属校验（必须 403，不能伪装成功）");
  assert.doesNotMatch(body, /String\(row\.accountId \|\| ""\) !== String\(auth\.sub\)[\s\S]{0,200}404/,
    "归属不符不能返回 404：404 是「接口未部署」信号，客户端会保留补删队列");
});

test("DEL-05 幂等：云端没有这条 / 已是墓碑 都返回 200", () => {
  const fn = API.slice(API.indexOf("async function handleSyncDeleteConversation"));
  const body = fn.slice(0, fn.indexOf("/** GET /sync/pull"));
  assert.match(body, /if \(!row\)[\s\S]{0,900}alreadyDeleted: true/, "云端无记录时未按幂等成功返回");
  assert.match(body, /if \(row\.deleted\)[\s\S]{0,160}alreadyDeleted: true/, "已是墓碑时未按幂等返回");
});

test("DEL-06 墓碑结构：deleted=true + payload 带 id（客户端 pull 靠它定位）", () => {
  const fn = API.slice(API.indexOf("async function handleSyncDeleteConversation"));
  const body = fn.slice(0, fn.indexOf("/** GET /sync/pull"));
  assert.match(body, /JSON\.stringify\(\{ id: refId, isDeleted: true/, "墓碑 payload 缺 id 或 isDeleted");
  assert.match(body, /deleted: true/, "未写行级 deleted 标记（pull 侧据此判删除）");
});

test("DEL-07 确定性 _id：重复/并发删除不会产生第二条记录", () => {
  const fn = API.slice(API.indexOf("async function handleSyncDeleteConversation"));
  const body = fn.slice(0, fn.indexOf("/** GET /sync/pull"));
  assert.match(body, /createHash\("sha256"\)[\s\S]{0,160}slice\(0, 40\)/, "未使用确定性 _id");
  assert.match(body, /catch \(eAdd\)[\s\S]{0,400}SYNC_FAILED/, "并发撞车缺少兜底");
});

// ── 客户端 ──────────────────────────────────────────────────────────────────

test("DEL-08 客户端调用云端删除接口（UUID 主键，无需百分号编码）", () => {
  assert.match(HOSTED, /func deleteConversation\(id: UUID\) async throws -> \[String: Any\]/);
  assert.match(HOSTED, /request\("\/sync\/conversations\/" \+ id\.uuidString, method: "DELETE"\)/);
});

test("DEL-09 本地删除是物理级联（消息不留孤儿）+ 保存失败回滚", () => {
  assert.match(DELETION, /for message in messages \{\s*context\.delete\(message\)/,
    "消息未显式删除（SwiftData 级联在可选反向关系上不可靠）");
  assert.match(DELETION, /context\.delete\(conv\)/, "会话本身未删除");
  assert.match(DELETION, /catch \{\s*\/\/[\s\S]{0,160}context\.rollback\(\)/, "保存失败未回滚");
});

test("DEL-10 离线补删队列：推不上去要留住，云端确认后才出队", () => {
  assert.match(DELETION, /guard HostedAccount\.isHostedActive, HostedAccount\.shared\.isLoggedIn else \{ return false \}/,
    "未登录/自备 Key 模式必须保留在队列里");
  assert.match(DELETION, /func flushPendingDeletes\(\) async/, "缺少同步前补推");
  // 关键反例：把 404 当"已删除"会吞掉「接口未部署」，墓碑永远写不上 → 别的设备复活
  assert.doesNotMatch(DELETION, /status == 404[\s\S]{0,120}confirmRemoteDeleted/,
    "不得把 404 当成功出队（404 = 接口未部署，必须留着重试）");
  assert.match(DELETION, /confirmRemoteDeleted\(id\)/, "成功后必须出队");
});

test("DEL-11 同步：先补推墓碑，再拉取；拉取时不许复活已删会话", () => {
  assert.match(SYNC, /try await push\(context: context\)[\s\S]{0,300}await ConversationDeletion\.flushPendingDeletes\(\)[\s\S]{0,120}try await pull\(context: context\)/,
    "syncNow 未在 pull 前补推删除墓碑");
  assert.match(SYNC, /ConversationDeletion\.isPendingDelete\(uuid\)[\s\S]{0,200}context\.delete\(existing\)/,
    "pull 缺少防复活守卫：本机已删的会话会被云端旧数据推回来");
  assert.match(SYNC, /if deleted \{[\s\S]{0,160}ConversationDeletion\.confirmRemoteDeleted\(uuid\)/,
    "云端墓碑到达后未出队");
});

test("DEL-12 UI：侧栏显性入口 + 确认弹窗 + 对话区入口共用同一套删除实现", () => {
  assert.match(MAINVIEW, /pendingDelete = conv/, "侧栏缺少删除入口");
  assert.match(MAINVIEW, /\.confirmationDialog\("删除这个对话？"/, "缺少删除确认弹窗");
  assert.match(MAINVIEW, /ConversationDeletion\.delete\(conv, context: context\)/,
    "侧栏删除未走统一实现");
  assert.match(VM_DELETION, /func deleteConversation\(\) -> Bool/, "缺少 ChatViewModel.deleteConversation");
  assert.match(VM_DELETION, /ConversationDeletion\.delete\(conv, context: modelContext\)/,
    "VM 删除未走统一实现");
});

// ── 底图缓存接线 ────────────────────────────────────────────────────────────

test("DEL-13 底图缓存接线：底图成功即缓存、命中跳过生成、成功才清", () => {
  assert.match(STREAMING, /if lookup == \.hit, let cached = cache\.entry/, "命中分支缺失（仍会重画底图）");
  assert.match(STREAMING, /cache\.save\(taskId: cacheTaskId/, "底图成功后未写缓存");
  assert.match(STREAMING, /cache\.markOverlayDoneAndEvict\(\)/, "排版成功后未清缓存");
  assert.match(STREAMING, /cache\.retainAfterOverlayFailure\(\)/, "排版失败未显式保留缓存");
  const saveIndex = STREAMING.indexOf("cache.save(taskId: cacheTaskId");
  const renderIndex = STREAMING.indexOf("TextOverlayRenderer.render(base: baseImage");
  assert.ok(saveIndex > 0 && renderIndex > saveIndex, "缓存必须写在排版之前（排版失败底图还在）");
});
