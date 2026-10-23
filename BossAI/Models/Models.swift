import Foundation
import SwiftData

// Models.swift —— SwiftData 本地持久化模型 + 轻量值类型集合。
// 职责：定义会话（Conversation）、消息（Message）、长期记忆（MemoryItem）、
//       资料库文件（StoredFile）四个 @Model，以及文件分类、回复风格、用户身份等值类型。
// 在整个 App 中的角色：App 的数据基座；BossAIApp 的 modelContainer 按此四个模型建库，
// 云端同步（P0-18）与多账号隔离（P0-16）都依赖其中的字段。
// 关键设计决策与防呆冗余：
// 1) ownerKey 数据隔离：每条记录创建时写入 HostedAccount.scopeKey，
//    查询侧必须带 ownerKey 过滤——同一设备切换账号后互不可见，防止数据串号。
//    这是隔离的"写端锚点"；读取过滤在服务/视图层完成。
// 2) Conversation.messages 用 cascade 删除规则：删会话即删消息，无孤儿数据。
// 3) 枚举字段（kindRaw/categoryRaw）以 String 存储而非枚举类型，
//    保证 SwiftData schema 稳定、未来新增枚举值不炸老库。
// 4) UserIdentity 采用逐字段容错解码：旧版本缺字段（如 replyStyle）时给默认值，
//    升级不丢数据、不因解码失败回退全空。

// MARK: - 会话与消息（SwiftData 本地持久化）

/// 一段对话：归属某专家，级联持有全部消息与滚动摘要。
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
    /// 长会话滚动摘要（P0-3）：早期对话的要点压缩，随会话增长增量刷新
    var rollingSummary: String = ""
    /// 已纳入摘要的消息条数（避免重复摘要）
    var summarizedCount: Int = 0
    /// P0-16 数据隔离：归属账号键（同一设备多账号互不可见）
    var ownerKey: String = ""
    /// 10-22 同步墓碑（客户端半边）：软删除标记。删除只置位不物理删，
    /// 这样"本机删除"会随同步推上去，另一台设备拉取后也会标记删除，不会"删了又复活"。
    var isDeleted: Bool = false

    /// 初始化：ownerKey 固定为当前登录账号的 scopeKey（P0-16 数据隔离锚点）。
    init(expertId: String, title: String) {
        self.expertId = expertId
        self.title = title
        self.createdAt = Date()
        self.updatedAt = Date()
        self.ownerKey = HostedAccount.scopeKey   // P0-16 归属当前账号
    }

    /// 消息所属专家的动态解析值（不落库，按 expertId 实时查目录）。
    var expert: Expert { ExpertCatalog.find(expertId) }
}

/// 单条消息：角色、文本、来源引用 JSON、生成图片二进制与附件 ID 列表。
@Model
final class Message {
    var id: UUID = UUID()
    var role: String = "user"          // user / assistant
    var text: String = ""
    var sourcesJSON: String = ""
    var imageData: Data? = nil         // 生成的图片（assistant 消息）
    // P0-69 缩略图分层：列表渲染用（长边 400px）——原图直存导致"图多了列表变慢"，
    // 缩略图先渲染、点开预览才加载原图；老消息无缩略图自动回退原图（SwiftData 可选字段轻量迁移）
    var thumbnailData: Data? = nil
    /// 附件（StoredFile.id 的字符串形式，逗号分隔）
    var attachmentIds: String = ""
    var createdAt: Date = Date()
    var conversation: Conversation?
    var conversationID: UUID? = nil   // P0-46 冗余字段：供 @Query 派生视图按会话过滤（轻量迁移自动加列）

    init(role: String, text: String, imageData: Data? = nil) {
        self.role = role
        self.text = text
        self.imageData = imageData
        self.createdAt = Date()
    }

    /// 附件 ID 解析：逗号分隔字符串转数组，自动忽略空片段。
    var attachmentIdList: [String] {
        attachmentIds.split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }
}

// MARK: - 长期记忆

/// 长期记忆条目：跨会话注入 prompt 的用户事实/偏好，带命中统计供淘汰策略。
@Model
final class MemoryItem {
    var id: UUID = UUID()
    var content: String = ""
    var createdAt: Date = Date()
    var hitCount: Int = 0
    /// 来源：这条记忆从哪段对话抽取（会话标题），供查看与纠错时定位
    var source: String = ""
    /// P0-18 云端同步：归属账号键 + 最后修改时间
    var ownerKey: String = ""
    var updatedAt: Date = Date()

    init(content: String, source: String = "") {
        self.content = content
        self.source = source
        self.ownerKey = HostedAccount.scopeKey
    }
}

// MARK: - 资料库文件（本地沙盒保存，App 生成 + 用户上传）

/// 资料库文件来源：用户上传 或 AI 生成。
enum FileKind: String, Codable, CaseIterable, Identifiable {
    case uploaded
    case generated
    var id: String { rawValue }
    var displayName: String { self == .uploaded ? "我上传的" : "AI 生成的" }
    var symbol: String { self == .uploaded ? "square.and.arrow.up" : "sparkles" }
}

/// 文件大类：按扩展名归类，驱动资料库的图标与筛选标签。
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

    /// 按小写扩展名归类；未知扩展名一律归入 .other。
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

/// 资料库文件记录：元数据落 SwiftData，文件本体存沙盒 Files 目录（storedName 关联）。
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
    /// P0-16 数据隔离：归属账号键
    var ownerKey: String = ""

    /// 初始化：ownerKey 同样锚定当前账号（P0-16），文件随账号隔离。
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
        self.ownerKey = HostedAccount.scopeKey   // P0-16 归属当前账号
    }

    var kind: FileKind { FileKind(rawValue: kindRaw) ?? .uploaded }
    var category: FileCategory { FileCategory(rawValue: categoryRaw) ?? .other }

    /// 可读文件大小（ByteCountFormatter 本地化格式）。
    var sizeText: String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: Int64(byteCount))
    }
}

// MARK: - 回复风格

/// 回复风格：用户显式选择的语气档位，转成 system prompt 附加指令。
enum ReplyStyle: String, Codable, CaseIterable, Identifiable {
    case auto
    case formal
    case concise
    case detailed
    case friendly
    var id: String { rawValue }

    /// P0-19 风格描述（设置页"标题+描述"列表用，参考 WorkBuddy 样式）
    var styleDescription: String {
        switch self {
        case .auto: return "不设定特定风格，按场景自动判断。"
        case .formal: return "清晰、准确、值得信赖。"
        case .concise: return "简明扼要、不废话、直击要点。"
        case .detailed: return "展开讲透：背景、依据与完整建议。"
        case .friendly: return "温暖、平易近人、鼓励支持。"
        }
    }

    var displayName: String {
        switch self {
        case .auto: return "自动"
        case .formal: return "专业严谨"
        case .concise: return "简明扼要"
        case .detailed: return "详细展开"
        case .friendly: return "亲和友善"
        }
    }

    /// 注入 system prompt 的风格指令
    var prompt: String {
        switch self {
        case .auto: return ""
        case .formal: return "\n【回复风格】语气正式、专业、克制，多用书面语，结论严谨，适合对外材料。"
        case .concise: return "\n【回复风格】极度简洁，先给结论，多用要点，能一句话讲清的不写两句。"
        case .detailed: return "\n【回复风格】详尽展开，给出背景、依据、步骤与示例，宁可多不要缺。"
        case .friendly: return "\n【回复风格】语气亲切、有温度，多用口语化表达，先共情再给建议。"
        }
    }
}

// MARK: - 用户身份（显式设置，UserDefaults 持久化）

/// 用户身份档案：显式设置 + UserDefaults JSON 持久化，注入对话者背景。
struct UserIdentity: Codable {
    var name: String = ""
    var company: String = ""
    var industry: String = ""
    var role: String = ""
    var goal: String = ""
    var replyStyle: ReplyStyle = .auto

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

    /// 从 UserDefaults 读取；数据缺失或损坏时返回空档案（不抛错）。
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

    /// 容错解码：旧版本没有 replyStyle 字段时给默认值，不让读取失败
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        company = (try? c.decode(String.self, forKey: .company)) ?? ""
        industry = (try? c.decode(String.self, forKey: .industry)) ?? ""
        role = (try? c.decode(String.self, forKey: .role)) ?? ""
        goal = (try? c.decode(String.self, forKey: .goal)) ?? ""
        replyStyle = (try? c.decodeIfPresent(ReplyStyle.self, forKey: .replyStyle)) ?? .auto
    }

    init() {}
}
