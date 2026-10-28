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
        let exactAssetReplacement = requiresOriginalAsset(userText)
        let replacingExistingAsset = exactAssetReplacement && ["换", "替换", "replace"].contains { lower.contains($0) }
        if modern, toolName != "image_edit", replacingExistingAsset {
            throw InputError.invalid("原样替换标识请用image_edit及原素材合成，不得用普通生图重画")
        }
        if let library = args["library_refs"] {
            guard let ids = library as? [String], (1...4).contains(ids.count),
                  ids.allSatisfy({ UUID(uuidString: $0) != nil }), Set(ids).count == ids.count else {
                throw InputError.invalid("library_refs")
            }
        }
        if toolName == "image_edit", exactAssetReplacement {
            let historicalPair = (args["library_refs"] as? [String] ?? []).count >= 2
            guard args["source"] as? String == "both" || historicalPair,
                  let fields = args["structured"] as? [String:Any],
                  let assets = fields["preserve_assets"] as? [[String:Any]], !assets.isEmpty else {
                throw InputError.invalid("原样替换上传Logo必须使用source=both、structured.preserve_assets=[{reference_index:2,kind:logo,background:auto,box:{x,y,width,height}}]；box根据底图预览估算旧Logo区域的归一化坐标，不要猜固定坐标。除Logo外保留原图：preserve_outside=true、text=[]，不要把已有标题再画一次。尚未调用作图模型，请补全参数后重新调用image_edit")
            }
        }
        if let reason = args["quality_reason"] {
            // Optional routing metadata must not invalidate an otherwise executable
            // task. Unknown recommendations fall through to conservative policy.
            if !(reason is String) || !ImageQualityPolicy.reasons.contains(reason as? String ?? "") {
                args.removeValue(forKey:"quality_reason")
            }
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
        // ── 2026-10-28 多附件合成（双图/多图）参数校验 ──────────────────────────
        // 背景：用户上传「人物照 + 底图」，Agent 只传一张，人物照没离开设备，
        // 模型只能按文字画个"有点像"的陌生人。这里在**计费之前**把参数钉死，
        // 参数不对就回注修正，而不是发出一张注定错的请求。
        let rawIndexes = args["source_indexes"]
        let rawRoles = args["reference_roles"]
        if rawIndexes != nil || rawRoles != nil {
            guard rawIndexes != nil else { throw InputError.invalid("reference_roles 必须与 source_indexes 一起使用") }
            guard let numbers = rawIndexes as? [NSNumber], (1...6).contains(numbers.count),
                  numbers.allSatisfy({ n in
                      String(cString: n.objCType) != "c"
                          && n.doubleValue == Double(n.intValue)
                          && (1...6).contains(n.intValue)
                  }),
                  Set(numbers.map(\.intValue)).count == numbers.count else {
                throw InputError.invalid("source_indexes（1~6 的整数序号数组，不重复，最多 6 项）")
            }
            // 只有 attached 是多图语义；both 是"上次生成图 + 一张素材"的旧契约，混用会静默丢图。
            guard (args["source"] as? String) == "attached" else {
                throw InputError.invalid("source_indexes 只能配 source=attached；两张上传附件互合成不要用 both")
            }
            if toolName == "image_decompose" || !modern {
                throw InputError.invalid("source_indexes（图层拆分只接受一张图）")
            }
            if args["source_index"] != nil {
                throw InputError.invalid("source_index 与 source_indexes 只能二选一")
            }
            if let roles = rawRoles {
                guard let list = roles as? [String], list.count == numbers.count,
                      list.allSatisfy({ r in
                          let t = r.trimmingCharacters(in: .whitespacesAndNewlines)
                          return !t.isEmpty && t.count <= 24 && !t.contains("\n")
                      }) else {
                    throw InputError.invalid("reference_roles（需与 source_indexes 等长，每项不超过 24 字）")
                }
            }
        }
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

    /// Detect the asset + operation + supplied-original relationship, not a fixed phrase.
    static func requiresOriginalAsset(_ text: String) -> Bool {
        let value = text.lowercased().replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        let asset = ["logo", "标志", "标识", "商标", "二维码", "qrcode"].contains { value.contains($0) }
        let operation = ["换", "替换", "改用", "粘贴", "贴上", "放上", "replace", "paste"].contains { value.contains($0) }
        let original = ["上传", "我们的", "这个", "这张", "原图", "原素材", "原样", "一模一样", "uploaded", "provided", "ourlogo", "thislogo"].contains { value.contains($0) }
        return asset && operation && original
    }
}
