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

    /// 会话切换 / 用户取消 / 任务放弃
    func evict() {
        guard entry != nil else { return }
        entry = nil
        PerformanceTrace.event("cache_evicted")
    }

    /// 供测试重置
    func resetForTesting() { entry = nil }
}
