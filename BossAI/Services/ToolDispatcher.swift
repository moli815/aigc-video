import Foundation

/// Shared admission gate, used before parallel scheduling and again before execution.
enum ToolDispatcher {
    static func validate(_ call: ChatService.ToolCall, policy: EffectiveToolPolicy) throws {
        guard policy.permits(call.name) else { throw ExpertSkillError.denied("当前配置未开放这项工具") }
        guard call.arguments.utf8.count <= 256 * 1024 else {
            throw ExpertSkillError.invalidInput("工具输入过长，请缩短后重试")
        }
        if call.name == "$web_search" { return }
        guard let raw = call.arguments.data(using: .utf8),
              let args = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else {
            throw ExpertSkillError.invalidInput("工具输入未解析完整，请重新提交需求")
        }
        if call.name == "create_document" {
            guard let format = DocumentUseCase.format(args["format"] as? String ?? "word"),
                  policy.docFormats.contains(format.rawValue) else {
                throw ExpertSkillError.denied("当前配置未开放这种文档格式")
            }
        }
    }
}
