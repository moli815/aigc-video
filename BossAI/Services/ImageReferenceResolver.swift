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

        if asksForAttached, hasAttachedImage, selected != "both" { return "attached" }
        if asksForLastGenerated, hasLastGeneratedImage { return "last" }
        return nil
    }

    static func resolve(source: String,
                        attachmentIndex: Int = 1,
                        attachedImages: [Data],
                        lastGeneratedImage: Data?) throws -> [Data] {
        switch source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "none":
            return []
        case "last":
            guard let image = lastGeneratedImage, !image.isEmpty else {
                throw ResolutionError.generatedImageUnavailable
            }
            return [image]
        case "attached":
            return [try attachedImage(at: attachmentIndex, from: attachedImages)]
        case "both":
            guard let image = lastGeneratedImage, !image.isEmpty else {
                throw ResolutionError.generatedImageUnavailable
            }
            return [image, try attachedImage(at: attachmentIndex, from: attachedImages)]
        default:
            // Invalid model output fails closed; never silently become text-to-image.
            throw ResolutionError.attachmentUnavailable(attachmentIndex)
        }
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
