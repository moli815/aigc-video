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
        【内部状态：\(name)本次没有产出任何东西】
        内部原因（**只给你自己看，禁止向用户复述或解释**）：\(reason)

        用简短自然语言说明本次没有完成；只根据已确认的错误类别给出下一步。
        如需重新选择图片、等待任务或重试保存，不能一律要求重新生成。
        可用建议：\(advice)。不得保证未被确认的扣费或服务器处理状态。

        禁止事项：
        1. 禁止使用「已生成/已完成/已保存/请查收/已插入」等暗示成功的表述；
        2. 禁止向用户解释技术原因、字段名、模型名、比例参数、requestId；
        3. 禁止建议用户「去 Canva / 用 PPT / 打开 PS / 找设计师」这类把活推回去的说法；
        4. 禁止描述你的执行过程（读了什么、改了什么、算了几版）。
        """
    }

    /// 成功回注（统一格式）：任何工具成功都走这里
    static func successNote(pluginID: String, detail: String) -> String {
        let name = ToolRegistry.plugin(pluginID)?.displayName ?? pluginID
        // 10-25：成功回注同样只给内部状态。界面文案由 ImageTaskStatus 决定，
        // 模型写长段"这版做了什么/设计思路"不会再进聊天区（见 ChatViewModel 的 visibleText）。
        return "\(name)已完成并展示给用户。给用户的回复控制在一句话内，不要复述执行过程或设计说明。\(detail)"
    }

    @MainActor @discardableResult
    static func persistArtifact(conversation: Conversation, imageData: Data? = nil,
        attachmentIDs: String? = nil, text: String = "", context: ModelContext) throws -> Message {
        try ArtifactRepository.persistArtifact(conversation: conversation, imageData: imageData,
            attachmentIDs: attachmentIDs, text: text, context: context)
    }
    @MainActor @discardableResult
    static func persistSeriesArtifact(conversation: Conversation, images: [Data], meta: SeriesMeta,
        text: String = "", context: ModelContext) throws -> Message {
        try ArtifactRepository.persistSeriesArtifact(conversation: conversation, images: images, meta: meta, text: text, context: context)
    }
    @MainActor static func updateSeriesArtifact(_ message: Message, images: [Data], meta: SeriesMeta, context: ModelContext) throws {
        try ArtifactRepository.updateSeriesArtifact(message, images: images, meta: meta, context: context)
    }
    static func makeThumbnail(_ data: Data) -> Data? { ArtifactRepository.makeThumbnail(data) }

    /// 参数缺失的标准回注（统一）：模型漏传必需参数时明确报错而非静默失败
    static func missingArgsNote(pluginID: String, missing: [String]) -> String {
        let name = ToolRegistry.plugin(pluginID)?.displayName ?? pluginID
        return "【\(name)参数不完整】缺少：\(missing.joined(separator: "、"))；本次未执行。请补充参数后重新调用，或改用其他方式回答用户。"
    }

    /// P0-64 工具失败上报（fire-and-forget、静默）：业务错误对云端可见（此前只有崩溃上报）。
    /// 管理台可据此发现"某个能力在特定账号上持续失败"——在线定位问题、减少人工排查。
    static func reportFailure(pluginID: String, reason: String, requestId: String = "", errorCode: String = "") {
        Task { @MainActor in
            // `reason` can contain user text or upstream payloads; do not upload it.
            DiagnosticQueue.shared.record(domain: pluginID, stage: "tool_failed",
                code: errorCode.isEmpty ? "TOOL_FAILED" : errorCode, requestId: requestId)
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
