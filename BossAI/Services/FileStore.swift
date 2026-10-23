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

    /// 确保仓库目录存在（不存在则创建）；同时恢复任何崩溃残留的删除日志
    static func prepare() {
        let url = rootURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        recoverDeletions()
    }

    /// 10-23 P2：崩溃残留的删除日志恢复。删除流程为"写日志→移隔离→删库→改日志→删隔离→删日志"，
    /// 任何中间崩溃都能据此把文件恢复到安全状态，避免"库删了但文件没删"或"库没删但文件丢了"。
    private static func recoverDeletions() {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: rootURL.path)) ?? []
        for name in names where name.hasPrefix("deletion-journal-") && name.hasSuffix(".json") {
            let journalURL = rootURL.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: journalURL),
                  let journal = try? JSONDecoder().decode(DeletionJournal.self, from: data) else {
                try? fm.removeItem(at: journalURL)
                continue
            }
            let original = rootURL.appendingPathComponent(journal.original)
            let quarantine = rootURL.appendingPathComponent(journal.quarantine)
            let originalExists = fm.fileExists(atPath: original.path)
            let quarantineExists = fm.fileExists(atPath: quarantine.path)

            if journal.state == DeletionJournal.committed {
                // 库已删、隔离文件可安全清理
                if quarantineExists { try? fm.removeItem(at: quarantine) }
            } else {
                // 未确认提交：保守回滚，把隔离文件移回原位（若 save 实际已发生，文件会变成孤儿，cleanupOrphans 会处理）
                if !originalExists && quarantineExists {
                    try? fm.moveItem(at: quarantine, to: original)
                } else if quarantineExists {
                    try? fm.removeItem(at: quarantine)
                }
            }
            try? fm.removeItem(at: journalURL)
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

    /// 删除文件：先写崩溃恢复日志，再物理挪到隔离名；数据库保存成功后再清日志与隔离文件。
    /// 10-23 P2：失败行为改为"手动恢复文件 + 清理日志"，避免对共享 ModelContext 调用宽泛 rollback()
    ///（rollback 会丢弃调用方在同一上下文上的所有未保存修改）。
    static func delete(_ file: StoredFile, context: ModelContext) throws {
        let path = url(for: file)
        let fileName = path.lastPathComponent
        // 隔离名：删除期间文件改姓改名，等库保存成功才真正移除
        let quarantineName = "delete-" + UUID().uuidString
        let quarantine = rootURL.appendingPathComponent(quarantineName)
        let journalURL = rootURL.appendingPathComponent("deletion-journal-\(file.id.uuidString).json")
        let exists = FileManager.default.fileExists(atPath: path.path)

        // 1) 写日志：记录原文件名与隔离文件名，状态为 pending
        var journal = DeletionJournal(original: fileName, quarantine: quarantineName, state: DeletionJournal.pending)
        try? JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)

        // 2) 移入隔离
        if exists { try FileManager.default.moveItem(at: path, to: quarantine) }

        // 3) 删除数据库记录并保存
        context.delete(file)
        do { try context.save() }
        catch {
            // 保存失败：撤销隔离（文件移回原位），清理日志，但不 rollback 整个上下文
            if exists { try? FileManager.default.moveItem(at: quarantine, to: path) }
            try? FileManager.default.removeItem(at: journalURL)
            throw error
        }

        // 4) 保存成功：标记 committed，然后清理隔离文件与日志
        journal.state = DeletionJournal.committed
        try? JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
        if exists { try? FileManager.default.removeItem(at: quarantine) }
        try? FileManager.default.removeItem(at: journalURL)
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

/// 10-23 P2 删除崩溃恢复日志：记录一次删除操作的原文件、隔离文件与提交状态。
private struct DeletionJournal: Codable {
    static let pending = "pending"
    static let committed = "committed"
    let original: String
    let quarantine: String
    var state: String
}

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
