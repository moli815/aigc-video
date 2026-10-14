import Foundation
import SwiftData

//
//  FileStore.swift
//  BossAI（中防AI iPad App）— Services 层
//
//  文件职责：本地文件仓库。统一管理上传/生成文件的落盘（沙盒 Documents/Files）、
//  元数据（SwiftData StoredFile）、删除（先隔离后清理）与孤儿文件清理。
//
//  在整个 App 中的角色：文件子系统的唯一入口。备份导入、文档生成、附件上传
//  都通过它落盘；UI 通过 bossAIFilesChanged 通知感知文件变化。
//
//  关键设计决策：
//  - 磁盘文件用 UUID 命名（storedName），用户原始文件名只存元数据——避免重名/非法字符问题。
//  - 删除采用"先挪入隔离名、保存成功后再真删"的两步策略，失败可回移，绝不丢文件。
//  - storeAsync 把写盘放到 FileIOWorker actor 后台执行，主线程只做元数据入库；
//    写盘后回读校验字节数（P0-21 防谎报），校验不过绝不写库。
//
//  防呆/安全冗余理由：
//  - 所有 URL 拼接都经 StorageBoundary.isSafeLeaf 校验，非法名退化为占位名，防路径穿越。
//  - 元数据入库失败时回滚记录并删除已写文件，保证"库"与"盘"一致。
//  - 清理孤儿文件只删"没有元数据记录"的文件，误删风险为零。
//
/// 本地文件仓库：所有上传与生成的文件都落在 App 沙盒 Documents/Files 下，
/// 元数据记在 SwiftData 的 StoredFile 里。
@MainActor
enum FileStore {
    /// 文件仓库根目录：Documents/Files（惰性计算）
    static var rootURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Files", isDirectory: true)
    }

    /// 确保仓库目录存在（不存在则创建）
    static func prepare() {
        let url = rootURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    /// 取文件在沙盒中的完整 URL。
    /// storedName 经安全校验，非法名退化为 "invalid-file-name"，防路径穿越
    static func url(for file: StoredFile) -> URL {
        rootURL.appendingPathComponent(StorageBoundary.isSafeLeaf(file.storedName) ? file.storedName : "invalid-file-name")
    }

    /// 判断文件实体是否存在于磁盘
    static func exists(_ file: StoredFile) -> Bool {
        FileManager.default.fileExists(atPath: url(for: file).path)
    }

    /// 同步写入沙盒并建元数据记录。
    /// - Returns: 新建的 StoredFile 记录
    /// - Throws: 写盘失败或数据库保存失败（此时已回滚并删除已写文件）
    @discardableResult
    static func store(data: Data,
                      filename: String,
                      kind: FileKind,
                      category: FileCategory? = nil,
                      sourceConversationId: String = "",
                      textContent: String = "",
                      context: ModelContext) throws -> StoredFile {
        prepare()
        // 磁盘名一律 UUID 化：既避免重名冲突，也规避用户文件名中的非法字符
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
            // 补偿：入库失败时回滚记录并删除已落盘文件，保证库与盘一致
            context.delete(record)
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
        NotificationCenter.default.post(name: .bossAIFilesChanged, object: nil)
        return record
    }

    /// 异步写入：字节落盘放后台 actor，主线程只做元数据入库。
    /// - Returns: 新建的 StoredFile 记录
    /// - Throws: 写盘/校验/入库失败（入库失败时已回滚并删除文件）
    /// Write bytes off the main thread, then insert only metadata on MainActor.
    @discardableResult
    static func storeAsync(data: Data, filename: String, kind: FileKind,
                           category: FileCategory? = nil, sourceConversationId: String = "",
                           textContent: String = "", context: ModelContext) async throws -> StoredFile {
        let ext = (filename as NSString).pathExtension.lowercased()
        // 磁盘名 UUID 化，与同步版 store 保持一致
        let storedName = "\(UUID().uuidString).\(ext.isEmpty ? "dat" : ext)"
        let directory = rootURL
        let destination = directory.appendingPathComponent(storedName)
        try await FileIOWorker.shared.write(data, to: destination, directory: directory)
        // 防谎报（P0-21）：写盘后立即回读验证——文件不存在或字节数不符视为写盘失败，
        // 绝不写库、绝不向上层返回"已导出"。此前对话中出现过 AI 说"文件已生成"
        // 但实际没有落盘的情况，根因就是写盘成功与否从未被验证。
        let writtenSize = (try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? Int
        guard writtenSize == data.count else {
            try? FileManager.default.removeItem(at: destination)
            throw NSError(domain: "FileStore", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "文件写盘校验失败（落盘不完整），已放弃保存"])
        }
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

    /// 删除文件：先物理挪到隔离名，数据库保存成功后再真删。
    /// 失败行为：入库失败时回滚并把隔离文件移回原位，文件绝不丢失
    static func delete(_ file: StoredFile, context: ModelContext) throws {
        let path = url(for: file)
        // 隔离名：删除期间文件改姓改名，等库保存成功才真正移除
        let quarantine = rootURL.appendingPathComponent("delete-" + UUID().uuidString)
        let exists = FileManager.default.fileExists(atPath: path.path)
        if exists { try FileManager.default.moveItem(at: path, to: quarantine) }
        context.delete(file)
        do { try context.save() }
        catch {
            // 回滚并撤销隔离：把文件移回原名，删除动作完全抵消
            context.rollback()
            if exists { try? FileManager.default.moveItem(at: quarantine, to: path) }
            throw error
        }
        // 走到这里说明库已保存成功，隔离文件可以安全真删
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
        // 超限截断并显式标注，让模型知道内容不完整
        if body.count <= limit { return body }
        return String(body.prefix(limit)) + "\n…（内容过长已截断）"
    }

    /// 是否为图片类文件
    var isImage: Bool { category == .image }
}

/// 文件变化通知名：文件新增/删除后广播，UI 据此刷新
extension Notification.Name { static let bossAIFilesChanged = Notification.Name("bossai.files.changed") }

/// 串行文件 IO 执行者：把磁盘读写从 MainActor 挪走，保证不卡界面
private actor FileIOWorker {
    /// 全局共享单例
    static let shared = FileIOWorker()
    /// 原子写入：先建目录再 .atomic 落盘，中途失败不留半截文件
    func write(_ data: Data, to destination: URL, directory: URL) throws {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
    }
    /// 删除文件（容错：文件不存在也不报错）
    func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }
}
