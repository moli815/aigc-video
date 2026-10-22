//
//  BackupService.swift
//  BossAI（中防AI iPad App）— Services 层
//
//  文件职责：实现 App 的"全量备份 / 换机迁移"能力。把 SwiftData 数据库中的对话、
//  消息、图片、资料库文件、长期记忆，加上钥匙串里的用户身份与 API Key、各类设置，
//  打包成单个加密归档文件（.bossai），换设备时可通过密码一键导入恢复。
//
//  在整个 App 中的角色：属于数据安全的最后一道防线，被备份/恢复设置页调用；
//  与 FileStore（文件落盘）、KeychainHelper（密钥存取）、SwiftData ModelContext 直接协作。
//
//  关键设计决策：
//  - 加密：PBKDF2-SHA256（随机盐 + 12 万次迭代）从用户密码派生 256 位密钥，
//    再用 AES-256-GCM 加密整包，GCM 自带完整性校验（防篡改/防损坏）。
//  - 归档结构：自研轻量 ZIP 读写（ZipWriter/ZipReader），头部 magic "BOSSAI01" 用于快速识别文件类型。
//  - 容错解码：Manifest/SettingsDTO 的 init(from:) 全部用 decodeIfPresent + 默认值，
//    保证老版本备份在新版本 App 上仍可导入（向前兼容）。
//  - 导入采用"先预检、后落库"两阶段：先完整校验归档内所有条目（文件名安全、ID 去重、
//    大小一致、图片齐全），全部通过后再写入数据库，且失败时回滚 + 清理已落盘文件，不留脏数据。
//
//  防呆/安全冗余理由：
//  - 限制单文件 ≤32MB、总归档 ≤120MB，防止超大备份耗尽内存或磁盘。
//  - 导入时对 storedName 走 StorageBoundary.isSafeLeaf 校验，拒绝路径穿越攻击。
//  - 重活（打包、PBKDF2、解密、落盘）全部 Task.detached 移出主线程，避免卡 UI。
//  - 身份/Key/设置的覆盖由 ImportOptions 开关控制，防止"合并导入却静默覆盖本地配置"。
//
import Foundation
import SwiftData
import CryptoKit
import CommonCrypto
import Compression
import Security

/// 全量备份与迁移：把对话、消息、图片、资料库文件、长期记忆、身份、API Key 与各项设置
/// 打成一个**加密**文件，换设备时一键导入。
///
/// 安全设计：
/// - 用户密码经 PBKDF2-SHA256（随机盐 + 12 万次迭代）派生 256 位密钥
/// - 整个归档用 AES-256-GCM 加密并带完整性校验（改一个字节就解不开）
/// - 文件格式：`BOSSAI01`(8B) + salt(16B) + AES-GCM combined(nonce12 + 密文 + tag16)
enum BackupService {

    /// 魔数：写在加密文件最前 8 字节，用于快速识别"这是不是本 App 的备份文件"
    static let magic = "BOSSAI01"
    /// 备份文件的扩展名
    static let fileExtension = "bossai"
    /// PBKDF2 盐长度（字节）：随机盐保证相同密码每次派生出不同密钥
    private static let saltLength = 16
    /// 派生密钥长度（字节）：32 字节 = 256 位，对应 AES-256
    private static let keyLength = 32
    /// PBKDF2 迭代次数：抬高暴力破解成本，12 万次是性能与安全的折中
    private static let pbkdfRounds: UInt32 = 120_000

    /// 备份/导入过程中可能出现的错误，全部映射为用户可读的中文描述
    enum BackupError: LocalizedError {
        /// 文件头不是本 App 的魔数，或长度异常
        case notBackupFile
        /// 解密失败：密码错误或密文/Tag 被篡改（GCM 校验不过）
        case wrongPasswordOrDamaged
        /// 解密成功但归档内部结构非法，携带具体原因
        case corruptArchive(String)
        /// 导出时密码为空
        case emptyPassword
        /// 导出时没有任何可备份数据
        case nothingToExport

        /// 把错误转成面向用户的中文提示文案
        var errorDescription: String? {
            switch self {
            case .notBackupFile: return "这不是中防AI的备份文件"
            case .wrongPasswordOrDamaged: return "密码错误，或文件已损坏"
            case .corruptArchive(let detail): return "备份内容不完整：\(detail)"
            case .emptyPassword: return "请设置密码"
            case .nothingToExport: return "没有可导出的数据"
            }
        }
    }

    // MARK: - 归档结构

    /// 备份清单：JSON 序列化后作为 manifest.json 存进归档，是整包数据的"目录+内容"。
    /// 所有 DTO 都用值类型 + Sendable，可安全跨线程传递。
    struct Manifest: Codable, Sendable {
        var version: Int = 1
        var exportedAt: Date = Date()
        var conversations: [ConversationDTO] = []
        var memories: [MemoryDTO] = []
        var files: [FileDTO] = []
        var identity: UserIdentity?
        var chatKey: String?
        var imageKey: String?
        var settings: SettingsDTO = SettingsDTO()

        init() {}

        /// 容错解码：以后新增字段时，老备份依然能读进来
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
            exportedAt = try c.decodeIfPresent(Date.self, forKey: .exportedAt) ?? Date()
            conversations = try c.decodeIfPresent([ConversationDTO].self, forKey: .conversations) ?? []
            memories = try c.decodeIfPresent([MemoryDTO].self, forKey: .memories) ?? []
            files = try c.decodeIfPresent([FileDTO].self, forKey: .files) ?? []
            identity = try? c.decodeIfPresent(UserIdentity.self, forKey: .identity)
            chatKey = try? c.decodeIfPresent(String.self, forKey: .chatKey)
            imageKey = try? c.decodeIfPresent(String.self, forKey: .imageKey)
            settings = try c.decodeIfPresent(SettingsDTO.self, forKey: .settings) ?? SettingsDTO()
        }
    }

    /// 会话快照 DTO：一个对话及其全部消息
    struct ConversationDTO: Codable, Sendable {
        /// 会话唯一标识
        var id: UUID
        /// 所属专家 ID，导入后据此还原专家归类
        var expertId: String
        /// 会话标题
        var title: String
        /// 创建时间
        var createdAt: Date
        /// 最后更新时间
        var updatedAt: Date
        /// 会话内的全部消息（已按时间排序）
        var messages: [MessageDTO]
    }

    /// 单条消息快照 DTO
    struct MessageDTO: Codable, Sendable {
        var id: UUID
        /// "user" 或 "assistant"，导入时会校验
        var role: String
        /// 消息正文
        var text: String
        /// 发送时间
        var createdAt: Date
        /// 附件 ID 逗号串（历史字段，保留兼容）
        var attachmentIds: String
        /// 图片在归档内的条目名（如 "images/xxx.bin"），无图时为 nil
        var imageEntry: String?
        /// 引用来源的 JSON 串
        var sourcesJSON: String? = nil
    }

    /// 资料库文件快照 DTO：文件元数据 + 归档内条目名
    struct FileDTO: Codable, Sendable {
        var id: UUID
        /// 用户可见的原始文件名
        var name: String
        /// 扩展名
        var ext: String
        /// FileKind 原始值
        var kindRaw: String
        /// FileCategory 原始值
        var categoryRaw: String
        /// 磁盘存储名（UUID 命名），导入时会做路径安全校验
        var storedName: String
        /// 字节数，导入时与实际数据长度比对
        var byteCount: Int
        /// 入库时间
        var createdAt: Date
        /// 来源会话 ID（可能为空串）
        var sourceConversationId: String
        /// 已抽取的文本内容
        var textContent: String
        /// 是否收藏
        var isFavorite: Bool
        /// 文件正文在归档内的条目名（如 "files/xxx"）
        var entry: String?
    }

    /// 长期记忆条目快照 DTO
    struct MemoryDTO: Codable, Sendable {
        var id: UUID
        /// 记忆内容文本
        var content: String
        /// 创建时间
        var createdAt: Date
        /// 命中次数（被引用次数）
        var hitCount: Int
        /// 记忆来源（手动/自动等），可能为空
        var source: String? = nil
    }

    /// 各项设置的快照 DTO：服务商选择、模型覆盖、预算、搜索引擎与搜索 Key 等
    struct SettingsDTO: Codable, Sendable {
        var chatProvider: String?
        var imageProvider: String?
        var chatModelOverride: String = ""
        var imageModelOverride: String = ""
        var budgetLimit: Double = 0
        var budgetSpent: Double = 0
        var searchEngine: String = WebSearchEngine.auto.rawValue
        var tavilyKey: String = ""
        var bochaKey: String = ""
        var preferProviderSearch: Bool = false
        var searchPageFetch: Int = 2

        init() {}

        /// 容错解码：缺字段时用默认值，不让整个备份解析失败
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            chatProvider = try? c.decodeIfPresent(String.self, forKey: .chatProvider)
            imageProvider = try? c.decodeIfPresent(String.self, forKey: .imageProvider)
            chatModelOverride = try c.decodeIfPresent(String.self, forKey: .chatModelOverride) ?? ""
            imageModelOverride = try c.decodeIfPresent(String.self, forKey: .imageModelOverride) ?? ""
            budgetLimit = try c.decodeIfPresent(Double.self, forKey: .budgetLimit) ?? 0
            budgetSpent = try c.decodeIfPresent(Double.self, forKey: .budgetSpent) ?? 0
            searchEngine = try c.decodeIfPresent(String.self, forKey: .searchEngine) ?? WebSearchEngine.auto.rawValue
            tavilyKey = try c.decodeIfPresent(String.self, forKey: .tavilyKey) ?? ""
            bochaKey = try c.decodeIfPresent(String.self, forKey: .bochaKey) ?? ""
            preferProviderSearch = try c.decodeIfPresent(Bool.self, forKey: .preferProviderSearch) ?? false
            searchPageFetch = try c.decodeIfPresent(Int.self, forKey: .searchPageFetch) ?? 2
        }
    }

    /// 解密成功后的载荷，用于从后台线程跨回主线程传递（Sendable 保证安全）
    private struct DecryptedPayload: Sendable {
        /// 解析出的清单
        let manifest: Manifest
        /// 解密后的原始归档数据（ZipReader 复用）
        let archive: Data
    }

    /// 导入结果统计：各项导入数量、跳过数量，以及可直接展示给用户的中文汇总文本
    struct ImportSummary {        var conversations = 0
        var messages = 0
        var files = 0
        var memories = 0
        var skippedExisting = 0
        var identityRestored = false
        var keysRestored = false
        var exportedAt: Date?

        var text: String {
            var lines: [String] = []
            if let exportedAt {
                lines.append("备份时间：\(exportedAt.formatted(date: .abbreviated, time: .shortened))")
            }
            lines.append("导入对话 \(conversations) 个（含 \(messages) 条消息）")
            lines.append("导入文件 \(files) 个")
            lines.append("导入记忆 \(memories) 条")
            if skippedExisting > 0 { lines.append("跳过已存在 \(skippedExisting) 项") }
            if identityRestored { lines.append("已恢复身份设置") }
            if keysRestored { lines.append("已恢复 API Key") }
            return lines.joined(separator: "\n")
        }
    }

    // MARK: - 导出

    /// 生成加密备份文件，返回文件 URL（存在 Documents/Exports 下）
    @MainActor
    static func export(password: String, context: ModelContext) async throws -> URL {
        guard !password.isEmpty else { throw BackupError.emptyPassword }

        let conversations = (try context.fetch(FetchDescriptor<Conversation>()))
            // 按时间排序保证备份内容顺序稳定、可复现
            .sorted { $0.createdAt < $1.createdAt }
        let storedFiles = (try context.fetch(FetchDescriptor<StoredFile>()))
            .sorted { $0.createdAt < $1.createdAt }
        let memories = (try context.fetch(FetchDescriptor<MemoryItem>()))
            .sorted { $0.createdAt < $1.createdAt }

        // 空库防呆：没有数据就导出会生成一个"空备份"，误导用户以为已备份成功
        guard !conversations.isEmpty || !storedFiles.isEmpty || !memories.isEmpty else {
            throw BackupError.nothingToExport
        }

        // SwiftData对象快照仍在主线程；大库和图片读取的耗时必须实测。
        var manifest = Manifest()
        manifest.exportedAt = Date()
        var blobs: [(String, Data)] = []
        var diskFiles: [(String, URL)] = []

        for conv in conversations {
            var dto = ConversationDTO(id: conv.id, expertId: conv.expertId, title: conv.title,
                                      createdAt: conv.createdAt, updatedAt: conv.updatedAt, messages: [])
            for msg in conv.messages.sorted(by: { $0.createdAt < $1.createdAt }) {
                var entry: String?
                if let image = msg.imageData {
                    let name = "images/\(msg.id.uuidString).bin"
                    // 容量双闸：单张图 ≤32MB、图片总量 ≤120MB，防止超大数据把整包撑爆或内存耗尽
                    guard image.count <= 32 * 1024 * 1024, blobs.reduce(0, { $0 + $1.1.count }) + image.count <= 120 * 1024 * 1024 else { throw BackupError.corruptArchive("图片或归档超过容量上限") }
                    blobs.append((name, image))
                    entry = name
                }
                dto.messages.append(MessageDTO(id: msg.id, role: msg.role, text: msg.text,
                                               createdAt: msg.createdAt,
                                               attachmentIds: msg.attachmentIds,
                                               imageEntry: entry, sourcesJSON: msg.sourcesJSON))
            }
            manifest.conversations.append(dto)
        }

        for file in storedFiles {
            var entry: String?
            // 防路径穿越：storedName 必须是安全叶子名才允许写进归档
            guard StorageBoundary.isSafeLeaf(file.storedName) else { throw BackupError.corruptArchive("本地文件名不安全") }
            let name = "files/" + file.storedName
            diskFiles.append((name, FileStore.url(for: file)))
            entry = name
            manifest.files.append(FileDTO(id: file.id, name: file.name, ext: file.ext,
                                          kindRaw: file.kindRaw, categoryRaw: file.categoryRaw,
                                          storedName: file.storedName, byteCount: file.byteCount,
                                          createdAt: file.createdAt,
                                          sourceConversationId: file.sourceConversationId,
                                          textContent: file.textContent,
                                          isFavorite: file.isFavorite,
                                          entry: entry))
        }

        for memory in memories {
            manifest.memories.append(MemoryDTO(id: memory.id, content: memory.content,
                                               createdAt: memory.createdAt, hitCount: memory.hitCount, source: memory.source))
        }

        manifest.identity = UserIdentity.load()
        manifest.chatKey = KeychainHelper.read(service: AppConfig.keychainService,
                                               account: AppConfig.chatKeyAccount)
        manifest.imageKey = KeychainHelper.read(service: AppConfig.keychainService,
                                                account: AppConfig.imageKeyAccount)
        manifest.settings = currentSettings()

        // 后台线程：打包 + 加密（PBKDF2 与压缩都在这里，避免卡界面）
        let payload = try await Task.detached(priority: .userInitiated) {
            var allBlobs = blobs
            var total = blobs.reduce(0) { $0 + $1.1.count }
            for (name, url) in diskFiles {
                let data = try Data(contentsOf: url)
                guard data.count <= 32 * 1024 * 1024 else { throw BackupError.corruptArchive("单文件超过32MB") }
                total += data.count
                guard total <= 120 * 1024 * 1024 else { throw BackupError.corruptArchive("备份超过120MB") }
                allBlobs.append((name, data))
            }
            return try assemble(manifest: manifest, blobs: allBlobs, password: password)
        }.value

        let dir = exportsDirectory()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        // 文件名带时间戳：同一分钟内重复导出会覆盖同名文件，属可接受行为
        let url = dir.appendingPathComponent("中防AI备份-\(formatter.string(from: Date())).\(fileExtension)")
        try Task.checkCancellation()
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try payload.write(to: url, options: .atomic)
        }.value
        try Task.checkCancellation()
        return url
    }

    /// 导出目录：Documents/Exports，备份文件统一落在这里便于用户分享
    static func exportsDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Exports", isDirectory: true)
    }

    /// 纯数据操作，可安全地在后台线程执行
    /// 把清单与所有二进制块组装成加密归档。
    /// - Parameters:
    ///   - manifest: 备份清单
    ///   - blobs: (归档内条目名, 数据) 列表，含图片与磁盘文件
    ///   - password: 用户密码，用于派生加密密钥
    /// - Returns: 加密后的完整归档数据
    /// - Throws: 超出容量上限或加密失败
    nonisolated private static func assemble(manifest: Manifest,
                                            blobs: [(String, Data)],
                                            password: String) throws -> Data {
        var zip = ZipWriter()
        for (name, data) in blobs {
            zip.add(name, data)
        }
        // 日期统一 ISO8601：跨设备/跨版本解码无歧义
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try encoder.encode(manifest)
        guard json.count <= 32 * 1024 * 1024, blobs.reduce(json.count, { $0 + $1.1.count }) <= 120 * 1024 * 1024 else { throw BackupError.corruptArchive("备份超过120MB上限，请分批清理资料") }
        zip.add("manifest.json", json)
        // 组包完成后整体加密：密文之外只暴露 magic 与盐，不泄露任何内容
        return try encrypt(zip.finalize(), password: password)
    }

    private static func currentSettings() -> SettingsDTO {
        var s = SettingsDTO()
        s.chatProvider = ProviderCatalog.storedChatProviderId()
        s.imageProvider = ProviderCatalog.storedImageProviderId()
        s.chatModelOverride = ProviderCatalog.chatModelOverride()
        s.imageModelOverride = ProviderCatalog.imageModelOverride()
        s.budgetLimit = BudgetTracker.limit()
        s.budgetSpent = BudgetTracker.spent()
        s.searchEngine = WebSearchService.engine.rawValue
        s.tavilyKey = WebSearchService.tavilyKey
        s.bochaKey = WebSearchService.bochaKey
        s.preferProviderSearch = AppConfig.preferProviderSearch
        s.searchPageFetch = AppConfig.searchPageFetchCount
        return s
    }

    // MARK: - 导入

    /// 导入选项：控制身份 / Key / 设置是否被备份覆盖。
    /// 默认全 true 保持旧行为，UI 层可让用户单独选择，避免"合并导入却静默覆盖本地配置"。
    struct ImportOptions {
        var overwriteIdentity: Bool = false
        var overwriteKeys: Bool = false
        var overwriteSettings: Bool = false
    }

    /// 从备份文件恢复；同 ID 跳过，不覆盖本地已有数据。
    /// 身份 / Key / 设置是否覆盖由 options 控制（默认覆盖，兼容旧行为）。
    @MainActor
    static func importBackup(from url: URL,
                             password: String,
                             context: ModelContext,
                             options: ImportOptions = ImportOptions()) async throws -> ImportSummary {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        // File reads, key derivation and archive parsing all execute off MainActor.
        let payload = try await Task.detached(priority: .userInitiated) {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 128 * 1024 * 1024,
                  let encrypted = try? Data(contentsOf: url) else { throw BackupError.notBackupFile }
            let archive = try decrypt(encrypted, password: password)
            let manifest = try parseManifest(reader: ZipReader(data: archive))
            return DecryptedPayload(manifest: manifest, archive: archive)
        }.value

        try Task.checkCancellation()
        let manifest = payload.manifest
        let reader = ZipReader(data: payload.archive)
        let names = reader.entryNames()

        guard manifest.version == 1 else { throw BackupError.corruptArchive("不支持的备份版本") }
        // 10-22 P2 安全：压缩炸弹防护。加密包本身 ≤128MB，但解压后可能远超内存。
        // 先按 manifest 声明的 byteCount 求和设总上限，再进入逐条预检。
        let declaredTotal = manifest.files.reduce(0) { $0 + max(0, $1.byteCount) }
        guard declaredTotal <= 512 * 1024 * 1024 else {
            throw BackupError.corruptArchive("备份内容解压后过大（超过 512MB），已拒绝导入")
        }
        // Preflight every referenced blob before touching the live database.
        // 先做两阶段预检：把所有二进制完整读入内存暂存并逐项校验（ID 去重、角色合法、
        // 大小一致、图片齐全），全部通过才碰线上数据库——避免导入到一半发现坏数据留下脏库。
        var staged: [UUID: Data] = [:]; var stagedImages: [String: Data] = [:]
        var fileIDs = Set<UUID>(); var conversationIDs = Set<UUID>(); var messageIDs = Set<UUID>()
        for file in manifest.files {
            guard fileIDs.insert(file.id).inserted, StorageBoundary.isSafeLeaf(file.storedName),
                  let entry = file.entry, entry == "files/" + file.storedName, names.contains(entry) else {
                throw BackupError.corruptArchive("文件名称不安全、重复或缺少正文")
            }
            let data = try reader.data(for: entry)
            guard data.count == file.byteCount else { throw BackupError.corruptArchive("文件大小不一致") }
            staged[file.id] = data
        }
        for dto in manifest.conversations {
            guard conversationIDs.insert(dto.id).inserted else { throw BackupError.corruptArchive("重复会话ID") }
            for message in dto.messages {
                guard messageIDs.insert(message.id).inserted, ["user", "assistant"].contains(message.role) else { throw BackupError.corruptArchive("重复消息或非法角色") }
                if let entry = message.imageEntry {
                    guard entry == "images/" + message.id.uuidString + ".bin", names.contains(entry) else { throw BackupError.corruptArchive("图片缺失") }
                    stagedImages[entry] = try reader.data(for: entry)
                }
            }
        }
        let transactionContext = ModelContext(context.container)
        let existing = try transactionContext.fetch(FetchDescriptor<Conversation>())
        let existingFiles = Set((try transactionContext.fetch(FetchDescriptor<StoredFile>())).map(\.id))
        var existingMemoryTexts = Set((try transactionContext.fetch(FetchDescriptor<MemoryItem>())).map(\.content))
        var conversationsByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        var knownMessageIDs = Set(existing.flatMap { $0.messages }.map(\.id))
        var summary = ImportSummary(); summary.exportedAt = manifest.exportedAt
        var createdPaths: [URL] = []
        do {
            for dto in manifest.conversations {
                let conv: Conversation
                if let current = conversationsByID[dto.id] { conv = current; summary.skippedExisting += 1 }
                else {
                    conv = Conversation(expertId: dto.expertId, title: dto.title)
                    conv.id = dto.id; conv.createdAt = dto.createdAt; conv.updatedAt = dto.updatedAt
                    transactionContext.insert(conv); conversationsByID[dto.id] = conv; summary.conversations += 1
                }
                for m in dto.messages where knownMessageIDs.insert(m.id).inserted {
                    let message = Message(role: m.role, text: m.text)
                    message.sourcesJSON = m.sourcesJSON ?? ""
                    message.id = m.id; message.createdAt = m.createdAt; message.attachmentIds = m.attachmentIds
                    if let entry = m.imageEntry { message.imageData = stagedImages[entry] }
                    message.conversation = conv
                    message.conversationID = conv.id   // 10-22：缺这一行会导致恢复后重进会话看不到消息
                    transactionContext.insert(message); summary.messages += 1
                    conv.updatedAt = max(conv.updatedAt, m.createdAt)
                }
            }
            FileStore.prepare()
            for dto in manifest.files {
                if existingFiles.contains(dto.id) { summary.skippedExisting += 1; continue }
                // New local name avoids collisions with a different existing record.
                let localName = UUID().uuidString + "." + (dto.ext.filter { $0.isLetter || $0.isNumber }.isEmpty ? "dat" : dto.ext.filter { $0.isLetter || $0.isNumber })
                let destination = FileStore.rootURL.appendingPathComponent(localName)
                guard let bytes = staged[dto.id] else { throw BackupError.corruptArchive("文件正文未暂存") }
                try bytes.write(to: destination, options: .atomic); createdPaths.append(destination)
                let record = StoredFile(name: dto.name, ext: dto.ext, storedName: localName,
                                        kind: FileKind(rawValue: dto.kindRaw) ?? .uploaded,
                                        category: FileCategory(rawValue: dto.categoryRaw) ?? .other,
                                        byteCount: bytes.count, sourceConversationId: dto.sourceConversationId, textContent: dto.textContent)
                record.id = dto.id; record.createdAt = dto.createdAt; record.isFavorite = dto.isFavorite
                transactionContext.insert(record); summary.files += 1
            }
            for dto in manifest.memories where existingMemoryTexts.insert(dto.content).inserted {
                let item = MemoryItem(content: dto.content, source: dto.source ?? "")
                item.id = dto.id; item.createdAt = dto.createdAt; item.hitCount = dto.hitCount
                transactionContext.insert(item); summary.memories += 1
            }
            try transactionContext.save()
        } catch {
            // 失败补偿：数据库回滚 + 删除本次已落盘的文件，保证导入是原子的（要么全成、要么全无）
            transactionContext.rollback()
            for path in createdPaths { try? FileManager.default.removeItem(at: path) }
            throw error
        }
        NotificationCenter.default.post(name: .bossAIFilesChanged, object: nil)

        // 4) 身份（D03：由 options 控制是否覆盖）
        if options.overwriteIdentity, let identity = manifest.identity, !identity.isEmpty {
            identity.save()
            summary.identityRestored = true
        }

        // 5) API Key（D03：由 options 控制是否覆盖）
        if options.overwriteKeys {
            if let chat = manifest.chatKey, !chat.isEmpty {
                guard KeychainHelper.save(chat, service: AppConfig.keychainService, account: AppConfig.chatKeyAccount) else { throw BackupError.corruptArchive("数据已导入，但对话Key写入失败；原Key保留") }
                summary.keysRestored = true
            }
            if let image = manifest.imageKey, !image.isEmpty {
                guard KeychainHelper.save(image, service: AppConfig.keychainService, account: AppConfig.imageKeyAccount) else { throw BackupError.corruptArchive("数据已导入，但作图Key写入失败；原Key保留") }
                summary.keysRestored = true
            }
        }

        // 6) 设置（D03：由 options 控制是否覆盖）
        if options.overwriteSettings {
            applySettings(manifest.settings)
        }

        NotificationCenter.default.post(name: .bossAIKeysChanged, object: nil)
        return summary
    }

    /// 从归档中解析 manifest.json：优先读压缩版（manifest.json.z），回退到未压缩版，
    /// 两者都没有则判定为缺 manifest 的损坏归档
    nonisolated private static func parseManifest(reader: ZipReader) throws -> Manifest {
        let names = reader.entryNames()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if names.contains("manifest.json.z") {
            let compressed = try reader.data(for: "manifest.json.z")
            guard let json = inflate(compressed) else { throw BackupError.corruptArchive("manifest 解压失败") }
            do { return try decoder.decode(Manifest.self, from: json) }
            catch { throw BackupError.corruptArchive("内容解析失败") }
        }
        if names.contains("manifest.json") {
            let json = try reader.data(for: "manifest.json")
            do { return try decoder.decode(Manifest.self, from: json) }
            catch { throw BackupError.corruptArchive("内容解析失败") }
        }
        throw BackupError.corruptArchive("缺少 manifest")
    }

    /// 把备份里的设置写回本地（仅在 ImportOptions.overwriteSettings 为 true 时调用）。
    /// budgetSpent 额外校验非负且有限，防止异常值污染预算统计
    @MainActor
    private static func applySettings(_ s: SettingsDTO) {
        if let chat = s.chatProvider { ProviderCatalog.saveChatProvider(chat) }
        if let image = s.imageProvider { ProviderCatalog.saveImageProvider(image) }
        ProviderCatalog.saveChatModelOverride(s.chatModelOverride)
        ProviderCatalog.saveImageModelOverride(s.imageModelOverride)
        BudgetTracker.setLimit(s.budgetLimit)
        if s.budgetSpent >= 0 && s.budgetSpent.isFinite { BudgetTracker.restoreSpent(s.budgetSpent) }
        WebSearchService.engine = WebSearchEngine(rawValue: s.searchEngine) ?? .auto
        WebSearchService.tavilyKey = s.tavilyKey
        WebSearchService.bochaKey = s.bochaKey
        AppConfig.setPreferProviderSearch(s.preferProviderSearch)
        AppConfig.setSearchPageFetchCount(s.searchPageFetch)
    }

    // MARK: - 加解密（纯数据操作）

    /// 加密：生成随机盐 → PBKDF2 派生密钥 → AES-GCM 加密 → 拼 [magic + 盐 + 密文]。
    /// - Parameters:
    ///   - plain: 待加密的明文归档
    ///   - password: 用户密码
    /// - Returns: 含文件头与盐的加密数据
    /// - Throws: 随机盐生成失败或加密失败
    nonisolated static func encrypt(_ plain: Data, password: String) throws -> Data {
        var salt = Data(count: saltLength)
        // 盐必须用密码学安全随机源（SecRandomCopyBytes），不能用普通随机数
        let randomStatus = salt.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, saltLength, buffer.baseAddress!)
        }
        guard randomStatus == errSecSuccess else { throw BackupError.corruptArchive("随机盐生成失败") }
        let key = try deriveKey(password: password, salt: salt)
        let sealed = try AES.GCM.seal(plain, using: key)
        guard let combined = sealed.combined else { throw BackupError.corruptArchive("加密失败") }
        var out = Data(magic.utf8)
        out.append(salt)
        out.append(combined)
        return out
    }

    /// 解密：校验魔数 → 切出盐与密文 → 重新派生密钥 → AES-GCM 解密。
    /// - Parameters:
    ///   - encrypted: 完整备份文件数据
    ///   - password: 用户输入的密码
    /// - Returns: 解密后的明文归档
    /// - Throws: 非本 App 备份文件，或密码错误/数据被篡改
    nonisolated static func decrypt(_ encrypted: Data, password: String) throws -> Data {
        // 长度下界检查（8B 头 + 16B 盐 + 至少 1B）防止 subdata 越界崩溃
        guard encrypted.count > saltLength + 8,
              String(data: encrypted.prefix(8), encoding: .utf8) == magic else {
            throw BackupError.notBackupFile
        }
        let salt = encrypted.subdata(in: 8..<(8 + saltLength))
        let combined = encrypted.subdata(in: (8 + saltLength)..<encrypted.count)
        let key = try deriveKey(password: password, salt: salt)
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(box, using: key)
        } catch {
            // GCM 校验失败只可能是密码不对或数据被改，统一报同一错误避免泄露细节
            throw BackupError.wrongPasswordOrDamaged
        }
    }

    /// 用 PBKDF2-SHA256 从密码+盐派生 256 位对称密钥。
    /// 失败行为：状态码非成功时抛 corruptArchive
    nonisolated private static func deriveKey(password: String, salt: Data) throws -> SymmetricKey {
        let passwordData = Data(password.utf8)
        var derived = Data(count: keyLength)
        let status = derived.withUnsafeMutableBytes { derivedBytes -> Int32 in
            salt.withUnsafeBytes { saltBytes -> Int32 in
                passwordData.withUnsafeBytes { pwBytes -> Int32 in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwBytes.bindMemory(to: Int8.self).baseAddress, passwordData.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        pbkdfRounds,
                        derivedBytes.bindMemory(to: UInt8.self).baseAddress, keyLength
                    )
                }
            }
        }
        if status != kCCSuccess {
            throw BackupError.corruptArchive("密码派生失败，已停止处理")
        }
        return SymmetricKey(data: derived)
    }

    // MARK: - zlib 压缩（manifest 文本）

    /// zlib 压缩 manifest JSON；输出缓冲按"原大小 + 10%（至少 64KB）"预留，
    /// 空数据直接返回 nil。失败行为：压缩不产出字节则返回 nil
    nonisolated private static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count + max(64 * 1024, data.count / 10)
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst -> Int in
            data.withUnsafeBytes { src -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                      let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(d, capacity, s, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return out.prefix(written)
    }

    /// 解压时逐级放大缓冲区，直到不再顶满
    nonisolated private static func inflate(_ data: Data) -> Data? {
        ZipReader.inflateManifest(data)
    }
}
