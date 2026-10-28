import Foundation
import ImageIO
import CoreGraphics

/// Authorized editing context: one bounded preview on the existing chat request.
/// Image generation, original-asset compositing and artifact storage stay separate.
enum GeneratedImagePlanningContext {
    static let marker = "【本次编辑前生成图预览】"
    static let maxPreviewEdge = 1024
    static let maxPreviewBytes = 350_000

    static func shouldInclude(userText: String, hasAttachedImages: Bool) -> Bool {
        let text = userText.lowercased()
        if ["不要用生成图", "不使用生成图", "不参考生成图", "只改上传", "只修改上传", "don't use generated", "do not use generated"].contains(where: { text.contains($0) }) { return false }
        let edits = ["替换", "换成", "换为", "换一下", "换个", "换一个", "换一种", "换背景", "换颜色", "换logo", "换 logo", "修改", "改成", "改为", "改一下", "调整", "编辑", "修图", "重做", "重绘", "重新设计", "重新排版", "添加", "新增", "加一个", "加上", "加点", "加文字", "加logo", "加 logo", "加我们的", "放到", "放在", "贴到", "贴上", "叠加", "去掉", "删除", "移除", "移动", "裁切", "抠图", "放大", "缩小", "edit ", "replace ", "change ", "add ", "remove ", "resize ", "redesign ", "crop "]
        // A mention of editing is not an instruction to edit. Remove refusals and
        // completed-action feedback, then require an actionable request clause.
        var request = text.replacingOccurrences(of: "(?:不要|别|不用|无需|不需要|不必|不想)(?:再|继续)?(?:替换|换成|换为|换一下|换个|换一种|换背景|修改|改成|调整|编辑|修图|重做|重绘|重新设计|重新排版|添加|新增|加一个|加上|去掉|删除|移除|移动|裁切|抠图|放大|缩小)", with: "", options: .regularExpression)
        request = request.replacingOccurrences(of: "(?:已经|已)(?:修改|编辑|调整|替换)|(?:修改|编辑|调整|替换|重做)(?:好了|完成|过了|过|完了)", with: "", options: .regularExpression)
        request = request.replacingOccurrences(of: "(?:don't|do not|never|no need to)\\s+(?:edit|replace|change|add|remove|resize|redesign|crop)\\s*", with: "", options: .regularExpression)
        guard edits.contains(where: { request.contains($0) }) else { return false }
        let clauses = request.components(separatedBy: CharacterSet(charactersIn: "，。；！？,;!?\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let starts = ["请", "帮", "给", "把", "将", "再", "在", "对", "我想", "我要", "我希望", "能否", "能不能", "please ", "can you ", "could you ", "i want "]
        let explicitAsk = ["帮我", "给我", "请你"].contains { request.contains($0) }
        guard explicitAsk || clauses.contains(where: { clause in starts.contains(where: { clause.hasPrefix($0) }) || edits.contains(where: { clause.hasPrefix($0) }) }) else { return false }
        if ["你生成", "刚才生成", "刚生成", "上一张生成", "生成的这张", "生成的那张", "刚才那张", "generated", "you made", "previous image", "last image"].contains(where: { text.contains($0) }) { return true }
        // A current uploaded photo is never replaced by an unrelated generated image.
        return !hasAttachedImages && ImageReferenceResolver.userRequestsImageSource(text)
    }

    @MainActor
    static func latestGenerated(in history: [Message], before user: Message) -> Message? {
        history.last { message in
            message.role == "assistant" && message.createdAt < user.createdAt
                && (message.imageData != nil || !CloudAssetStore.references(message.imageAssetsJSON).isEmpty)
        }
    }

    static func canAppend(to messages: [[String: Any]]) -> Bool {
        guard HostedAccount.behaviorBool("generatedPreviewEnabled", default: true) else { return false }
        guard let user = messages.last(where: { $0["role"] as? String == "user" }) else { return false }
        let parts = contentParts(user)
        return parts.filter { $0["type"] as? String == "image_url" }.count < 6
            && !parts.contains { ($0["text"] as? String ?? "").hasPrefix(marker) }
    }
    static func appending(_ url: String, to messages: [[String: Any]]) -> [[String: Any]] {
        guard canAppend(to: messages), url.hasPrefix("data:image/jpeg;base64,"),
              url.utf8.count <= maxPreviewBytes * 4 / 3 + 30 else { return messages }
        return prepending([
            ["type": "text", "text": marker + "这是编辑前的底图，不是本轮编辑结果，仅供本次定位。source=last；both时为第1张底图。本预览不属于用户上传附件，不计入source_index。替换标识时定位完整旧标识区域，不覆盖邻近标题。原样替换上传素材必须在structured.preserve_assets填写reference_index=2、kind=logo、background=auto和box，不是仅写在prompt里；保留其余原图时preserve_outside=true且text=[]。"],
            ["type": "image_url", "image_url": ["url": url]],
            ["type": "text", "text": "【以下是用户本轮输入与上传附件，source_index仍按原附件顺序从1计数】"]
        ], to: messages)
    }
    static func notingUnavailable(in messages: [[String: Any]]) -> [[String: Any]] {
        prepending([["type": "text", "text": "【本次生成图预览未读取】不能据此声称已看清编辑位置，也不要用其他历史附件代替。若需从图中确定精确区域且用户尚未指定位置，请先确认位置。"]], to: messages)
    }
    private static func contentParts(_ message: [String: Any]) -> [[String: Any]] {
        if let parts = message["content"] as? [[String: Any]] { return parts }
        return [["type": "text", "text": message["content"] as? String ?? ""]]
    }
    private static func prepending(_ parts: [[String: Any]], to input: [[String: Any]]) -> [[String: Any]] {
        var messages = input
        guard let index = messages.lastIndex(where: { $0["role"] as? String == "user" }) else { return messages }
        messages[index]["content"] = parts + contentParts(messages[index])
        return messages
    }

    /// Native ImageIO downsamples before decoding; no crop, retained EXIF orientation.
    static func dataURL(from raw: Data) async -> String? {
        guard !Task.isCancelled else { return nil }
        let edge = min(maxPreviewEdge, max(256, HostedAccount.behaviorInt("generatedPreviewEdge", default: maxPreviewEdge)))
        let result = await Task.detached(priority: .userInitiated) { () -> String? in
            guard raw.count <= 32 * 1024 * 1024, let pixels = ImageGeometry.pixelSize(of: raw),
                  Double(pixels.width) * Double(pixels.height) <= 40_000_000,
                  let source = CGImageSourceCreateWithData(raw as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: edge
                  ] as CFDictionary) else { return nil }
            // JPEG has no alpha. A neutral white backing keeps dark transparent
            // artwork visible without modifying the original image or its geometry.
            guard let canvas = CGContext(data: nil, width: thumbnail.width, height: thumbnail.height,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            let rect = CGRect(x: 0, y: 0, width: thumbnail.width, height: thumbnail.height)
            canvas.setFillColor(CGColor(gray: 1, alpha: 1)); canvas.fill(rect)
            canvas.draw(thumbnail, in: rect)
            guard let flattened = canvas.makeImage() else { return nil }
            for quality in [0.72, 0.5] {
                let bytes = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(bytes, "public.jpeg" as CFString, 1, nil) else { return nil }
                CGImageDestinationAddImage(destination, flattened, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                if CGImageDestinationFinalize(destination), bytes.length <= maxPreviewBytes {
                    return "data:image/jpeg;base64," + (bytes as Data).base64EncodedString()
                }
            }
            return nil
        }.value
        return Task.isCancelled ? nil : result
    }

    @MainActor
    static func dataURL(for message: Message, in conversation: Conversation, owner: String, session: CloudSession?) async -> String? {
        func current() -> Bool {
            !Task.isCancelled && conversation.modelContext != nil && message.modelContext != nil
                && HostedAccount.scopeKey == owner && conversation.ownerKey == owner
                && !conversation.isDeleted && message.conversation?.id == conversation.id
        }
        guard current() else { return nil }
        var bytes = message.imageData
        if bytes == nil, let session { bytes = try? await CloudAssetHydrator.image(message, session: session) }
        guard current(), let bytes else { return nil }
        let preview = await dataURL(from: bytes)
        if let session { do { try session.validate() } catch { return nil } }
        return current() ? preview : nil
    }
}
