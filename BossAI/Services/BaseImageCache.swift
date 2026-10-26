import Foundation
import UIKit
import CryptoKit

// BaseImageCache.swift —— 无字底图缓存（2026-10-25）
//
// 目的只有一个：**排版失败或用户只改文字时，不要重新调 Pro**。
// 一次 Pro 底图 0.45 元、20~30 秒；改个电话号码就重画一张，是纯浪费。
//
// ── 并发模型（10-25 复核后重写）──────────────────────────────────────────────
// 旧版是**单条全局 entry**，只有在"全局任何时刻只跑一个图片任务"时才安全。
// 实测代码路径并不能保证这一点：
//   · 每个会话有自己的 ChatViewModel / runLoop，切会话时旧 VM 的取消是协作式的
//     （URLSession 取消返回前，旧任务仍可能正在写缓存）；
//   · 组图补画（series retry）与新对话共用同一进程；
//   · 将来接多窗口 / iPad 分屏会更加并发。
// 所以现在改为 **按 conversationId + taskId 的字典**，并用 NSLock 保护——
// 任务 A 与任务 B 各存各的键，物理上不可能互相覆盖。
//
// 命中规则（四条同时满足才算 hit，任一条不符即 miss）：
//   1. conversationId 相同（绝不跨会话串图）
//   2. taskId 相同（不同任务不用彼此底图）
//   3. aspectRatio 相同（比例变了要重画）
//   4. 未过期（默认 15 分钟，避免长期占内存）
//
// 明确不做的事：
//   · 不写磁盘（底图是大对象，落盘要处理清理/配额，收益不抵成本）
//   · IN_PROGRESS 不写缓存（那时根本没有图）
//   · 排版失败不删缓存（这正是它存在的理由）
//
// 清理时机（全部有对应入口，不靠"反正有 TTL"）：
//   · 排版成功   → markOverlayDone(会话, 任务)，保留到 TTL/容量淘汰，支持只改文案
//   · 用户取消   → evict(conversationId:)               清该会话全部
//   · 会话删除   → evict(conversationId:)               同上
//   · 任务超时   → lookup/save 内 sweep + evictExpired()
//   · App 退出   → evictAll()（见 BossAIApp 生命周期）
//   · 容量上限   → maxEntries 按 createdAt 淘汰最老

struct BaseImageEntry {
    let taskId: String
    let conversationId: String
    let baseImage: UIImage
    let aspectRatio: String
    let createdAt: Date
    var overlayDone: Bool
}

enum CacheLookup: Equatable {
    case hit
    case missNoEntry
    case missConversation          // 别的会话的底图，禁止复用
    case missTaskId                // 任务不匹配
    case missAspect                // 比例变了，必须重画
    case missExpired               // 超时，淘汰
}

/// 多任务并发的底图缓存：键 = conversationId + taskId，内部加锁。
final class BaseImageCache {
    static let shared = BaseImageCache()

    /// 缓存寿命：15 分钟。超时视为淘汰，避免内存长期占用。
    let ttl: TimeInterval = 15 * 60
    /// 同时在手的底图上限：解码后每张约 5~10MB，4 张已是 40MB 量级，再多是拿内存换小概率命中。
    let maxEntries = 4

    /// 所有读写都在这把锁内完成。缓存也会被主线程之外的生命周期回调（App 退出）碰到，
    /// 所以锁是**必须**的，不能假设"反正都在主线程"。
    private let lock = NSLock()
    /// key = "\(conversationId)|\(taskId)"；两者都是 UUID / 十六进制串，天然不含分隔符
    private var storage: [String: BaseImageEntry] = [:]

    private init() {}

    private func cacheKey(_ conversationId: String, _ taskId: String) -> String {
        conversationId + "|" + taskId
    }

    /// 该会话是否已有底图（用于区分"任务不匹配"与"别的会话的图"）
    private func hasConversationLocked(_ conversationId: String) -> Bool {
        let prefix = conversationId + "|"
        return storage.keys.contains { $0.hasPrefix(prefix) }
    }

    /// 清掉所有过期条目。调用方必须已持锁。
    private func sweepExpiredLocked(now: Date) {
        let expired = storage.filter { now.timeIntervalSince($0.value.createdAt) > ttl }.map { $0.key }
        guard !expired.isEmpty else { return }
        for key in expired { storage.removeValue(forKey: key) }
        PerformanceTrace.event("cache_evicted")
    }

    /// 超出容量时按创建时间淘汰最老的（调用方必须已持锁）
    private func trimLocked() {
        let overflow = storage.count - maxEntries
        guard overflow > 0 else { return }
        let oldest = storage.sorted { $0.value.createdAt < $1.value.createdAt }.prefix(overflow)
        for (key, _) in oldest { storage.removeValue(forKey: key) }
        PerformanceTrace.event("cache_evicted")
    }

    // MARK: - 读写

    func save(taskId: String,
              conversationId: String,
              baseImage: UIImage,
              aspectRatio: String,
              now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        sweepExpiredLocked(now: now)
        storage[cacheKey(conversationId, taskId)] = BaseImageEntry(taskId: taskId,
                                                                  conversationId: conversationId,
                                                                  baseImage: baseImage,
                                                                  aspectRatio: aspectRatio,
                                                                  createdAt: now,
                                                                  overlayDone: false)
        trimLocked()
        PerformanceTrace.event("cache_saved")
    }

    /// 查命中。命中后调用方**不得**再调 Pro。
    func lookup(conversationId: String, taskId: String, aspectRatio: String, now: Date = Date()) -> CacheLookup {
        lock.lock()
        defer { lock.unlock() }
        guard !storage.isEmpty else {
            PerformanceTrace.event("cache_miss")
            return .missNoEntry
        }
        let key = cacheKey(conversationId, taskId)
        // 命中的那条先判过期：missExpired 与 missNoEntry 必须是两种不同信号，
        // 否则"缓存超时"会被误读成"从来没缓存过"，排查时看不出差别。
        if let entry = storage[key], now.timeIntervalSince(entry.createdAt) > ttl {
            storage.removeValue(forKey: key)
            PerformanceTrace.event("cache_evicted")
            return .missExpired
        }
        sweepExpiredLocked(now: now)
        guard let entry = storage[key] else {
            let sameConversation = hasConversationLocked(conversationId)
            PerformanceTrace.event("cache_miss")
            return sameConversation ? .missTaskId : .missConversation
        }
        guard entry.aspectRatio == aspectRatio else {
            PerformanceTrace.event("cache_invalidated")
            return .missAspect
        }
        PerformanceTrace.event("cache_hit")
        return .hit
    }

    /// 取命中的条目（lookup == .hit 后再取，避免连读两次状态）。
    /// 过期即视为没有，并顺手淘汰。
    func entry(conversationId: String, taskId: String, now: Date = Date()) -> BaseImageEntry? {
        lock.lock()
        defer { lock.unlock() }
        let key = cacheKey(conversationId, taskId)
        guard let entry = storage[key] else { return nil }
        guard now.timeIntervalSince(entry.createdAt) <= ttl else {
            storage.removeValue(forKey: key)
            PerformanceTrace.event("cache_evicted")
            return nil
        }
        return entry
    }

    /// 当前缓存条目数（诊断/测试用）
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    // MARK: - 清理

    /// 完成排版后仍可复用底图；按 TTL/容量上限回收。
    func markOverlayDone(conversationId: String, taskId: String) {
        lock.lock()
        defer { lock.unlock() }
        let key = cacheKey(conversationId, taskId)
        guard storage[key] != nil else { return }
        storage[key]?.overlayDone = true
        PerformanceTrace.event("cache_overlay_completed")
    }

    /// 排版失败后**保留**缓存。
    /// 语义化占位：这里故意不删。单独成方法，是为了让「失败不删」成为显式契约，
    /// 而不是依赖某个调用点"忘了写 evict"这种偶然正确。
    func retainAfterOverlayFailure(conversationId: String, taskId: String) {
        lock.lock()
        defer { lock.unlock() }
        guard storage[cacheKey(conversationId, taskId)] != nil else { return }
        PerformanceTrace.event("cache_kept_after_overlay_failure")
    }

    /// 会话级清理：会话删除 / 用户取消 / 该会话任务已放弃。
    func evict(conversationId: String) {
        lock.lock()
        defer { lock.unlock() }
        let prefix = conversationId + "|"
        let keys = storage.keys.filter { $0.hasPrefix(prefix) }
        guard !keys.isEmpty else { return }
        for key in keys { storage.removeValue(forKey: key) }
        PerformanceTrace.event("cache_evicted")
    }

    /// 全清：App 退出、登出、账号切换。
    func evictAll() {
        lock.lock()
        defer { lock.unlock() }
        guard !storage.isEmpty else { return }
        storage.removeAll()
        PerformanceTrace.event("cache_evicted")
    }

    /// 只清过期的（App 进后台时调用：留活的，不留死的）
    func evictExpired(now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        sweepExpiredLocked(now: now)
    }

    /// 供测试重置
    func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
    }
}

// MARK: - 任务指纹（10-25 接线配套）

/// 底图任务的**确定性指纹**：同一次设计任务的多次调用必须算出同一个值，
/// 否则缓存永远命不中（每次换 UUID 等于没接缓存）。
///
/// 纳入指纹（变了就必须重画底图）：任务类型、比例、尺寸、质量档、视觉意图、
/// 非文字 structured 字段、完整参考图 SHA-256，以及剔除可见文案后的 prompt 骨架。
///
/// 故意排除：要绘制的文字值本身。用户把电话从 138… 改成 139… 时，
/// 底图一个像素都不用变——这正是缓存存在的理由。
enum BaseImageTaskKey {

    static func make(context: ImageRequestContext, items: [TextItem] = []) -> String {
        var normalized = context.prompt.lowercased()

        // ① 把「只影响叠字、不影响底图」的文本从 prompt 里抹掉。
        //    长串优先替换，避免短串先替换把长串切碎后留下残渣。
        let structuredCopy = TextItem.values(from: context.structured?["text"])
        let rawValues = items.map(\.text) + structuredCopy
        let textValues = Set(rawValues)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { $0.count >= 2 }
            .sorted { $0.count > $1.count }
        for value in textValues {
            normalized = normalized.replacingOccurrences(of: value, with: "◇")
        }

        // ② 折叠空白：同一需求的措辞常带换行/多空格差异，不该算成两个任务
        normalized = normalized
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")

        var visualFields = context.structured ?? [:]
        visualFields.removeValue(forKey: "text")
        let structuredFingerprint: String
        if !visualFields.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: visualFields,
                                                  options: [.sortedKeys, .fragmentsAllowed]) {
            structuredFingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        } else {
            // 不可序列化的工具参数不得导致两个不同请求错误共用同一张底图。
            structuredFingerprint = visualFields.isEmpty ? "none" : UUID().uuidString
        }

        // Length-prefix each value so user-provided delimiters cannot create ambiguous keys.
        let keyParts = [
            context.taskKind,
            context.aspectRatio,
            context.renderIntent,
            context.qualityTier,
            context.targetSize ?? "",
            String(context.requestedCount ?? 1),
            structuredFingerprint,
            normalized,
            context.references.map { referenceFingerprint($0) }.joined(separator: ","),
        ]
        let seed = keyParts.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        return fnv1a(seed)
    }

    /// 对完整参考图做 SHA-256。只取头尾会让常见 JPEG 头尾相同、尺寸相同的不同图片
    /// 意外命中同一缓存项，后续会把上一张图的底图错误用于当前设计。
    private static func referenceFingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// FNV-1a 64 位：输出仅作为进程内缓存键；参考图内容已由 SHA-256 覆盖。
    private static func fnv1a(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
