import Foundation
import UIKit
import SwiftData

// ============================================================================
// ToolPipeline —— 工具执行统一管道（阶段二：成功 / 失败 / 落库的唯一路径）
//
// 根治三类历史问题（不再依赖"每个 case 记得写对"）：
//   · 防谎报：所有失败注入统一走 failureNote（强措辞），不会因某个工具漏写而失效
//   · 漏落库：所有产出物统一走 persistArtifact（含 modelContext.save），不会漏显示
//   · 文案漂移：成功/失败文案由 ToolRegistry 声明生成，改一处全局一致
// ============================================================================

enum ToolPipeline {

    /// 失败回注（统一防谎报）：任何工具失败都走这里（并顺带上报云端，供管理台诊断）
    static func failureNote(pluginID: String, reason: String, requestId: String = "", errorCode: String = "") -> String {
        reportFailure(pluginID: pluginID, reason: reason, requestId: requestId, errorCode: errorCode)
        let plugin = ToolRegistry.plugin(pluginID)
        let name = plugin?.displayName ?? pluginID
        let advice = plugin?.failureAdvice ?? "建议稍后重试"
        return """
        【严重错误：\(name)执行失败，用户没有收到任何产出】
        失败原因：\(reason)

        你必须严格遵守：
        1. 明确告诉用户这次没有成功；
        2. 简述上面的失败原因；
        3. \(advice)。

        禁止使用「已生成」「已完成」「已保存」「请查收」「已插入」等任何暗示成功的表述——本次调用没有产出任何东西，声称成功即是欺骗用户。
        """
    }

    /// 成功回注（统一格式）：任何工具成功都走这里
    static func successNote(pluginID: String, detail: String) -> String {
        let name = ToolRegistry.plugin(pluginID)?.displayName ?? pluginID
        return "\(name)已完成并展示给用户。\(detail)"
    }

    /// 产出物统一落库（含 save）：图片/文档/图表消息一律走这里——
    /// 历史上"生成了但没显示"就是因为某个分支漏了 save，此函数让这类问题在结构上不可能发生。
    @MainActor
    @discardableResult
    /// 10-22 修复：改为 throws。此前 `try? context.save()` 后无条件返回 msg，
    /// 保存失败时调用方仍向模型回「成功」——用户看到图，重开会话却没了。
    /// 现在失败会回滚插入并抛错，调用方必须据此返回失败文案。
    static func persistArtifact(conversation: Conversation,
                                imageData: Data? = nil,
                                attachmentIDs: String? = nil,
                                text: String = "",
                                context: ModelContext) throws -> Message {
        let msg = Message(role: "assistant", text: text)
        if let imageData {
            msg.imageData = imageData
            msg.thumbnailData = makeThumbnail(imageData)   // P0-69 缩略图分层
        }
        if let attachmentIDs { msg.attachmentIds = attachmentIDs }
        msg.conversation = conversation
        msg.conversationID = conversation.id
        context.insert(msg)
        do {
            try context.save()
        } catch {
            context.delete(msg)
            throw error
        }
        // 10-24：图片产物同时写入资料库。此前只挂会话消息，资料库里永远只有文档。
        // 放在 context.save() 之后：消息已确定落库，写库失败不影响这张图的展示与计费。
        if let imageData {
            LibraryImageWriter.save(imageData: imageData,
                                    conversationId: conversation.id,
                                    prompt: text,
                                    context: context)
        }
        return msg
    }

    /// 10-24 组图落库（P0-2）：多张图 + 元信息写进**同一条**消息。
    /// 每张图都真实落库，重开 App 仍能看到全部图片；保存失败照旧抛出，由调用方如实告知。
    @MainActor
    @discardableResult
    static func persistSeriesArtifact(conversation: Conversation,
                                      images: [Data],
                                      meta: SeriesMeta,
                                      text: String = "",
                                      context: ModelContext) throws -> Message {
        let msg = Message(role: "assistant", text: text)
        if let first = images.first {
            msg.imageData = first
            msg.thumbnailData = makeThumbnail(first)
        }
        if images.count > 1 {
            msg.extraImagesJSON = try? JSONEncoder().encode(Array(images.dropFirst()))
        }
        msg.seriesMetaJSON = (try? JSONEncoder().encode(meta))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        msg.conversation = conversation
        msg.conversationID = conversation.id
        context.insert(msg)
        do {
            try context.save()
        } catch {
            context.delete(msg)
            throw error
        }
        // 10-24：组图的**每一张**都要进资料库（去重按内容哈希，重试合并不会重复存）
        for data in images {
            LibraryImageWriter.save(imageData: data,
                                    conversationId: conversation.id,
                                    prompt: text,
                                    context: context)
        }
        return msg
    }

    /// 10-24 组图结果更新（重试失败项后合并）：
    /// 只替换图片与元信息，不新增消息 —— 否则历史里会出现两条"同一组图"。
    @MainActor
    static func updateSeriesArtifact(_ message: Message,
                                     images: [Data],
                                     meta: SeriesMeta,
                                     context: ModelContext) throws {
        // 重试后补上的图同样要进资料库（已存在的按指纹跳过）
        for data in images {
            LibraryImageWriter.save(imageData: data,
                                    conversationId: message.conversationID,
                                    prompt: message.text,
                                    context: context)
        }
        if let first = images.first {
            message.imageData = first
            message.thumbnailData = makeThumbnail(first)
        }
        message.extraImagesJSON = images.count > 1
            ? (try? JSONEncoder().encode(Array(images.dropFirst())))
            : nil
        message.seriesMetaJSON = (try? JSONEncoder().encode(meta))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        try context.save()
    }

    /// P0-69 缩略图生成（长边 400px、JPEG 0.7）：列表渲染用——防大图（2K 约数 MB）在列表滚动时卡顿；
    /// 小图原样返回；生成失败回退 nil（渲染层自动用原图）。
    static func makeThumbnail(_ data: Data) -> Data? {
        guard let img = UIImage(data: data) else { return nil }
        let maxSide: CGFloat = 400
        let longSide = max(img.size.width, img.size.height)
        guard longSide > maxSide else { return data }
        let scale = maxSide / longSide
        let target = CGSize(width: img.size.width * scale, height: img.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        let scaled = renderer.image { _ in img.draw(in: CGRect(origin: .zero, size: target)) }
        return scaled.jpegData(compressionQuality: 0.7)
    }

    /// 参数缺失的标准回注（统一）：模型漏传必需参数时明确报错而非静默失败
    static func missingArgsNote(pluginID: String, missing: [String]) -> String {
        let name = ToolRegistry.plugin(pluginID)?.displayName ?? pluginID
        return "【\(name)参数不完整】缺少：\(missing.joined(separator: "、"))；本次未执行。请补充参数后重新调用，或改用其他方式回答用户。"
    }

    /// P0-64 工具失败上报（fire-and-forget、静默）：业务错误对云端可见（此前只有崩溃上报）。
    /// 管理台可据此发现"某个能力在特定账号上持续失败"——在线定位问题、减少人工排查。
    static func reportFailure(pluginID: String, reason: String, requestId: String = "", errorCode: String = "") {
        guard HostedAccount.isHostedActive else { return }
        Task { @MainActor in
            guard let token = HostedAccount.shared.token,
                  let url = URL(string: AppConfig.hostedAPIBase + "/tool-event") else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !requestId.isEmpty { req.setValue(requestId, forHTTPHeaderField: "X-Request-Id") }
            // 10-24 P1-8：带上 requestId / errorCode，管理台能把"工具失败"与"服务端那次请求"对上
            var payload: [String: Any] = ["tool": pluginID, "reason": String(reason.prefix(300))]
            if !requestId.isEmpty { payload["requestId"] = requestId }
            if !errorCode.isEmpty { payload["errorCode"] = errorCode }
            req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
            // 10-23 P3：工具失败上报走受限网络客户端，响应体限制 256KB
            _ = try? await BoundedHTTPClient.data(for: req,
                                                  session: BoundedHTTPClient.searchSession,
                                                  limit: 256 * 1024)
        }
    }

    /// 结果截断（对照 Hermes max_result_size_chars）：超出该能力的上限时截断并注明——
    /// 防止超大结果挤爆上下文（Hermes 对此有 2KB 错误体 / 结果上限的双层防护）。
    static func boundResult(_ text: String, pluginID: String) -> String {
        let limit = ToolRegistry.plugin(pluginID)?.maxResultChars ?? 12000
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n…[结果过长已截断]"
    }
}
