import Foundation
import SwiftData
import UIKit

// ============================================================================
// ConversationDeletionService.swift —— 历史会话删除（2026-10-25）
//
// 目的：侧栏删掉的对话必须**真的消失**，并且不能"删了又复活"。
//
// 为什么不能只做本地删除（关键）：
//   本地删干净、云端不清 → 另一台设备一同步就把它推回来，用户眼里就是"删了又回来了"。
//   所以本地删完必须给云端写一条墓碑。
//
// 为什么也不能只靠 /sync/push 的 isDeleted 墓碑（旧做法）：
//   墓碑方案要求"记录还在本地"，否则推不上去。用户删了以后这条记录会一直留在库里，
//   消息正文、附件索引全留着——既占空间又与"删除"的语义不符。
//   因此这里：**本地物理级联删 + 云端墓碑（DELETE 接口）**，两者各司其职。
//
// 离线怎么办（必须有答案）：
//   本地删除是同步完成的（用户立刻看到效果），云端 DELETE 是异步任务。
//   失败（离线/服务不可用/自备 Key 模式）就把 id 记进「补删队列」，
//   每次 syncNow 先补推一遍；pull 时若发现云端又把这条推回来，本地立刻再删一次。
//
// 失败分类（10-25 收尾，别退回"什么都重试"）：
//   · 网络 / 401 / 404（接口未部署）/ 429 / 5xx → 留队列，下次再试（最多 maxAttempts 次）
//   · 400 / 403                                  → 重试无意义，**出队放弃**。
//     注意：放弃 ≠ 删除成功。403 是"这不是你的会话"，绝不能记为"云端已确认删除"，
//     否则会掩盖越权/数据错乱。
//
// 幂等：重复删除同一条 → 云端 200 alreadyDeleted；本地队列按 id 去重。
// ============================================================================

@MainActor
enum ConversationDeletion {

    /// 云端删除请求的判定结果
    enum DeleteOutcome: Equatable {
        /// 云端已删除（含幂等 200）
        case done
        /// 可恢复失败：网络 / 401 / 404（未部署）/ 429 / 5xx —— 留在队列里下次再试
        case retryLater
        /// 终态失败：400 / 403 —— 重试没有意义，出队放弃（**不代表删除成功**）
        case drop
    }

    /// 补删队列（按账号隔离，避免 A 账号的删除动作影响 B 账号）
    private static let outboxPrefix = "bossai.deleted.conversations."
    /// 队列上限：异常情况下（例如一直离线）也不允许无限增长
    private static let outboxLimit = 300
    /// 单条补删最多尝试次数：网络抖动留足余地，永久性失败不许无限刷
    static let maxAttempts = 8

    /// 一条待补删记录
    struct PendingDelete: Equatable {
        let id: UUID
        let enqueuedAt: Date
        let attempts: Int
    }

    private static func outboxKey() -> String {
        let scope = HostedAccount.scopeKey
        return outboxPrefix + (scope.isEmpty ? "anon" : scope)
    }

    private static func rawOutbox() -> [String: Any] {
        UserDefaults.standard.dictionary(forKey: outboxKey()) ?? [:]
    }

    private static func writeOutbox(_ raw: [String: Any]) {
        UserDefaults.standard.set(raw, forKey: outboxKey())
    }

    /// 兼容上一版（[String: Double]）存下来的队列数据
    private static func meta(_ value: Any?) -> (enqueuedAt: Date, attempts: Int) {
        if let dict = value as? [String: Any] {
            let at = (dict["at"] as? Double) ?? 0
            let tries = (dict["tries"] as? Int) ?? (dict["tries"] as? NSNumber)?.intValue ?? 0
            return (Date(timeIntervalSince1970: at), tries)
        }
        if let legacy = value as? Double {
            return (Date(timeIntervalSince1970: legacy), 0)
        }
        return (Date(), 0)
    }

    // MARK: - 本地级联删除（同步、用户立即看到结果）

    /// 删除一条会话：底座图缓存 → 级联删消息 → 删会话 → 落库 → 进补删队列 → 异步推云端墓碑。
    /// 返回是否真的删掉了（已不存在 / 非本账号 返回 false）。
    @discardableResult
    static func delete(_ conv: Conversation, context: ModelContext) -> Bool {
        let id = conv.id
        let owner = conv.ownerKey
        let scope = HostedAccount.scopeKey
        // 防呆（跨账号）：只允许删当前账号名下的会话。侧栏已过滤，这里再兜一次，
        // 任何未来新增入口都不至于因为漏过滤而删到别人的数据。
        if !owner.isEmpty, !scope.isEmpty, owner != scope { return false }
        // Durable tombstone precedes physical deletion. Legacy retry limits must never
        // erase the user's intent, even after a long offline period or app restart.
        do { try SyncV2Engine.enqueueDeletion(kind: "conversation", id: id, owner: scope) }
        catch { return false }

        // 底图缓存里属于这条会话的底图一并清掉（只清这个会话的键，别的会话/并发任务不受影响）
        BaseImageCache.shared.evict(conversationId: id.uuidString)

        // 级联：先删子对象再删父对象。
        // Conversation.messages 上虽然声明了 .cascade，但 SwiftData 的级联删在
        // 「可选反向关系 + 关系未完全解析」时并不总是可靠，显式删一遍才不会留孤儿消息。
        let messages = conv.messages
        for message in messages {
            context.delete(message)
        }
        context.delete(conv)
        do {
            try context.save()
        } catch {
            // 保存失败：回滚到删除前的状态，避免内存里"看着删了、库里还在"的半截状态
            context.rollback()
            SyncV2Engine.cancelDeletion(kind: "conversation", id: id, owner: scope)
            return false
        }

        enqueue(id)
        // 云端墓碑异步推：不阻塞 UI。失败按分类处理（留队列 / 放弃）
        Task { await pushTombstone(id: id) }
        return true
    }

    // MARK: - 云端墓碑（按失败类型判定）

    /// 失败分类：纯函数，方便测试与排查。
    static func classify(_ error: Error?) -> DeleteOutcome {
        guard let error else { return .done }
        guard let hosted = error as? HostedError else {
            // 未知错误按可重试处理（宁可多试几次，也不要把没删掉当成删掉了）
            return .retryLater
        }
        switch hosted {
        case .network:
            return .retryLater
        case .input:
            return .drop
        case .server(_, let status, _):
            // 400 参数不合法、403 归属不符 → 重试永远同样结果
            if status == 400 || status == 403 { return .drop }
            // 401 token 过期（重新登录后还能推）、404 接口未部署、429 限流、5xx 抖动 → 留队列
            return .retryLater
        }
    }

    /// 给云端写墓碑：成功返回 true 并出队；失败按分类留队列 / 放弃。
    ///
    /// 注意：这里**不把 404 当成功**。404 在本服务里基本只有一个来源——接口还没部署
    /// （路由未匹配的兜底就是 404 "接口不存在"）。把它当"已删除"会把墓碑永远吞掉：
    /// 本地删了、云端还在，另一台设备一同步就复活。宁可留在队列里重试。
    @discardableResult
    static func pushTombstone(id: UUID) async -> Bool {
        guard HostedAccount.isHostedActive, HostedAccount.shared.isLoggedIn else { return false }
        guard let session = CloudSession.capture() else { return false }
        do {
            _ = try await session.request("/sync/conversations/" + id.uuidString, method: "DELETE")
            try session.validate()
            try SyncV2Engine.noteDeletedConversation(id, owner: session.owner)
            confirmRemoteDeleted(id)
            return true
        } catch {
            guard (try? session.validate()) != nil else { return false }
            switch classify(error) {
            case .done:
                confirmRemoteDeleted(id)
                return true
            case .retryLater:
                _ = recordRetryFailure(id)
                return false
            case .drop:
                dropFromOutbox(id)
                return false
            }
        }
    }

    /// 同步前补推：把上次没删成功的墓碑补上（幂等；每条只试一次，失败留到下次）
    static func flushPendingDeletes() async {
        let pending = pendingDeletes()
        guard !pending.isEmpty else { return }
        for item in pending {
            _ = await pushTombstone(id: item.id)
        }
    }

    // MARK: - 补删队列

    static func pendingDeletes() -> [PendingDelete] {
        rawOutbox().compactMap { pair -> PendingDelete? in
            guard let id = UUID(uuidString: pair.key) else { return nil }
            let info = meta(pair.value)
            return PendingDelete(id: id, enqueuedAt: info.enqueuedAt, attempts: info.attempts)
        }
    }

    static func pendingDeleteIDs() -> Set<UUID> {
        Set(pendingDeletes().map { $0.id })
    }

    /// 这条会话是否处于"本地已删、云端墓碑还没确认"的状态。
    /// pull 合并时用它挡住复活（云端旧数据/另一台设备的旧副本推上来一律不落地）。
    static func isPendingDelete(_ id: UUID) -> Bool {
        rawOutbox()[id.uuidString] != nil || SyncV2Engine.hasPendingDeletion(kind: "conversation", id: id, owner: HostedAccount.scopeKey)
    }

    /// 云端已确认删除（或云端返回墓碑）→ 出队
    static func confirmRemoteDeleted(_ id: UUID) {
        SyncV2Engine.cancelDeletion(kind: "conversation", id: id, owner: HostedAccount.scopeKey)
        var raw = rawOutbox()
        guard raw.removeValue(forKey: id.uuidString) != nil else { return }
        writeOutbox(raw)
    }

    /// 放弃补删（400/403 等永久失败）——**不是**删除成功，只是不再重试
    static func dropFromOutbox(_ id: UUID) {
        var raw = rawOutbox()
        guard raw.removeValue(forKey: id.uuidString) != nil else { return }
        writeOutbox(raw)
    }

    /// Attempts are capped for diagnostics; a recoverable failure never removes a tombstone.
    @discardableResult
    static func recordRetryFailure(_ id: UUID, now: Date = Date()) -> Bool {
        var raw = rawOutbox()
        guard let value = raw[id.uuidString] else { return false }
        let old = meta(value)
        let tries = old.attempts + 1
        raw[id.uuidString] = ["at": old.enqueuedAt.timeIntervalSince1970,
                              "tries": min(tries, maxAttempts),
                              "lastTry": now.timeIntervalSince1970]
        writeOutbox(raw)
        return false
    }

    private static func enqueue(_ id: UUID) {
        var raw = rawOutbox()
        raw[id.uuidString] = ["at": Date().timeIntervalSince1970, "tries": 0]
        if raw.count > outboxLimit {
            // 只保留最近 outboxLimit 条：极端情况下宁可丢最老的补删（用户早已看不到那条会话）
            let kept = raw
                .sorted { meta($0.value).enqueuedAt > meta($1.value).enqueuedAt }
                .prefix(outboxLimit)
            raw = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }
        writeOutbox(raw)
    }

    /// 测试与帐号切换用：清空当前账号的补删队列
    static func resetOutboxForTesting() {
        UserDefaults.standard.removeObject(forKey: outboxKey())
    }
}
