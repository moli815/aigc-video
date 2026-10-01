import Foundation
import SwiftData

// MARK: - 会话与消息（SwiftData 本地持久化）

@Model
final class Conversation {
    var id: UUID = UUID()
    /// 对应 ExpertCatalog 中的 expert.id（"general" 为普通对话）
    var expertId: String = "general"
    var title: String = ""
    var createdAt: Date = Date()
    @Relationship(deleteRule: .cascade, inverse: \Message.conversation)
    var messages: [Message] = []

    init(expertId: String, title: String) {
        self.expertId = expertId
        self.title = title
    }
}

@Model
final class Message {
    var id: UUID = UUID()
    var role: String = "user"          // user / assistant
    var text: String = ""
    var imageData: Data? = nil         // 生成的图片（assistant 消息）
    var createdAt: Date = Date()
    var conversation: Conversation?

    init(role: String, text: String, imageData: Data? = nil) {
        self.role = role
        self.text = text
        self.imageData = imageData
    }
}

// MARK: - 长期记忆

@Model
final class MemoryItem {
    var id: UUID = UUID()
    var content: String = ""
    var createdAt: Date = Date()
    var hitCount: Int = 0

    init(content: String) {
        self.content = content
    }
}

// MARK: - 用户身份（显式设置，UserDefaults 持久化）

struct UserIdentity: Codable {
    var name: String = ""
    var company: String = ""
    var industry: String = ""
    var role: String = ""
    var goal: String = ""

    var isEmpty: Bool {
        [name, company, industry, role, goal].allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var promptFragment: String {
        guard !isEmpty else { return "" }
        return """

        【对话者身份】姓名：\(name)；公司：\(company)；行业：\(industry)；身份：\(role)；当前诉求：\(goal)。
        请结合以上身份背景，给出更贴合其实际经营场景的回答。
        """
    }

    private static let storageKey = "bossai.user_identity"

    static func load() -> UserIdentity {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let value = try? JSONDecoder().decode(UserIdentity.self, from: data) else {
            return UserIdentity()
        }
        return value
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
