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

    static let magic = "BOSSAI01"
    static let fileExtension = "bossai"
    private static let saltLength = 16
    private static let keyLength = 32
    private static let pbkdfRounds: UInt32 = 120_000

    enum BackupError: LocalizedError {
        case notBackupFile
        case wrongPasswordOrDamaged
        case corruptArchive(String)
        case emptyPassword
        case nothingToExport

        var errorDescription: String? {
            switch self {
            case .notBackupFile: return "这不是 Boss AI 的备份文件"
            case .wrongPasswordOrDamaged: return "密码错误，或文件已损坏"
            case .corruptArchive(let detail): return "备份内容不完整：\(detail)"
            case .emptyPassword: return "请设置密码"
            case .nothingToExport: return "没有可导出的数据"
            }
        }
    }

    // MARK: - 归档结构

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

    struct ConversationDTO: Codable, Sendable {
        var id: UUID
        var expertId: String
        var title: String
        var createdAt: Date
        var updatedAt: Date
        var messages: [MessageDTO]
    }

    struct MessageDTO: Codable, Sendable {
        var id: UUID
        var role: String
        var text: String
        var createdAt: Date
        var attachmentIds: String
        var imageEntry: String?
        var sourcesJSON: String? = nil
    }

    struct FileDTO: Codable, Sendable {
        var id: UUID
        var name: String
        var ext: String
        var kindRaw: String
        var categoryRaw: String
        var storedName: String
        var byteCount: Int
        var createdAt: Date
        var sourceConversationId: String
        var textContent: String
        var isFavorite: Bool
        var entry: String?
    }

    struct MemoryDTO: Codable, Sendable {
        var id: UUID
        var content: String
        var createdAt: Date
        var hitCount: Int
        var source: String? = nil
    }

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

    /// 解密后的结果，用于跨线程传递
    private struct DecryptedPayload: Sendable {
        let manifest: Manifest
        let archive: Data
    }

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
            .sorted { $0.createdAt < $1.createdAt }
        let storedFiles = (try context.fetch(FetchDescriptor<StoredFile>()))
            .sorted { $0.createdAt < $1.createdAt }
        let memories = (try context.fetch(FetchDescriptor<MemoryItem>()))
            .sorted { $0.createdAt < $1.createdAt }

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
        let url = dir.appendingPathComponent("BossAI备份-\(formatter.string(from: Date())).\(fileExtension)")
        try Task.checkCancellation()
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try payload.write(to: url, options: .atomic)
        }.value
        try Task.checkCancellation()
        return url
    }

    static func exportsDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Exports", isDirectory: true)
    }

    /// 纯数据操作，可安全地在后台线程执行
    nonisolated private static func assemble(manifest: Manifest,
                                            blobs: [(String, Data)],
                                            password: String) throws -> Data {
        var zip = ZipWriter()
        for (name, data) in blobs {
            zip.add(name, data)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try encoder.encode(manifest)
        guard json.count <= 32 * 1024 * 1024, blobs.reduce(json.count, { $0 + $1.1.count }) <= 120 * 1024 * 1024 else { throw BackupError.corruptArchive("备份超过120MB上限，请分批清理资料") }
        zip.add("manifest.json", json)
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
        // Preflight every referenced blob before touching the live database.
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
                    message.conversation = conv; transactionContext.insert(message); summary.messages += 1
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

    nonisolated static func encrypt(_ plain: Data, password: String) throws -> Data {
        var salt = Data(count: saltLength)
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

    nonisolated static func decrypt(_ encrypted: Data, password: String) throws -> Data {
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
            throw BackupError.wrongPasswordOrDamaged
        }
    }

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
