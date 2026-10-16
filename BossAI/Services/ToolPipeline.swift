import Foundation
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
    static func failureNote(pluginID: String, reason: String) -> String {
        reportFailure(pluginID: pluginID, reason: reason)
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
    static func persistArtifact(conversation: Conversation,
                                imageData: Data? = nil,
                                attachmentIDs: String? = nil,
                                text: String = "",
                                context: ModelContext) -> Message {
        let msg = Message(role: "assistant", text: text)
        if let imageData { msg.imageData = imageData }
        if let attachmentIDs { msg.attachmentIds = attachmentIDs }
        msg.conversation = conversation
        msg.conversationID = conversation.id
        context.insert(msg)
        try? context.save()
        return msg
    }

    /// 参数缺失的标准回注（统一）：模型漏传必需参数时明确报错而非静默失败
    static func missingArgsNote(pluginID: String, missing: [String]) -> String {
        let name = ToolRegistry.plugin(pluginID)?.displayName ?? pluginID
        return "【\(name)参数不完整】缺少：\(missing.joined(separator: "、"))；本次未执行。请补充参数后重新调用，或改用其他方式回答用户。"
    }

    /// P0-64 工具失败上报（fire-and-forget、静默）：业务错误对云端可见（此前只有崩溃上报）。
    /// 管理台可据此发现"某个能力在特定账号上持续失败"——在线定位问题、减少人工排查。
    static func reportFailure(pluginID: String, reason: String) {
        guard HostedAccount.isHostedActive else { return }
        Task { @MainActor in
            guard let token = HostedAccount.shared.token,
                  let url = URL(string: AppConfig.hostedAPIBase + "/tool-event") else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["tool": pluginID, "reason": String(reason.prefix(300))])
            req.timeoutInterval = 10
            _ = try? await URLSession.shared.data(for: req)
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
