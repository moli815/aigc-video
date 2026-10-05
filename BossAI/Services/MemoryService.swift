import Foundation
import SwiftData

/// 长期记忆服务：后台用轻量模型从对话中抽取事实，去重后写入本地 SwiftData。
/// 注入时拼进 system prompt，效果对齐 ChatGPT 记忆。
@MainActor
final class MemoryService {
    private let profile: ChatProfile
    private let apiKeyProvider: () -> String?
    init(profile: ChatProfile, apiKeyProvider: @escaping () -> String?) {
        self.profile = profile
        self.apiKeyProvider = apiKeyProvider
    }

    /// 注入用：返回「【关于用户的已知信息】」片段
    func injectionFragment(context: ModelContext) -> String {
        let descriptor = FetchDescriptor<MemoryItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let items = (try? context.fetch(descriptor)) ?? []
        guard !items.isEmpty else { return "" }
        let limited = Array(items.prefix(AppConfig.memoryInjectLimit))
        let lines = limited.enumerated().map { "\($0.offset + 1). \($0.element.content)" }
        return "\n\n【关于用户的已知信息】\n" + lines.joined(separator: "\n")
    }

    /// 后台抽取：对照现有记忆返回 add/update/skip 操作并落库。
    /// source：本条记忆来自哪段对话（会话标题），落到每条记忆上，供查看与纠错定位。
    func extract(from recentDialogue: String, source: String = "", context: ModelContext) async {
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else { return }

        let existing = (try? context.fetch(FetchDescriptor<MemoryItem>())) ?? []
        let existingList = existing.enumerated()
            .map { "[\($0.offset)] \($0.element.content)" }
            .joined(separator: "\n")

        let prompt = """
        你在维护一份关于用户的长期记忆库。从下面【新对话】中抽取值得长期记住的事实\
        （公司名、业务、人员、项目进展、用户偏好、已做的决策），对照【现有记忆】判断操作。
        规则：只输出 JSON 数组，每个元素形如 {"action":"add","content":"…"} 或 \
        {"action":"update","index":0,"content":"…"}；没有值得记住的内容则输出 []。\
        禁止记录临时性、情绪性、一次性的内容。最多 5 条。

        【现有记忆】
        \(existingList.isEmpty ? "（空）" : existingList)

        【新对话】
        \(recentDialogue)
        """

        var request = URLRequest(url: URL(string: "\(profile.baseURL)/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        let body: [String: Any] = [
            "model": profile.memoryModel,
            "messages": [["role": "user", "content": prompt]],
            "temperature": 0.1,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { return }

        // 容错提取 JSON 数组
        guard let start = content.firstIndex(of: "["),
              let end = content.lastIndex(of: "]"),
              let ops = try? JSONSerialization.jsonObject(with: Data(content[start...end].utf8)) as? [[String: Any]]
        else { return }

        for op in ops {
            guard let action = op["action"] as? String,
                  let text = op["content"] as? String, !text.isEmpty else { continue }
            switch action {
            case "add":
                context.insert(MemoryItem(content: text, source: source))
            case "update":
                if let index = op["index"] as? Int, existing.indices.contains(index) {
                    existing[index].content = text
                    if !source.isEmpty { existing[index].source = source }
                } else {
                    context.insert(MemoryItem(content: text, source: source))
                }
            default:
                continue
            }
        }
        try? context.save()
    }
}
