import Foundation

/// Resolves a tool's image-source intent into the exact ordered references sent to the image provider.
/// Indices are one-based and refer to the image attachments visible in the current request context.
enum ImageReferenceResolver {
    enum ResolutionError: LocalizedError {
        case attachmentUnavailable(Int)
        case generatedImageUnavailable

        var errorDescription: String? {
            switch self {
            case .attachmentUnavailable(let index):
                return "找不到本轮第 \(index) 张图片，请重新上传后再试。"
            case .generatedImageUnavailable:
                return "找不到本轮要继续编辑的生成图片，请先生成或重新选择图片。"
            }
        }
    }

    static func userRequestsImageSource(_ text: String) -> Bool {
        let value = text.lowercased()
        let phrases = ["这张", "这幅", "原图", "上传的图",
                       "附件里的图", "根据图片", "根据这张", "基于图片", "基于这张", "参考这张", "照着这张",
                       "编辑这张", "重做这张"]
        return phrases.contains { value.contains($0) }
    }

    /// Resolve conflicts between the Agent's tool arguments and explicit user references.
    /// User intent wins: a mistaken `source=none/last` must not silently turn an edit into T2I.
    static func sourceOverride(requested: String?,
                               userText: String,
                               hasAttachedImage: Bool,
                               hasLastGeneratedImage: Bool) -> String? {
        let value = userText.lowercased()
        let attachedPhrases = ["上传的", "我上传", "附件", "原图", "这张图", "这张图片", "这张照片",
                               "根据这张", "基于这张", "参考这张", "对这张", "把这张"]
        let lastGeneratedPhrases = ["刚才生成", "刚生成的", "上一张生成", "你生成的", "刚才那张生成"]
        let asksForAttached = attachedPhrases.contains { value.contains($0) }
        let asksForLastGenerated = lastGeneratedPhrases.contains { value.contains($0) }
        let selected = requested?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // A two-source request must remain two-source. Explicitly mentioning the
        // base image does not revoke the uploaded material (e.g. replace its logo).
        if ["不要用上传", "不使用上传", "只改生成图", "只修改生成图"].contains(where: {value.contains($0)}), hasLastGeneratedImage { return "last" }
        if ["不要用生成图", "不使用生成图", "只改上传", "只修改上传"].contains(where: {value.contains($0)}), hasAttachedImage { return "attached" }
        if selected == "both" { return nil }
        let combinesUploadedMaterial = ["logo", "标志", "商标", "徽标", "素材"].contains { value.contains($0) }
            && ["替换", "换成", "换为", "放到", "放在", "加到", "贴到"].contains { value.contains($0) }
        if combinesUploadedMaterial && asksForLastGenerated && hasAttachedImage && hasLastGeneratedImage {
            return "both"
        }

        if asksForAttached, hasAttachedImage, selected != "both" { return "attached" }
        if asksForLastGenerated, hasLastGeneratedImage { return "last" }
        return nil
    }

    /// 多附件合成入口（2026-10-28）。
    ///
    /// 事故背景：用户上传「人物照 + 底图」要求合成，Agent 只传 `source=attached, source_index=2`，
    /// 于是**人物照那一张从未离开设备**；Seedream 只收到光秃秃的底图，只能照 prompt 里的文字
    /// 画一个"有点像"的陌生人。根因不是模型不会合成，是请求里只有一张图。
    ///
    /// 设计取舍：不新增 source 枚举值，而是把 `attached` 扩展成"可带多个序号"。
    /// 因为 source 的取值同时被 Agent 提示词、服务端 task_kind 推导、
    /// 原素材合成（preserve_assets）流程使用，新增枚举会连带打穿三条链路。
    ///
    /// 顺序契约：`indices.first` 是**底图**，其余是素材（人物/产品/Logo）。
    /// 这个顺序与客户端 `reference_roles` 一一对应，服务端据此标注"图1=底图、图2=人物"，
    /// 也让 ImageGeometry 的比例保护自然落在底图上（它只读 refs.first）。
    static func resolve(source: String,
                        attachmentIndices: [Int],
                        attachedImages: [Data],
                        lastGeneratedImage: Data?) throws -> [Data] {
        let normalized = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // 去重但保序：同一张图传两次只会让模型多花一份注意力，不产生任何收益。
        var seen = Set<Int>()
        let indices = attachmentIndices.filter { $0 >= 1 && seen.insert($0).inserted }
        let primary = indices.first ?? 1
        switch normalized {
        case "", "none":
            return []
        case "last":
            guard let image = lastGeneratedImage, !image.isEmpty else {
                throw ResolutionError.generatedImageUnavailable
            }
            return [image]
        case "attached":
            guard !indices.isEmpty, indices.count <= maxReferences else {
                throw ResolutionError.attachmentUnavailable(primary)
            }
            return try indices.map { try attachedImage(at: $0, from: attachedImages) }
        case "both":
            // 兼容旧契约：生成图底图 + 一张上传素材（Logo/二维码替换走这条）。
            // 两张**上传**附件互合成请用 attached + attachmentIndices。
            guard let image = lastGeneratedImage, !image.isEmpty else {
                throw ResolutionError.generatedImageUnavailable
            }
            return [image, try attachedImage(at: primary, from: attachedImages)]
        default:
            // Invalid model output fails closed; never silently become text-to-image.
            throw ResolutionError.attachmentUnavailable(primary)
        }
    }

    /// 单序号入口保留：历史调用点与旧测试都走这里，语义与多序号入口的 `[index]` 完全一致。
    static func resolve(source: String,
                        attachmentIndex: Int = 1,
                        attachedImages: [Data],
                        lastGeneratedImage: Data?) throws -> [Data] {
        try resolve(source: source,
                    attachmentIndices: [attachmentIndex],
                    attachedImages: attachedImages,
                    lastGeneratedImage: lastGeneratedImage)
    }

    /// 单次请求最多几张输入图。与服务端 maxImages 对齐：再多只会稀释每张图的权重。
    static let maxReferences = 6

    /// 用户是否在描述「把 A 图里的人/物放到 B 图」——这种请求**必须**两张附件同时上行。
    ///
    /// 为什么需要这个判断：文档改了、字段加了，Agent 仍可能习惯性地只传 `source_index`。
    /// 一旦只传一张，模型看不到素材，就会按文字画个"有点像"的陌生人，而且**不会报错**。
    /// 这里只做意图识别，不做强制改写——识别到就给 Agent 一次参数修正机会，
    /// 真正的修复仍然由 Agent 重新调用完成（避免我们在客户端替模型猜序号）。
    ///
    /// 只认明确的双图指代，不碰「把这张图里的人往左挪」这类单图编辑。
    static func requestsCrossAttachmentComposite(_ text: String) -> Bool {
        let value = text.lowercased()
        let firstMarkers = ["第一张", "第1张", "图一", "图1", "前一张", "上面那张", "上一张"]
        let secondMarkers = ["第二张", "第2张", "图二", "图2", "后一张", "下面那张", "下一张"]
        if firstMarkers.contains(where: { value.contains($0) }),
           secondMarkers.contains(where: { value.contains($0) }) { return true }
        // "把这张图里的人放到另一张上"：一个指代 + 一个"另一张"
        let another = ["另一张", "另外一张", "另一幅", "别的图", "其他图"]
        let pointing = ["这张", "那张", "图里", "图上", "照片里", "照片上"]
        return another.contains { value.contains($0) } && pointing.contains { value.contains($0) }
    }

    private static func attachedImage(at oneBasedIndex: Int, from images: [Data]) throws -> Data {
        guard oneBasedIndex > 0,
              images.indices.contains(oneBasedIndex - 1),
              !images[oneBasedIndex - 1].isEmpty else {
            throw ResolutionError.attachmentUnavailable(oneBasedIndex)
        }
        return images[oneBasedIndex - 1]
    }
}
