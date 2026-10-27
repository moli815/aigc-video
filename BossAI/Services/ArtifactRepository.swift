import Foundation
import UIKit
import SwiftData

/// Single local persistence boundary for messages and library products.
enum ArtifactRepository {
    /// 产出物统一落库（含 save）：图片/文档/图表消息一律走这里——
    /// 历史上"生成了但没显示"就是因为某个分支漏了 save，此函数让这类问题在结构上不可能发生。
    @MainActor
    @discardableResult
    /// 10-22 修复：改为 throws。此前 `try? context.save()` 后无条件返回 msg，
    /// 保存失败时调用方仍向模型回「成功」——用户看到图，重开会话却没了。
    /// 现在失败会回滚插入并抛错，调用方必须据此返回失败文案。
    static func persistArtifact(conversation: Conversation,
                                imageData: Data? = nil,
                                attachmentIDs: String? = nil,
                                text: String = "",
                                context: ModelContext) throws -> Message {
        guard conversation.ownerKey == HostedAccount.scopeKey, conversation.modelContext != nil else { throw CancellationError() }
        guard imageData?.isEmpty != true,
              imageData != nil || !(attachmentIDs ?? "").isEmpty || !text.isEmpty else {
            throw ExpertSkillError.invalidInput("产物没有保存完整，请重试保存")
        }
        let msg = Message(role: "assistant", text: text)
        if let imageData {
            msg.imageData = imageData
            msg.thumbnailData = makeThumbnail(imageData)   // P0-69 缩略图分层
        }
        if let attachmentIDs { msg.attachmentIds = attachmentIDs }
        msg.conversation = conversation
        msg.conversationID = conversation.id
        context.insert(msg)
        do {
            try context.save()
        } catch {
            context.delete(msg)
            throw error
        }
        // 10-24：图片产物同时写入资料库。此前只挂会话消息，资料库里永远只有文档。
        // 放在 context.save() 之后：消息已确定落库，写库失败不影响这张图的展示与计费。
        if let imageData {
            LibraryImageWriter.save(imageData: imageData,
                                    conversationId: conversation.id,
                                    prompt: text,
                                    context: context)
        }
        return msg
    }

    /// 10-24 组图落库（P0-2）：多张图 + 元信息写进**同一条**消息。
    /// 每张图都真实落库，重开 App 仍能看到全部图片；保存失败照旧抛出，由调用方如实告知。
    @MainActor
    @discardableResult
    static func persistSeriesArtifact(conversation: Conversation,
                                      images: [Data],
                                      meta: SeriesMeta,
                                      text: String = "",
                                      context: ModelContext) throws -> Message {
        guard conversation.ownerKey == HostedAccount.scopeKey, conversation.modelContext != nil else { throw CancellationError() }
        let msg = Message(role: "assistant", text: text)
        if let first = images.first {
            msg.imageData = first
            msg.thumbnailData = makeThumbnail(first)
        }
        if images.count > 1 {
            msg.extraImagesJSON = try? JSONEncoder().encode(Array(images.dropFirst()))
        }
        msg.seriesMetaJSON = (try? JSONEncoder().encode(meta))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        msg.conversation = conversation
        msg.conversationID = conversation.id
        context.insert(msg)
        do {
            try context.save()
        } catch {
            context.delete(msg)
            throw error
        }
        // 10-24：组图的**每一张**都要进资料库（去重按内容哈希，重试合并不会重复存）
        for data in images {
            LibraryImageWriter.save(imageData: data,
                                    conversationId: conversation.id,
                                    prompt: text,
                                    context: context)
        }
        return msg
    }

    /// 10-24 组图结果更新（重试失败项后合并）：
    /// 只替换图片与元信息，不新增消息 —— 否则历史里会出现两条"同一组图"。
    @MainActor
    static func updateSeriesArtifact(_ message: Message,
                                     images: [Data],
                                     meta: SeriesMeta,
                                     context: ModelContext) throws {
        // 重试后补上的图同样要进资料库（已存在的按指纹跳过）
        for data in images {
            LibraryImageWriter.save(imageData: data,
                                    conversationId: message.conversationID,
                                    prompt: message.text,
                                    context: context)
        }
        if let first = images.first {
            message.imageData = first
            message.thumbnailData = makeThumbnail(first)
        }
        message.extraImagesJSON = images.count > 1
            ? (try? JSONEncoder().encode(Array(images.dropFirst())))
            : nil
        message.seriesMetaJSON = (try? JSONEncoder().encode(meta))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        try context.save()
    }

    /// P0-69 缩略图生成（长边 400px、JPEG 0.7）：列表渲染用——防大图（2K 约数 MB）在列表滚动时卡顿；
    /// 小图原样返回；生成失败回退 nil（渲染层自动用原图）。
    static func makeThumbnail(_ data: Data) -> Data? {
        CloudAssetStore.thumbnail(data, maxPixel: 400)
    }

}
