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
        rootURL.appendingPathComponent(file.storedName)
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
        try? context.save()
        return record
    }

    static func delete(_ file: StoredFile, context: ModelContext) {
        let path = url(for: file)
        if FileManager.default.fileExists(atPath: path.path) {
            try? FileManager.default.removeItem(at: path)
        }
        context.delete(file)
        try? context.save()
    }

    /// 清理没有任何元数据记录的孤儿文件
    static func cleanupOrphans(context: ModelContext) {
        prepare()
        let descriptor = FetchDescriptor<StoredFile>()
        let known = Set(((try? context.fetch(descriptor)) ?? []).map(\.storedName))
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
