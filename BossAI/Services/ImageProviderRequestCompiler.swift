import Foundation

/// Provider-specific request contract compilation.
/// App intent is normalized once here; transport/authentication remains in ImageService.
enum ImageProviderRequestCompiler {
    static func hosted(model: String,
                       prompt: String,
                       structured: [String: Any]?,
                       requestId: String?,
                       layerDecomposition: Bool,
                       renderIntent: String?,
                       aspectRatio: String?,
                       taskKind: String?,
                       qualityTier: String?,
                       requestedCount: Int?,
                       targetSize: String?,
                       textMode: String?,
                       referenceRoles: [String]? = nil) -> [String: Any] {
        var body: [String: Any] = ["model": model, "prompt": prompt]
        if let structured, !structured.isEmpty { body["structured"] = structured }
        if let requestId, !requestId.isEmpty { body["requestId"] = requestId }
        if layerDecomposition { body["layer_decomposition"] = true }
        if let renderIntent, !renderIntent.isEmpty { body["render_intent"] = renderIntent }
        if let targetSize, !targetSize.trimmingCharacters(in: .whitespaces).isEmpty {
            body["size"] = targetSize.trimmingCharacters(in: .whitespaces)
        } else if let aspectRatio, !aspectRatio.isEmpty {
            body["aspect_ratio"] = aspectRatio
        }
        // overlay = 底图必须无字，文案由客户端排版层绘制；服务端据此不再把文案塞回 prompt
        if let textMode, !textMode.isEmpty { body["text_mode"] = textMode }
        // 多图角色标注：只有真的有多张时才发，单图带角色只会浪费 token
        if let referenceRoles, referenceRoles.count > 1 { body["reference_roles"] = referenceRoles }
        if let taskKind, !taskKind.isEmpty { body["task_kind"] = taskKind }
        if let qualityTier, !qualityTier.isEmpty { body["quality_tier"] = qualityTier }
        if let requestedCount, requestedCount > 1 { body["requested_count"] = requestedCount }
        return body
    }

    static func seedream(model: String,
                         prompt: String,
                         references: [Data],
                         structured: [String: Any]?,
                         layerDecomposition: Bool,
                         aspectRatio: String?,
                         taskKind: String?,
                         requestedCount: Int?,
                         targetSize: String?) throws -> [String: Any] {
        if taskKind == "series" || (requestedCount ?? 1) > 1 {
            throw ImageService.ImageError.taskUnsupported("当前直连服务暂不支持组图，请改为单张生成")
        }
        if layerDecomposition && references.count != 1 {
            throw ImageService.ImageError.taskUnsupported("图层拆分需要且只支持一张参考图片")
        }

        let explicitSize = (targetSize ?? "").trimmingCharacters(in: .whitespaces)
        let resolvedSize: String
        if !explicitSize.isEmpty {
            guard let size = SeedreamSizeResolver.resolveExplicit(explicitSize) else {
                throw ImageService.ImageError.unsupportedAspectRatio
            }
            resolvedSize = size
        } else if let aspectRatio, !aspectRatio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let size = SeedreamSizeResolver.resolve(aspectRatio: aspectRatio, tier: "2K") else {
                throw ImageService.ImageError.unsupportedAspectRatio
            }
            resolvedSize = size
        } else {
            resolvedSize = "2K"
        }

        var body: [String: Any] = ["model": model, "prompt": prompt, "size": resolvedSize]
        if model.contains("seedream-5-0-pro") || model.contains("seedream-4-0") {
            body["optimize_prompt_options"] = ["mode": "standard"]
        }
        if layerDecomposition { body["layer_decomposition"] = true }
        let visibleCopy = TextItem.values(from: structured?["text"])
            .filter { !$0.isEmpty && !prompt.contains($0) }
        if !visibleCopy.isEmpty {
            body["prompt"] = prompt + "\n\n【需准确呈现的原文】\n" + visibleCopy.joined(separator: "\n")
        }
        return body
    }

    static func zhipu(model: String,
                      prompt: String,
                      references: [Data],
                      structured: [String: Any]?,
                      layerDecomposition: Bool,
                      aspectRatio: String?,
                      taskKind: String?,
                      requestedCount: Int?,
                      targetSize: String?) throws -> [String: Any] {
        if taskKind == "series" || (requestedCount ?? 1) > 1 {
            throw ImageService.ImageError.taskUnsupported("当前直连服务暂不支持组图，请改为单张生成")
        }
        guard references.isEmpty else { throw ImageService.ImageError.unsupportedEdit }
        if layerDecomposition {
            throw ImageService.ImageError.taskUnsupported("当前直连服务暂不支持图层拆分")
        }
        if let targetSize, !targetSize.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ImageService.ImageError.unsupportedAspectRatio
        }
        if let aspectRatio, !aspectRatio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let normalized = ImageTaskPlanner.normalizeAspect(aspectRatio), normalized == "1:1" else {
                throw ImageService.ImageError.unsupportedAspectRatio
            }
        }

        var body: [String: Any] = ["model": model, "prompt": prompt]
        let visibleCopy = TextItem.values(from: structured?["text"])
            .filter { !$0.isEmpty && !prompt.contains($0) }
        if !visibleCopy.isEmpty {
            body["prompt"] = prompt + "\n\n【需准确呈现的原文】\n" + visibleCopy.joined(separator: "\n")
        }
        return body
    }
}
