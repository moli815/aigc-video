import Foundation
import SwiftData

/// 本地文件仓库：所有上传与生成的文件都落在 App 沙盒 Documents/Files 下，
/// 元数据记在 SwiftData 的 StoredFile 里。
@MainActor
enum FileStore {
    static var rootURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Files", isDirectory: true)
    }

    static func prepare() {
        let url = rootURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    static func url(for file: StoredFile) -> URL {
        rootURL.appendingPathComponent(StorageBoundary.isSafeLeaf(file.storedName) ? file.storedName : "invalid-file-name")
    }

    static func exists(_ file: StoredFile) -> Bool {
        FileManager.default.fileExists(atPath: url(for: file).path)
    }

    /// 写入沙盒并建元数据记录
    @discardableResult
    static func store(data: Data,
                      filename: String,
                      kind: FileKind,
                      category: FileCategory? = nil,
                      sourceConversationId: String = "",
                      textContent: String = "",
                      context: ModelContext) throws -> StoredFile {
        prepare()
        let ext = (filename as NSString).pathExtension.lowercased()
        let storedName = "\(UUID().uuidString).\(ext.isEmpty ? "dat" : ext)"
        let dest = rootURL.appendingPathComponent(storedName)
        try data.write(to: dest, options: .atomic)

        let record = StoredFile(name: filename,
                                ext: ext,
                                storedName: storedName,
                                kind: kind,
                                category: category ?? FileCategory.from(ext: ext),
                                byteCount: data.count,
                                sourceConversationId: sourceConversationId,
                                textContent: textContent)
        context.insert(record)
        do { try context.save() }
        catch {
            context.delete(record)
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
        NotificationCenter.default.post(name: .bossAIFilesChanged, object: nil)
        return record
    }

    /// Write bytes off the main thread, then insert only metadata on MainActor.
    @discardableResult
    static func storeAsync(data: Data, filename: String, kind: FileKind,
                           category: FileCategory? = nil, sourceConversationId: String = "",
                           textContent: String = "", context: ModelContext) async throws -> StoredFile {
        let ext = (filename as NSString).pathExtension.lowercased()
        let storedName = "\(UUID().uuidString).\(ext.isEmpty ? "dat" : ext)"
        let directory = rootURL
        let destination = directory.appendingPathComponent(storedName)
        try await FileIOWorker.shared.write(data, to: destination, directory: directory)
        let record = StoredFile(name: filename, ext: ext, storedName: storedName, kind: kind,
                                category: category ?? FileCategory.from(ext: ext), byteCount: data.count,
                                sourceConversationId: sourceConversationId, textContent: textContent)
        do {
            try Task.checkCancellation()
            context.insert(record)
            try context.save()
        } catch {
            context.delete(record)
            await FileIOWorker.shared.remove(destination)
            throw error
        }
        NotificationCenter.default.post(name: .bossAIFilesChanged, object: nil)
        return record
    }

    static func delete(_ file: StoredFile, context: ModelContext) throws {
        let path = url(for: file)
        let quarantine = rootURL.appendingPathComponent("delete-" + UUID().uuidString)
        let exists = FileManager.default.fileExists(atPath: path.path)
        if exists { try FileManager.default.moveItem(at: path, to: quarantine) }
        context.delete(file)
        do { try context.save() }
        catch {
            context.rollback()
            if exists { try? FileManager.default.moveItem(at: quarantine, to: path) }
            throw error
        }
        if exists { try? FileManager.default.removeItem(at: quarantine) }
        NotificationCenter.default.post(name: .bossAIFilesChanged, object: nil)
    }

    /// 清理没有任何元数据记录的孤儿文件
    static func cleanupOrphans(context: ModelContext) {
        prepare()
        let descriptor = FetchDescriptor<StoredFile>()
        guard let records = try? context.fetch(descriptor) else { return }
        let known = Set(records.map(\.storedName))
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: rootURL.path)) ?? []
        for name in contents where !known.contains(name) {
            try? FileManager.default.removeItem(at: rootURL.appendingPathComponent(name))
        }
    }
}

extension StoredFile {
    /// 提供给模型阅读的正文（截断，避免超长）
    func contextText(limit: Int = 12000) -> String {
        let body = textContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return "" }
        if body.count <= limit { return body }
        return String(body.prefix(limit)) + "\n…（内容过长已截断）"
    }

    var isImage: Bool { category == .image }
}

extension Notification.Name { static let bossAIFilesChanged = Notification.Name("bossai.files.changed") }

private actor FileIOWorker {
    static let shared = FileIOWorker()
    func write(_ data: Data, to destination: URL, directory: URL) throws {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
    }
    func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }
}
