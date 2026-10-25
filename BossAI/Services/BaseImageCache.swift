import Foundation
import UIKit

// BaseImageCache.swift —— 无字底图缓存（2026-10-25）
//
// 目的只有一个：**排版失败或用户只改文字时，不要重新调 Pro**。
// 一次 Pro 底图 0.45 元、20~30 秒；改个电话号码就重画一张，是纯浪费。
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

struct BaseImageEntry {
    let taskId: String
    let conversationId: String
    let baseImage: UIImage
    let aspectRatio: String
    let extractedText: [String: String]
    let items: [TextItem]
    let layout: LayoutSpec
    let canvas: CanvasSpec
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

/// 单会话、单条目的缓存：够用且不会无限增长。
/// 需要多任务并行时再改成字典（当前一次只跑一条图片任务）。
final class BaseImageCache {
    static let shared = BaseImageCache()

    /// 缓存寿命：15 分钟。超时视为淘汰，避免内存长期占用。
    let ttl: TimeInterval = 15 * 60

    private(set) var entry: BaseImageEntry?

    private init() {}

    // MARK: - 读写

    func save(taskId: String,
              conversationId: String,
              baseImage: UIImage,
              aspectRatio: String,
              extractedText: [String: String],
              items: [TextItem],
              layout: LayoutSpec,
              canvas: CanvasSpec,
              now: Date = Date()) {
        entry = BaseImageEntry(taskId: taskId,
                               conversationId: conversationId,
                               baseImage: baseImage,
                               aspectRatio: aspectRatio,
                               extractedText: extractedText,
                               items: items,
                               layout: layout,
                               canvas: canvas,
                               createdAt: now,
                               overlayDone: false)
        PerformanceTrace.event("cache_saved")
    }

    /// 查命中。命中后调用方**不得**再调 Pro。
    func lookup(conversationId: String, taskId: String, aspectRatio: String, now: Date = Date()) -> CacheLookup {
        guard let e = entry else {
            PerformanceTrace.event("cache_miss")
            return .missNoEntry
        }
        if now.timeIntervalSince(e.createdAt) > ttl {
            entry = nil
            PerformanceTrace.event("cache_evicted")
            return .missExpired
        }
        guard e.conversationId == conversationId else {
            PerformanceTrace.event("cache_miss")
            return .missConversation
        }
        guard e.taskId == taskId else {
            PerformanceTrace.event("cache_miss")
            return .missTaskId
        }
        guard e.aspectRatio == aspectRatio else {
            PerformanceTrace.event("cache_invalidated")
            return .missAspect
        }
        PerformanceTrace.event("cache_hit")
        return .hit
    }

    /// 排版成功后清理（成品已出，底图不再需要）
    func markOverlayDoneAndEvict() {
        entry?.overlayDone = true
        entry = nil
        PerformanceTrace.event("cache_evicted")
    }

    /// 排版失败后**保留**缓存。
    /// 语义化占位：这里故意不删。单独成方法，是为了让「失败不删」成为显式契约，
    /// 而不是依赖某个调用点"忘了写 evict"这种偶然正确。
    func retainAfterOverlayFailure() {
        guard entry != nil else { return }
        PerformanceTrace.event("cache_kept_after_overlay_failure")
    }

    /// 会话切换 / 用户取消 / 任务放弃
    func evict() {
        guard entry != nil else { return }
        entry = nil
        PerformanceTrace.event("cache_evicted")
    }

    /// 供测试重置
    func resetForTesting() { entry = nil }
}

// MARK: - 任务指纹（10-25 接线配套）

/// 底图任务的**确定性指纹**：同一次设计任务的多次调用必须算出同一个值，
/// 否则缓存永远命不中（每次换 UUID 等于没接缓存）。
///
/// 纳入指纹（变了就必须重画底图）：
///   · taskKind（generate / edit / decompose …）
///   · aspectRatio（比例变了画布就变）
///   · renderIntent（平面稿 / 展示稿是两种画法）
///   · 参考图指纹（换了原图必须重画）
///   · prompt 骨架（**抹掉要绘制的文字值后**的主题描述）
///
/// 故意排除：要绘制的文字值本身。用户把电话从 138… 改成 139… 时，
/// 底图一个像素都不用变——这正是缓存存在的理由。
enum BaseImageTaskKey {

    static func make(context: ImageRequestContext, items: [TextItem] = []) -> String {
        var normalized = context.prompt.lowercased()

        // ① 把「只影响叠字、不影响底图」的文本从 prompt 里抹掉。
        //    长串优先替换，避免短串先替换把长串切碎后留下残渣。
        let rawValues = Array(context.extractedText.values) + items.map { $0.text }
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

        var seed = [context.taskKind, context.aspectRatio, context.renderIntent, normalized]
            .joined(separator: "|")
        seed += "|refs:" + context.references.map { referenceFingerprint($0) }.joined(separator: ",")
        return fnv1a(seed)
    }

    /// 参考图指纹：只取头尾各 256 字节 + 总长度。
    /// 不整图哈希——几 MB 的图每次算一遍哈希，省下的 0.45 元还不够付 CPU 时间。
    private static func referenceFingerprint(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data.prefix(256) {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        for byte in data.suffix(256) {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return String(format: "%016llx", hash ^ UInt64(data.count))
    }

    /// FNV-1a 64 位：不引入 CryptoKit，跨平台稳定，够用于缓存键
    private static func fnv1a(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
