import Foundation
import CryptoKit
import SwiftData

// LibraryImageWriter.swift —— 把聊天里生成的图片同时写入「资料库」。
//
// 为什么需要它（2026-10-24 真机反馈）：
//   生图成功后只调用了 ToolPipeline.persistArtifact(conversation:imageData:)，那一步只把图挂到
//   **会话消息**上；资料库列表读的是 StoredFile 记录，而全仓库没有一处对图片调用 FileStore.store，
//   于是资料库里只有文档、没有图片，删掉会话图片就彻底消失。
//
// 设计取舍：
//   1) 写库失败**不能**让生图本身失败 —— 图已经在消息里了，用户能看到；这里只做丢日志 + 会话内去重，
//      避免把"资料库写失败"演变成"这张图白生成了"。
//   2) 去重按内容哈希（会话内）。同一张图被重复落库（重试/回放）只保留一份。
//   3) 文件名用中文可读格式，方便用户在资料库里找；不含路径分隔符等非法字符。
enum LibraryImageWriter {

    /// 会话内已写入过的图片指纹，防止重试/回放导致同一张图存多份。
    /// 只保存在内存里：重启后哈希集合清空，但历史图片已在库中，不会重复触发。
    @MainActor private static var savedFingerprints: Set<String> = []

    /// 内容指纹（SHA-256 前 16 字节十六进制）——用于去重，也可在日志里对齐同一张图。
    nonisolated static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// 生成资料库里的文件名：`生成图片-20261024-2312-<提示词前 10 字>.png`
    nonisolated static func filename(prompt: String, date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmm"
        let stamp = f.string(from: date)
        let cleaned = sanitize(prompt)
        return cleaned.isEmpty ? "生成图片-\(stamp).png" : "生成图片-\(stamp)-\(cleaned).png"
    }

    /// 去掉路径分隔符、换行、首尾空白并截断到 10 个字符（避免文件名过长）。
    nonisolated static func sanitize(_ raw: String) -> String {
        let banned = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let parts = raw.components(separatedBy: banned).joined(separator: " ")
        let collapsed = parts.split(separator: " ").joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(10))
    }

    /// 写入资料库。返回是否真的写入了（去重命中 / 写失败都返回 false）。
    /// - Note: 必须在主线程调用（ModelContext 约束）。失败只记录轨迹，不抛错。
    @MainActor
    @discardableResult
    static func save(imageData: Data,
                     conversationId: UUID?,
                     prompt: String = "",
                     context: ModelContext) -> Bool {
        guard !imageData.isEmpty else { return false }

        let key = fingerprint(imageData)
        if savedFingerprints.contains(key) { return false }

        do {
            try FileStore.store(data: imageData,
                                filename: filename(prompt: prompt),
                                kind: .generated,
                                category: .image,
                                sourceConversationId: conversationId?.uuidString ?? "",
                                context: context)
            savedFingerprints.insert(key)
            PerformanceTrace.event("library_image_saved")
            return true
        } catch {
            // 资料库写失败不影响图片已在会话里展示的事实；但要留痕，便于排查"为什么库里没有"
            PerformanceTrace.event("library_image_save_failed")
            return false
        }
    }

    /// 供测试重置去重集合（生产代码不应调用）
    @MainActor
    static func resetForTesting() { savedFingerprints.removeAll() }
}
