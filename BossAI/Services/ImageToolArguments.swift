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
