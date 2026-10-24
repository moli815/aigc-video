import Foundation
import SwiftData

// ============================================================================
// ChatViewModel+Series.swift —— 组图任务执行（10-24 P1-5）
//
// 为什么单独一个文件：组图现在不是「一次请求拿 N 张」，而是
//   start → 多次 step（并发 2）→ 可选 cancel / 续跑
// 把这套编排塞进 ChatViewModel+Streaming 的 switch 里既难读，也会拖慢类型检查。
//
// 关键约束：
//   1. 每张只发一次 step；服务端按 index 幂等（已成功的直接返回，不重跑、不重复扣费）；
//   2. 每批完成就落库一次，用户能看到 2/4 → 4/4，而不是等全部跑完才出现；
//   3. 用户中途停止 → 调 /series/cancel，已生成的图保留，未开始的不再生成；
//   4. start 失败（老服务端没有这套接口）→ 回退旧的单请求组图路径。
// ============================================================================

/// 一次组图执行的结果（给调用方拼工具回注与本地预算用）。
struct SeriesRunOutcome {
    var message: Message?
    var requested: Int = 0
    var succeeded: Int = 0
    var failedIndices: [Int] = []
    var pendingIndices: [Int] = []
    var downloadFailedIndices: [Int] = []
    var taskId: String = ""
    var requestId: String = ""
    var status: String = ""
    var pricedCny: Double = 0
    var committedCny: Double = 0
    var pendingCostCount: Int = 0
    var partial: Bool = false
    var size: String = ""
    var qualityTier: String = ""
    var newlyGenerated: Int = 0
    var cancelled: Bool = false
    var usedLegacyPath: Bool = false
    /// 中途某一次 step 失败的原因（仅用于日志，不直接展示）
    var stepError: String = ""
}

@MainActor
extension ChatViewModel {

    /// 跑一次组图任务。
    /// - Parameters:
    ///   - existingMessageID: 续跑时传原消息 id（原地合并，不新增消息）
    func runSeriesTask(prompt: String,
                       requestedCount: Int,
                       structured: [String: Any]?,
                       renderIntent: String,
                       aspectRatio: String,
                       qualityTier: String,
                       conversation: Conversation,
                       existingMessageID: UUID? = nil) async throws -> SeriesRunOutcome {
        let n = max(2, min(4, requestedCount))
        let requestId = UUID().uuidString

        statusText = "正在创建组图任务…"
        let started: ImageService.SeriesTaskSnapshot
        do {
            started = try await imageService.startSeries(
                prompt: prompt, requestId: requestId, requestedCount: n,
                qualityTier: qualityTier, aspectRatio: aspectRatio,
                renderIntent: renderIntent, structured: structured
            )
        } catch {
            // start 这一步还没生成任何图，回退是安全的（不会重复扣费）。
            // 触发场景：服务端还是旧版本（没有 /series/start）、或任务创建失败。
            return try await runSeriesLegacy(
                prompt: prompt, requestedCount: n, structured: structured,
                renderIntent: renderIntent, aspectRatio: aspectRatio,
                qualityTier: qualityTier, conversation: conversation,
                existingMessageID: existingMessageID, startError: error
            )
        }
        defer { statusText = nil }

        var images: [Int: Data] = [:]
        for item in started.items where item.ok {
            if let d = item.imageData { images[item.index] = d }
        }
        var outcome = SeriesRunOutcome()
        outcome.requested = started.requested
        outcome.taskId = started.taskId
        outcome.requestId = started.requestId
        outcome.size = started.size
        outcome.qualityTier = started.qualityTier

        // 先落一次库：续跑时已有图片要立刻可见
        var messageID = existingMessageID
        if !images.isEmpty {
            let msg = try? persistSeriesImages(conversation: conversation,
                                               messageID: messageID,
                                               images: images,
                                               meta: makeSeriesMeta(from: started, images: images))
            outcome.message = msg
            messageID = msg?.id ?? messageID
        }

        var remaining = started.pendingIndices
        let total = started.requested
        do {
            while !remaining.isEmpty {
                try Task.checkCancellation()
                statusText = "正在生成第 \(max(1, total - remaining.count + 1))/\(total) 张…"
                let batch = Array(remaining.prefix(2))
                remaining.removeFirst(min(2, remaining.count))
                let results = try await imageService.runSteps(taskId: started.taskId,
                                                              indices: batch,
                                                              maxConcurrent: 2)
                for r in results {
                    if let d = r.imageData {
                        images[r.index] = d
                        outcome.newlyGenerated += 1
                    }
                }
                // 每批更新一次：用户能看见进度推进，而不是长时间空白
                let snap = (try? await imageService.seriesStatus(taskId: started.taskId)) ?? started
                let msg = try? persistSeriesImages(conversation: conversation,
                                                   messageID: messageID,
                                                   images: images,
                                                   meta: makeSeriesMeta(from: snap, images: images))
                if let msg { outcome.message = msg; messageID = msg.id }
            }
        } catch is CancellationError {
            // 用户停止：取消服务端任务（不再启动新的张数），已生成的全部保留
            cancelSeriesTask(started.taskId)
            outcome.cancelled = true
            ToolPipeline.reportFailure(pluginID: "image_series", reason: "用户取消组图任务",
                                       requestId: started.requestId, errorCode: "TASK_CANCELLED")
        } catch {
            // 单张失败不该把整个任务废掉：保留已完成的，剩下交给「继续生成 / 重试」
            outcome.stepError = error.localizedDescription
            ToolPipeline.reportFailure(pluginID: "image_series",
                                       reason: "step failed: \(error.localizedDescription)",
                                       requestId: started.requestId,
                                       errorCode: (error as? ImageService.ImageError)?.envelope?.code ?? "")
        }

        // 收尾：金额与失败序号一律以服务端最终状态为准
        let final = (try? await imageService.seriesStatus(taskId: started.taskId)) ?? started
        outcome.succeeded = images.count
        outcome.failedIndices = final.failedIndices
        outcome.pendingIndices = final.pendingIndices
        outcome.downloadFailedIndices = final.items.filter(\.downloadFailed).map(\.index)
        outcome.status = final.status
        outcome.pricedCny = final.pricedCny
        outcome.committedCny = final.committedCny
        outcome.pendingCostCount = final.pendingCostCount
        outcome.partial = final.partial
        outcome.cancelled = outcome.cancelled || final.isCancelled
        let msg = try? persistSeriesImages(conversation: conversation,
                                           messageID: messageID,
                                           images: images,
                                           meta: makeSeriesMeta(from: final, images: images))
        if let msg { outcome.message = msg }
        return outcome
    }

    /// 续跑：只处理服务端标记为「还没开始」的序号，已成功的不会重跑
    func resumeSeries(message: Message) async {
        guard let metaInfo = message.seriesMeta, metaInfo.canResume, !isRetryingSeries, !isStreaming else { return }
        isRetryingSeries = true
        statusText = "正在继续生成…"
        defer {
            isRetryingSeries = false
            statusText = nil
        }
        do {
            let snap = try await imageService.seriesStatus(taskId: metaInfo.taskId)
            var images: [Int: Data] = [:]
            for item in snap.items where item.ok {
                if let d = item.imageData { images[item.index] = d }
            }
            if !snap.pendingIndices.isEmpty {
                _ = try await imageService.runSteps(taskId: snap.taskId,
                                                    indices: snap.pendingIndices,
                                                    maxConcurrent: 2)
            }
            let final = (try? await imageService.seriesStatus(taskId: snap.taskId)) ?? snap
            for item in final.items where item.ok {
                if let d = item.imageData { images[item.index] = d }
            }
            try ToolPipeline.updateSeriesArtifact(message,
                                                 images: orderedImages(images),
                                                 meta: makeSeriesMeta(from: final, images: images),
                                                 context: modelContext)
            let newly = final.items.filter { $0.ok && !$0.reused }.count
            if newly > 0 { BudgetTracker.addImageGeneration(newly) }
            if final.pendingIndices.isEmpty && final.failedIndices.isEmpty {
                pendingSeriesRetry = nil
                errorEnvelope = nil
                toast = "组图已全部完成，共 \(images.count) 张"
            } else {
                pendingSeriesRetry = SeriesRetryContext(requestId: final.requestId,
                                                        failedIndices: final.failedIndices,
                                                        messageID: message.id)
                toast = "已完成 \(images.count)/\(final.requested) 张"
            }
        } catch {
            adopt(error)
        }
    }

    /// 取消当前任务（用户点停止时调用）：已生成的保留，未开始的不再生成。
    ///
    /// 关键：这里必须用 detached 任务发出去。用户点停止时，外层 runLoop 的 Task 已被 cancel，
    /// 在同一个（已取消的）任务里发请求会立刻抛 URLError.cancelled —— 服务端根本收不到取消，
    /// 任务会一直停在 running，继续消耗额度。
    func cancelSeriesTask(_ taskId: String) {
        guard !taskId.isEmpty else { return }
        let service = imageService
        Task.detached(priority: .utility) {
            _ = try? await service.cancelSeries(taskId: taskId)
        }
    }

    // MARK: - 旧路径回退（服务端还没升级时）

    private func runSeriesLegacy(prompt: String,
                                 requestedCount: Int,
                                 structured: [String: Any]?,
                                 renderIntent: String,
                                 aspectRatio: String,
                                 qualityTier: String,
                                 conversation: Conversation,
                                 existingMessageID: UUID?,
                                 startError: Error) async throws -> SeriesRunOutcome {
        let legacy = try await Self.generateSeriesWithRetry(
            prompt: prompt, references: [], service: imageService,
            requestedCount: requestedCount, structured: structured,
            renderIntent: renderIntent, aspectRatio: aspectRatio, qualityTier: qualityTier
        )
        var images: [Int: Data] = [:]
        for item in legacy.succeededItems { images[item.index] = item.imageData }

        var metaOut = SeriesMeta()
        metaOut.requestId = legacy.requestId
        metaOut.requested = legacy.requested
        metaOut.succeeded = images.count
        metaOut.failedIndices = legacy.failedIndices
        metaOut.downloadFailedIndices = legacy.downloadFailedIndices
        metaOut.pricedCny = legacy.pricedCny
        metaOut.committedCny = legacy.committedCny
        metaOut.pendingCostCount = legacy.pendingCostCount
        metaOut.partial = legacy.partial
        metaOut.size = legacy.size
        metaOut.qualityTier = legacy.qualityTier

        var outcome = SeriesRunOutcome()
        outcome.usedLegacyPath = true
        outcome.requested = legacy.requested
        outcome.requestId = legacy.requestId
        outcome.succeeded = images.count
        outcome.failedIndices = legacy.failedIndices
        outcome.downloadFailedIndices = legacy.downloadFailedIndices
        outcome.pricedCny = legacy.pricedCny
        outcome.committedCny = legacy.committedCny
        outcome.pendingCostCount = legacy.pendingCostCount
        outcome.partial = legacy.partial
        outcome.size = legacy.size
        outcome.qualityTier = legacy.qualityTier
        outcome.newlyGenerated = legacy.items.filter { $0.ok && !$0.reused }.count
        outcome.message = try persistSeriesImages(conversation: conversation,
                                                  messageID: existingMessageID,
                                                  images: images, meta: metaOut)
        // 回退原因进日志，不展示给用户
        ToolPipeline.reportFailure(pluginID: "image_series",
                                   reason: "start failed, fell back to legacy: \(startError.localizedDescription)",
                                   errorCode: (startError as? ImageService.ImageError)?.envelope?.code ?? "")
        return outcome
    }

    // MARK: - 落库与元信息

    private func orderedImages(_ map: [Int: Data]) -> [Data] {
        map.keys.sorted().compactMap { map[$0] }
    }

    private func makeSeriesMeta(from snap: ImageService.SeriesTaskSnapshot, images: [Int: Data]) -> SeriesMeta {
        var m = SeriesMeta()
        m.requestId = snap.requestId
        m.taskId = snap.taskId
        m.status = snap.status
        m.requested = snap.requested
        m.succeeded = images.count
        m.failedIndices = snap.failedIndices
        m.pendingIndices = snap.pendingIndices
        m.downloadFailedIndices = snap.items.filter(\.downloadFailed).map(\.index)
        m.pricedCny = snap.pricedCny
        m.committedCny = snap.committedCny
        m.pendingCostCount = snap.pendingCostCount
        m.partial = snap.partial
        m.size = snap.size
        m.qualityTier = snap.qualityTier
        return m
    }

    /// 有 messageID 就原地更新，否则新建一条（组图消息只应有一条）
    @discardableResult
    private func persistSeriesImages(conversation: Conversation,
                                     messageID: UUID?,
                                     images: [Int: Data],
                                     meta: SeriesMeta) throws -> Message {
        let ordered = orderedImages(images)
        if let messageID, let existing = conversation.messages.first(where: { $0.id == messageID }) {
            try ToolPipeline.updateSeriesArtifact(existing, images: ordered, meta: meta, context: modelContext)
            return existing
        }
        return try ToolPipeline.persistSeriesArtifact(conversation: conversation,
                                                      images: ordered, meta: meta,
                                                      context: modelContext)
    }

    /// 工具回注：只报真实张数与失败序号，并明确「不要重跑已成功的图」
    nonisolated static func seriesTaskNote(_ outcome: SeriesRunOutcome) -> String {
        var lines: [String] = []
        if outcome.cancelled {
            lines.append("组图已取消：已完成 \(outcome.succeeded)/\(outcome.requested) 张，已完成的图片已保留。")
        } else {
            lines.append("组图已完成 \(outcome.succeeded)/\(outcome.requested) 张并已保存到本地。")
        }
        if !outcome.failedIndices.isEmpty {
            let failed = outcome.failedIndices.map { "#\($0)" }.joined(separator: "、")
            lines.append("失败：\(failed)")
            lines.append("必须如实告诉用户成功几张、哪几张失败，并给出两个选项：「重试失败的几张」或「保留已完成的」；禁止重跑已成功的图。")
        }
        if !outcome.pendingIndices.isEmpty {
            let pending = outcome.pendingIndices.map { "#\($0)" }.joined(separator: "、")
            lines.append("还没生成：\(pending)。告诉用户可以点「继续生成」补齐，不需要重新描述需求。")
        }
        if !outcome.downloadFailedIndices.isEmpty {
            let dl = outcome.downloadFailedIndices.map { "#\($0)" }.joined(separator: "、")
            lines.append("\(dl) 已生成但下载到本机失败——不要重新生成，提示用户稍后重新保存。")
        }
        if !outcome.stepError.isEmpty {
            lines.append("中途有一次执行出错（已保留已完成的部分），剩余张数可以用「继续生成」补齐。")
        }
        return lines.joined(separator: "\n")
    }
}
