import Foundation
import SwiftData

// MARK: - 会话与消息（SwiftData 本地持久化）

@Model
final class Conversation {
    var id: UUID = UUID()
    /// 对应 ExpertCatalog 中的 expert.id
    var expertId: String = "general"
    var title: String = ""
    var createdAt: Date = Date()
    /// 最后活动时间：侧栏按此倒序排列
    var updatedAt: Date = Date()
    @Relationship(deleteRule: .cascade, inverse: \Message.conversation)
    var messages: [Message] = []

    init(expertId: String, title: String) {
        self.expertId = expertId
        self.title = title
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var expert: Expert { ExpertCatalog.find(expertId) }
}

@Model
final class Message {
    var id: UUID = UUID()
    var role: String = "user"          // user / assistant
    var text: String = ""
    var imageData: Data? = nil         // 生成的图片（assistant 消息）
    /// 附件（StoredFile.id 的字符串形式，逗号分隔）
    var attachmentIds: String = ""
    var createdAt: Date = Date()
    var conversation: Conversation?

    init(role: String, text: String, imageData: Data? = nil) {
        self.role = role
        self.text = text
        self.imageData = imageData
        self.createdAt = Date()
    }

    var attachmentIdList: [String] {
        attachmentIds.split(separator: ",").map(String.init).filter { !$0.isEmpty }
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

// MARK: - 资料库文件（本地沙盒保存，App 生成 + 用户上传）

enum FileKind: String, Codable, CaseIterable, Identifiable {
    case uploaded
    case generated
    var id: String { rawValue }
    var displayName: String { self == .uploaded ? "我上传的" : "AI 生成的" }
    var symbol: String { self == .uploaded ? "square.and.arrow.up" : "sparkles" }
}

enum FileCategory: String, Codable, CaseIterable, Identifiable {
    case pdf, document, spreadsheet, presentation, image, text, other
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pdf: return "PDF"
        case .document: return "文档"
        case .spreadsheet: return "表格"
        case .presentation: return "演示"
        case .image: return "图片"
        case .text: return "文本"
        case .other: return "其他"
        }
    }

    var symbol: String {
        switch self {
        case .pdf: return "doc.richtext"
        case .document: return "doc.text"
        case .spreadsheet: return "tablecells"
        case .presentation: return "rectangle.on.rectangle"
        case .image: return "photo"
        case .text: return "text.alignleft"
        case .other: return "doc"
        }
    }

    static func from(ext: String) -> FileCategory {
        switch ext.lowercased() {
        case "pdf": return .pdf
        case "doc", "docx", "rtf", "pages": return .document
        case "xls", "xlsx", "csv", "numbers": return .spreadsheet
        case "ppt", "pptx", "key": return .presentation
        case "png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tiff": return .image
        case "txt", "md", "markdown", "json", "xml", "html": return .text
        default: return .other
        }
    }
}

@Model
final class StoredFile {
    var id: UUID = UUID()
    /// 显示名（含扩展名）
    var name: String = ""
    /// 小写扩展名，不含点
    var ext: String = ""
    /// FileKind.rawValue
    var kindRaw: String = FileKind.uploaded.rawValue
    /// FileCategory.rawValue
    var categoryRaw: String = FileCategory.other.rawValue
    /// 相对 Files 目录的文件名
    var storedName: String = ""
    var byteCount: Int = 0
    var createdAt: Date = Date()
    /// 来源会话（可空字符串）
    var sourceConversationId: String = ""
    /// 抽取出的纯文本（供喂给模型 / 全文搜索）
    var textContent: String = ""
    var isFavorite: Bool = false

    init(name: String, ext: String, storedName: String,
         kind: FileKind, category: FileCategory,
         byteCount: Int, sourceConversationId: String = "",
         textContent: String = "") {
        self.name = name
        self.ext = ext
        self.storedName = storedName
        self.kindRaw = kind.rawValue
        self.categoryRaw = category.rawValue
        self.byteCount = byteCount
        self.sourceConversationId = sourceConversationId
        self.textContent = textContent
        self.createdAt = Date()
    }

    var kind: FileKind { FileKind(rawValue: kindRaw) ?? .uploaded }
    var category: FileCategory { FileCategory(rawValue: categoryRaw) ?? .other }

    var sizeText: String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: Int64(byteCount))
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
