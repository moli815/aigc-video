import Foundation

/// Validate function-call JSON before any upload, provider call or billable operation.
/// This validates execution data; ordinary assistant replies remain natural language.
enum ImageToolArguments {
    enum InputError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case .invalid(let field): return "作图参数「\(field)」不完整或格式不正确，请按工具约定补全后再调用。" }
        }
    }

    static func decode(_ raw: String, toolName: String, userText: String) throws -> [String: Any] {
        guard let data = raw.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              var args = value as? [String: Any] else { throw InputError.invalid("JSON") }
        let modern = toolName != "generate_image"
        let lower = userText.lowercased()
        let exactAssetReplacement = ["换成我们的logo", "换成我们的 logo", "替换成我们的logo", "换成这个logo", "换成上传的logo", "替换为上传的", "用我们的logo"].contains { lower.contains($0) }
        if toolName == "image_edit", exactAssetReplacement {
            guard args["source"] as? String == "both",
                  let fields = args["structured"] as? [String:Any],
                  let assets = fields["preserve_assets"] as? [[String:Any]], !assets.isEmpty else {
                throw InputError.invalid("原样替换标识需要source=both及structured.preserve_assets，不得重绘相似Logo")
            }
        }
        if let reason = args["quality_reason"] {
            guard let reason = reason as? String, ImageQualityPolicy.reasons.contains(reason) else { throw InputError.invalid("quality_reason") }
        }
        if toolName == "image_decompose" || !modern {
            if args["prompt"] == nil { args["prompt"] = userText }
        }
        guard let prompt = args["prompt"] as? String, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InputError.invalid("prompt")
        }
        let allowedSources: [String]
        switch toolName {
        case "image_generate": allowedSources = ["none", "attached"]
        case "image_edit": allowedSources = ["last", "attached", "both"]
        case "image_decompose": allowedSources = ["last", "attached"]
        default: allowedSources = ["none", "last", "attached", "both"]
        }
        if let source = args["source"] {
            guard let source = source as? String, allowedSources.contains(source) else { throw InputError.invalid("source") }
        } else if toolName == "image_edit" || toolName == "image_decompose" { throw InputError.invalid("source") }
        if let index = args["source_index"] {
            guard let n = index as? NSNumber, String(cString: n.objCType) != "c", n.doubleValue == Double(n.intValue),
                  (1...6).contains(n.intValue) else { throw InputError.invalid("source_index") }
        }
        if let ratio = args["aspect_ratio"] {
            guard let text = ratio as? String, ImageTaskPlanner.normalizeAspect(text) != nil else { throw InputError.invalid("aspect_ratio") }
        }
        if let rawCount = args["count"] {
            guard let n = rawCount as? NSNumber, String(cString: n.objCType) != "c", n.doubleValue == Double(n.intValue),
                  (toolName == "image_series" ? (2...4).contains(n.intValue) : n.intValue == 1) else { throw InputError.invalid("count：多图请用 image_series") }
        }
        if let rawStructured = args["structured"] {
            guard let structured = rawStructured as? [String: Any] else { throw InputError.invalid("structured") }
            if let value = structured["text"] {
                if let entries = value as? [[String: Any]] {
                    var keys = Set<String>()
                    for entry in entries {
                        guard let text = entry["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              let role = entry["role"] as? String, TextItem.Role(rawValue: role) != nil,
                              let key = entry["key"] as? String, !key.isEmpty,
                              keys.insert(key).inserted else { throw InputError.invalid("structured.text") }
                    }
                } else if modern || !(value is String) { throw InputError.invalid("structured.text") }
            }
        }
        return args
    }
}
