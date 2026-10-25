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
// 幂等：重复删除同一条 → 本地 notFound、云端 404/alreadyDeleted，全部按成功处理。
// ============================================================================

@MainActor
enum ConversationDeletion {

    /// 补删队列（按账号隔离，避免 A 账号的删除动作影响 B 账号）
    private static let outboxPrefix = "bossai.deleted.conversations."
    /// 队列上限：异常情况下（例如一直离线）也不允许无限增长
    private static let outboxLimit = 300

    private static func outboxKey() -> String {
        let scope = HostedAccount.scopeKey
        return outboxPrefix + (scope.isEmpty ? "anon" : scope)
    }

    // MARK: - 本地级联删除（同步、用户立即看到结果）

    /// 删除一条会话：底座图缓存 → 级联删消息 → 删会话 → 落库 → 进补删队列 → 异步推云端墓碑。
    /// 返回是否真的删掉了（已不存在返回 false，调用方可按"无变化"处理）。
    @discardableResult
    static func delete(_ conv: Conversation, context: ModelContext) -> Bool {
        let id = conv.id
        let owner = conv.ownerKey
        let scope = HostedAccount.scopeKey
        // 防呆（跨账号）：只允许删当前账号名下的会话。侧栏已过滤，这里再兜一次，
        // 任何未来新增入口都不至于因为漏过滤而删到别人的数据。
        if !owner.isEmpty, !scope.isEmpty, owner != scope { return false }

        // 底图缓存里如果是这条会话的底图，一并清掉：内存里不该留一张已删会话的图
        if BaseImageCache.shared.entry?.conversationId == id.uuidString {
            BaseImageCache.shared.evict()
        }

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
            return false
        }

        enqueue(id)
        // 云端墓碑异步推：不阻塞 UI。失败留在队列里，下次同步补推。
        Task { await pushTombstone(id: id) }
        return true
    }

    // MARK: - 云端墓碑（幂等）

    /// 给云端写墓碑：成功返回 true 并出队；任何失败都返回 false 并**保留**在队列里。
    ///
    /// 注意：这里**不把 404 当成功**。404 在本服务里基本只有一个来源——接口还没部署
    /// （路由未匹配的兜底就是 404 "接口不存在"）。把它当"已删除"会把墓碑永远吞掉：
    /// 本地删了、云端还在，另一台设备一同步就复活。宁可留在队列里重试。
    @discardableResult
    static func pushTombstone(id: UUID) async -> Bool {
        guard HostedAccount.isHostedActive, HostedAccount.shared.isLoggedIn else { return false }
        do {
            _ = try await HostedAccount.shared.deleteConversation(id: id)
            confirmRemoteDeleted(id)
            return true
        } catch {
            return false
        }
    }

    /// 同步前补推：把上次没删成功的墓碑补上（幂等；每条只试一次，失败留到下次）
    static func flushPendingDeletes() async {
        let ids = pendingDeleteIDs()
        guard !ids.isEmpty else { return }
        for id in ids {
            _ = await pushTombstone(id: id)
        }
    }

    // MARK: - 补删队列

    static func pendingDeleteIDs() -> Set<UUID> {
        let raw = UserDefaults.standard.dictionary(forKey: outboxKey()) ?? [:]
        return Set(raw.keys.compactMap { UUID(uuidString: $0) })
    }

    /// 这条会话是否处于"本地已删、云端墓碑还没确认"的状态。
    /// pull 合并时用它挡住复活（云端旧数据/另一台设备的旧副本推上来一律不落地）。
    static func isPendingDelete(_ id: UUID) -> Bool {
        (UserDefaults.standard.dictionary(forKey: outboxKey()) ?? [:])[id.uuidString] != nil
    }

    /// 云端已确认删除（或云端返回墓碑）→ 出队
    static func confirmRemoteDeleted(_ id: UUID) {
        var raw = UserDefaults.standard.dictionary(forKey: outboxKey()) ?? [:]
        guard raw.removeValue(forKey: id.uuidString) != nil else { return }
        UserDefaults.standard.set(raw, forKey: outboxKey())
    }

    private static func enqueue(_ id: UUID) {
        var raw = UserDefaults.standard.dictionary(forKey: outboxKey()) ?? [:]
        raw[id.uuidString] = Date().timeIntervalSince1970
        if raw.count > outboxLimit {
            // 只保留最近 outboxLimit 条：极端情况下宁可丢最老的补删（用户早已看不到那条会话）
            let kept = raw
                .sorted { ($0.value as? Double ?? 0) > ($1.value as? Double ?? 0) }
                .prefix(outboxLimit)
            raw = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }
        UserDefaults.standard.set(raw, forKey: outboxKey())
    }

    /// 测试与帐号切换用：清空当前账号的补删队列
    static func resetOutboxForTesting() {
        UserDefaults.standard.removeObject(forKey: outboxKey())
    }
}
