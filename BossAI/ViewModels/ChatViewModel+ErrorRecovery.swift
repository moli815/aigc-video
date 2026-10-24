import Foundation
import SwiftUI
import UIKit
import SwiftData

// ============================================================================
// ChatViewModel+ErrorRecovery.swift —— 结构化错误的"最后一公里"（10-24 新增）
//
// 背景（P1-1）：服务端已经下发 actions / requestId / retryable，但客户端只有
// FriendlyError.actions() 这个数据层函数，**没有任何 UI 调用它**，也没有处理器。
// 结果：用户仍然只看到一句错误文本，按钮等于不存在。
//
// 本文件的职责：
//   1. 把服务端动作 ID 映射到**真实业务行为**（不是重发一句自然语言）；
//   2. 未知动作一律忽略（白名单由 FriendlyError.actions 维护）；
//   3. 组图"只重试失败项"的入口：复用父任务 requestId，服务端保证不重跑已成功的图。
//
// 明确不做：不在这里做导航（会员页/登录页由 View 层接管），避免 VM 依赖 UI。
// ============================================================================

@MainActor
extension ChatViewModel {

    /// 服务端受控动作 → 本地真实行为。
    /// 注意：`renew` / `view_quota` / `relogin` 涉及页面跳转，由 ChatView 拦截处理；
    /// 这里只兜底"什么都不做"之外的安全行为。
    func handleErrorAction(_ id: String) {
        switch id {
        case "retry":
            if pendingSeriesRetry != nil {
                Task { await retryFailedSeries() }
            } else if canRetryReply {
                retryReply()
            } else {
                sendFollowUp("请按刚才的要求再试一次。")
            }

        case "edit_request":
            // 把上一条用户输入放回输入框，**不自动发送** —— 用户需要能改需求
            if let last = sortedMessages.last(where: { $0.role == "user" })?.text, !last.isEmpty {
                inputText = last
            }
            errorEnvelope = nil
            errorMessage = nil
            toast = "已把刚才的要求放回输入框，改完再发。"

        case "cancel":
            pendingSeriesRetry = nil
            errorEnvelope = nil
            errorMessage = nil

        case "single_only":
            // 组图能力/额度不足时的降级：明确告诉模型只做一张，不静默改变用户要求
            sendFollowUp("这次先只生成 1 张，其余的先不生成。")

        case "contact_support", "feedback":
            copyDiagnosticId()

        default:
            // 未知动作：不执行、不显示空按钮
            break
        }
    }

    /// 把 requestId 复制到剪贴板（反馈问题时可直接粘贴给客服）。
    /// 不上报任何密钥/完整对话内容，只给一个能查日志的编号。
    func copyDiagnosticId() {
        let rid = errorEnvelope?.requestId ?? ""
        guard !rid.isEmpty else {
            toast = "这次没有可用的诊断编号"
            return
        }
        UIPasteboard.general.string = rid
        toast = "问题编号已复制：\(rid)"
    }

    /// 组图"只重试失败项"（P0-2 / P1-5 的客户端半边）。
    /// 服务端语义：成功的子任务 claim 命中直接复用，不会重新生成、不会重复扣费。
    func retryFailedSeries() async {
        guard let ctx = pendingSeriesRetry, !isRetryingSeries, !isStreaming else { return }
        isRetryingSeries = true
        statusText = "正在补画失败的图片…"
        defer {
            isRetryingSeries = false
            statusText = nil
        }
        do {
            let outcome = try await imageService.retryFailedSeries(
                parentRequestId: ctx.requestId,
                indices: ctx.failedIndices
            )
            let images = outcome.succeededItems.compactMap(\.imageData)
            let meta = SeriesMeta(
                requestId: outcome.requestId,
                requested: outcome.requested,
                succeeded: images.count,
                failedIndices: outcome.failedIndices,
                downloadFailedIndices: outcome.downloadFailedIndices,
                pricedCny: outcome.pricedCny,
                committedCny: outcome.committedCny,
                pendingCostCount: outcome.pendingCostCount,
                partial: outcome.partial,
                size: outcome.size,
                qualityTier: outcome.qualityTier
            )
            if let mid = ctx.messageID,
               let msg = conversation?.messages.first(where: { $0.id == mid }) {
                try ToolPipeline.updateSeriesArtifact(msg, images: images, meta: meta, context: modelContext)
            }
            // 只把**新生成**的张数计入本地预算（复用的不应重复计）
            let newlyGenerated = outcome.items.filter { $0.ok && !$0.reused }.count
            if newlyGenerated > 0 { BudgetTracker.addImageGeneration(newlyGenerated) }

            if meta.failedIndices.isEmpty {
                pendingSeriesRetry = nil
                errorEnvelope = nil
                errorMessage = nil
                toast = "已补齐，共 \(images.count) 张"
            } else {
                pendingSeriesRetry = SeriesRetryContext(requestId: outcome.requestId,
                                                        failedIndices: meta.failedIndices,
                                                        messageID: ctx.messageID)
                toast = "还差 \(meta.failedIndices.count) 张，可以再试一次"
            }
        } catch {
            adopt(error)
        }
    }

    /// 统一吸收错误：写文案 + 保留信封（供 UI 渲染按钮）+ 记录组图重试上下文。
    func adopt(_ error: Error) {
        errorMessage = error.localizedDescription
        // 图片与对话两类错误都实现了 APIErrorCarrying：这里只认协议、不认具体类型，
        // 以后新增模块只要带上信封就自动获得按钮能力。
        guard let env = (error as? any APIErrorCarrying)?.envelope else { return }
        errorEnvelope = env
        if !env.failedIndices.isEmpty {
            pendingSeriesRetry = SeriesRetryContext(requestId: env.requestId,
                                                    failedIndices: env.failedIndices,
                                                    messageID: pendingSeriesRetry?.messageID)
        }
    }

    /// 组图回注文案：真实报告张数与失败序号，禁止重跑已成功的图。
    /// 放在扩展里而不是 Streaming（那里已有 800 行，越加越难读）。
    nonisolated static func seriesNote(outcome: ImageService.SeriesOutcome, meta: SeriesMeta) -> String {
        let okList = outcome.items.filter { $0.ok }.map { "#\($0.index)" }.joined(separator: "、")
        var lines = ["组图已完成 \(outcome.succeededCount)/\(outcome.requested) 张并已保存到本地。"]
        if !okList.isEmpty { lines.append("成功：\(okList)") }
        if !meta.failedIndices.isEmpty {
            let failed = meta.failedIndices.map { "#\($0)" }.joined(separator: "、")
            lines.append("失败：\(failed)")
            lines.append("必须如实告诉用户成功几张、哪几张失败，并给出两个选项：「重试失败的几张」或「保留已完成的」；禁止重跑已成功的图。")
        }
        if !meta.downloadFailedIndices.isEmpty {
            let dl = meta.downloadFailedIndices.map { "#\($0)" }.joined(separator: "、")
            lines.append("\(dl) 已生成但下载到本机失败——不要重新生成，提示用户稍后重新保存。")
        }
        return lines.joined(separator: "\n")
    }

    /// 清空错误状态（用户切会话、重新发送时调用）
    func clearErrorState() {
        errorEnvelope = nil
        errorMessage = nil
        pendingSeriesRetry = nil
    }
}
