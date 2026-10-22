import Foundation
import SwiftData
import UIKit

// ============================================================================
// 文件职责：ChatViewModel 的附件模块（God File 拆分 P0-46）。
// 从 ChatViewModel.swift 拆出：文件/图片导入、附件缓存、附件查询。
// 说明：原类为 @MainActor，本 extension 天然继承；方法体未做任何逻辑改动（纯移动）。
// ============================================================================

extension ChatViewModel {

    /// 从文件选择器导入（支持多选、多种类型）
    func attach(urls: [URL]) {
        guard !urls.isEmpty, !isImporting else { return }
        isImporting = true
        Task {
            var added: [StoredFile] = []
            for url in urls {
                let (data, text) = await FileImportService.load(url: url)
                guard !data.isEmpty else { errorMessage = FriendlyError.fileProblem(url.lastPathComponent, reason: "没能读取（可能超过 32MB 或格式不受支持）"); continue }
                let name = url.lastPathComponent
                do {
                let record = try await FileStore.storeAsync(data: data,
                                                     filename: name,
                                                     kind: .uploaded,
                                                     sourceConversationId: conversation?.id.uuidString ?? "",
                                                     textContent: text,
                                                     context: modelContext)
                    added.append(record)
                } catch { errorMessage = FriendlyError.message(for: error, scene: .upload) }
            }
            pendingAttachments.append(contentsOf: added)
            invalidateFileCache()
            isImporting = false
        }
    }

    /// 从相册或相机导入图片
    func attach(images: [UIImage]) {
        guard !images.isEmpty, !isImporting else { return }
        isImporting = true
        Task {
            var added: [StoredFile] = []
            for (index, image) in images.enumerated() {
                guard let data = image.ocrFriendlyJPEG() else { continue }
                let name = "照片_\(Self.timestamp())_\(index + 1).jpg"
                let text = await FileImportService.ocr(imageData: data)
                do {
                let record = try await FileStore.storeAsync(data: data,
                                                     filename: name,
                                                     kind: .uploaded,
                                                     sourceConversationId: conversation?.id.uuidString ?? "",
                                                     textContent: text,
                                                     context: modelContext)
                    added.append(record)
                } catch { errorMessage = FriendlyError.message(for: error, scene: .upload) }
            }
            pendingAttachments.append(contentsOf: added)
            invalidateFileCache()
            isImporting = false
        }
    }

    /// 移除一个待发送附件
    func removeAttachment(_ file: StoredFile) {
        pendingAttachments.removeAll { $0.id == file.id }
    }

    /// 取某条消息的附件列表（走内存缓存，未命中 UUID 的 id 静默丢弃）
    func files(for message: Message) -> [StoredFile] {
        let ids = message.attachmentIdList
        guard !ids.isEmpty else { return [] }
        ensureFileCache()
        return ids.compactMap { key in
            guard let uuid = UUID(uuidString: key) else { return nil }
            return fileCache[uuid]
        }
    }

    /// 一次性把资料库文件读进内存缓存，避免每条消息各查一次数据库
    func ensureFileCache() {
        guard !fileCacheLoaded else { return }
        let descriptor = FetchDescriptor<StoredFile>()
        // 10-22 修复：查询失败时不要标记 loaded——否则同一个 ViewModel 生命周期内不会再重试，
        // 附件会"凭空消失"且没有任何错误提示。失败就保持未加载，下次访问自动重试。
        do {
            let all = try modelContext.fetch(descriptor)
            fileCache = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
            fileCacheLoaded = true
        } catch {
            fileCacheLoaded = false
        }
    }

    func invalidateFileCache() {
        fileCacheLoaded = false
        fileCache = [:]
    }

    func storedFile(id: String) -> StoredFile? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        ensureFileCache()
        return fileCache[uuid]
    }
}
