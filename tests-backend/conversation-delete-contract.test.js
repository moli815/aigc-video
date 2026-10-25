// ============================================================================
// 历史会话删除契约（10-25 收尾版）
//
// 锁住这些不变量，任何一条破了都会变成线上事故：
//   1. 云端存在 DELETE /sync/conversations/:id，且必须走会员鉴权；
//   2. 归属校验：查询绑 accountId，删除前再校验一次，别人的会话一律 403；
//   3. 幂等：云端没有 / 已是墓碑 / 同一 requestId 重放 都返回 200；
//   4. 客户端：本地物理级联删 + 离线补删队列 + 拉取时不许复活 + 永久失败不再重试；
//   5. 响应与审计不含 Token / 消息正文；
//   6. 底图缓存：命中即跳过生成、成功才清、失败保留、按会话与任务隔离。
// ============================================================================

const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.resolve(__dirname, "..");
const read = (p) => fs.readFileSync(path.join(ROOT, p), "utf8");
const API = read("cloudfunctions/bf-api/index.js");
const HOSTED = read("BossAI/Services/HostedAccount.swift");
const SYNC = read("BossAI/Services/SyncService.swift");
const DELETION = read("BossAI/Services/ConversationDeletionService.swift");
const VM_DELETION = read("BossAI/ViewModels/ChatViewModel+Deletion.swift");
const STREAMING = read("BossAI/ViewModels/ChatViewModel+Streaming.swift");
const MAINVIEW = read("BossAI/Views/MainView.swift");
const CACHE = read("BossAI/Services/BaseImageCache.swift");

const handlerFrom = () => {
  const start = API.indexOf("async function handleSyncDeleteConversation");
  const end = API.indexOf("/** GET /sync/pull", start);
  return API.slice(start, end);
};

// ── 云端 ────────────────────────────────────────────────────────────────────

test("DEL-01 路由已注册（DELETE /api/sync/conversations/:id）", () => {
  assert.match(API, /m === "DELETE" && p\.startsWith\("\/api\/sync\/conversations\/"\)/,
    "缺少 DELETE /api/sync/conversations/:id 路由");
  assert.match(API, /function handleSyncDeleteConversation\(/, "缺少处理器实现");
});

test("DEL-02 处理器必须走会员鉴权（不能是公开接口）", () => {
  const head = handlerFrom().slice(0, 400);
  assert.match(head, /requireMember\(req, res\)/, "删除接口未做会员鉴权");
});

test("DEL-03 路径 id 只接受 UUID（防呆，不把任意路径写进库）", () => {
  const body = handlerFrom().slice(0, 1400);
  assert.match(body, /UUID_RE\.test\(refId\)/, "缺少 UUID 校验");
  assert.match(body, /sendError\(res, 400, "BAD_ID"/, "非法 id 未返回 400");
});

test("DEL-04 归属校验：查询绑 accountId，删除前再校验一次（别人的会话 403）", () => {
  const body = handlerFrom();
  assert.match(body, /where\(\{ accountId: auth\.sub, kind, refId \}\)/, "兼容查询未绑 accountId");
  assert.match(body, /String\(row\.accountId \|\| ""\) !== String\(auth\.sub\)[\s\S]{0,200}403/,
    "缺少删除前的归属校验（必须 403，不能伪装成功）");
  assert.doesNotMatch(body, /String\(row\.accountId \|\| ""\) !== String\(auth\.sub\)[\s\S]{0,200}404/,
    "归属不符不能返回 404：404 是「接口未部署」信号，客户端会保留补删队列");
});

test("DEL-05 幂等：云端没有这条 / 已是墓碑 都返回 200", () => {
  const body = handlerFrom();
  assert.match(body, /if \(!row\)[\s\S]{0,1200}alreadyDeleted: true/, "云端无记录时未按幂等成功返回");
  assert.match(body, /if \(row\.deleted\)[\s\S]{0,300}alreadyDeleted: true/, "已是墓碑时未按幂等返回");
});

test("DEL-06 墓碑结构：deleted=true + payload 带 id（客户端 pull 靠它定位）", () => {
  const body = handlerFrom();
  assert.match(body, /JSON\.stringify\(\{ id: refId, isDeleted: true/, "墓碑 payload 缺 id 或 isDeleted");
  assert.match(body, /deleted: true/, "未写行级 deleted 标记（pull 侧据此判删除）");
});

test("DEL-07 确定性 _id：重复/并发删除不会产生第二条记录", () => {
  const body = handlerFrom();
  assert.match(body, /createHash\("sha256"\)[\s\S]{0,160}slice\(0, 40\)/, "未使用确定性 _id");
  assert.match(body, /catch \(eAdd\)[\s\S]{0,600}SYNC_FAILED/, "并发撞车缺少兜底");
});

test("DEL-14 requestId 幂等：同一请求重放只生效一次", () => {
  const body = handlerFrom();
  assert.match(body, /const rid = currentRequestId\(\)/, "未取 requestId");
  assert.match(body, /lastDeleteRequestId === rid[\s\S]{0,200}replayed: true/, "缺少 requestId 重放短路");
  assert.match(body, /lastDeleteRequestId: rid/, "墓碑未记录 lastDeleteRequestId");
});

test("DEL-15 审计：记录必要信息，且不含消息正文", () => {
  const body = handlerFrom();
  assert.match(body, /auditLog\(auth, "conversation_delete"/, "删除未写审计");
  assert.match(body, /messagesRemoved/, "审计未记录删除消息数量");
  assert.match(body, /result: "(tombstoned|tombstone_created|already_tombstoned)"/, "审计未记录结果");
  assert.doesNotMatch(body, /auditLog\([\s\S]{0,200}payload:/, "审计不得写入 payload 正文");
});

test("DEL-16 响应不含 Token / 消息正文 / 敏感内容", () => {
  const body = handlerFrom();
  const responses = body.match(/sendJson\(res, 200, \{[\s\S]*?\}\);/g) || [];
  assert.ok(responses.length >= 3, "响应分支数量异常");
  for (const r of responses) {
    assert.doesNotMatch(r, /token|payload|title|messages\s*:|text\s*:/i, "响应泄露敏感字段：" + r.slice(0, 120));
  }
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
  assert.doesNotMatch(DELETION, /status == 404[\s\S]{0,120}confirmRemoteDeleted/,
    "不得把 404 当成功出队（404 = 接口未部署，必须留着重试）");
  assert.match(DELETION, /confirmRemoteDeleted\(id\)/, "成功后必须出队");
});

test("DEL-17 永久失败不再无限重试，且 403 绝不当成已删除", () => {
  assert.match(DELETION, /case drop/, "缺少「重试无意义」的终态");
  assert.match(DELETION, /403[\s\S]{0,160}drop/, "403 未归类为终态");
  // 关键：走终态时只能出队，不能调用「云端已确认」的出队语义
  const dropIndex = DELETION.indexOf("case .drop");
  const dropBlock = DELETION.slice(dropIndex, dropIndex + 500);
  assert.doesNotMatch(dropBlock, /confirmRemoteDeleted/, "403 不能被记为「云端已确认删除」");
  assert.match(DELETION, /maxAttempts/, "缺少重试次数上限");
});

test("DEL-18 同步：先补推墓碑，再拉取；拉取时不许复活已删会话", () => {
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

// ── 底图缓存 ────────────────────────────────────────────────────────────────

test("DEL-13 底图缓存：字典键（会话+任务）+ 锁 + 会话级清理", () => {
  assert.match(CACHE, /private var storage: \[String: BaseImageEntry\] = \[:\]/, "仍是单条 entry（并发会互相覆盖）");
  assert.match(CACHE, /private let lock = NSLock\(\)/, "缺少互斥锁");
  assert.match(CACHE, /private func cacheKey\(_ conversationId: String, _ taskId: String\)/, "键未包含会话+任务");
  assert.match(CACHE, /func evict\(conversationId: String\)/, "缺少会话级清理");
  assert.match(CACHE, /func evictAll\(\)/, "缺少全清");
  assert.match(CACHE, /func evictExpired\(now: Date = Date\(\)\)/, "缺少过期清理");
});

test("DEL-19 排版分支：底图成功即缓存、命中跳过 Pro、成功才清、失败保留、命中不计额度", () => {
  assert.match(STREAMING, /if lookup == \.hit,/, "命中分支缺失（仍会重画底图）");
  assert.match(STREAMING, /let cached = cache\.entry\(conversationId: cacheConversationId, taskId: cacheTaskId\)/,
    "命中后未按会话+任务取条目");
  assert.match(STREAMING, /cache\.markOverlayDoneAndEvict\(conversationId: cacheConversationId, taskId: cacheTaskId\)/,
    "排版成功后未精确清理该条");
  assert.match(STREAMING, /cache\.retainAfterOverlayFailure\(conversationId: cacheConversationId, taskId: cacheTaskId\)/,
    "排版失败未显式保留缓存");
  assert.match(STREAMING, /if baseImageFromCache \{[\s\S]{0,260}else \{[\s\S]{0,120}BudgetTracker\.addImageGeneration\(\)/,
    "命中缓存仍计本地生图额度（重复计费体感）");
  const saveIndex = STREAMING.indexOf("cache.save(taskId: cacheTaskId");
  const renderIndex = STREAMING.indexOf("TextOverlayRenderer.render(base: baseImage");
  assert.ok(saveIndex > 0 && renderIndex > saveIndex, "缓存必须写在排版之前（排版失败底图还在）");
});
