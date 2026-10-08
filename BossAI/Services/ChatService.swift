import Foundation

/// 对话服务：OpenAI 兼容 Chat Completions 流式（SSE）+ 工具调用。
/// 默认接 Kimi（Moonshot）：内置 $web_search 由服务端执行；
/// generate_image 为本地自定义工具，由 ChatViewModel 回调执行。
final class ChatService {
    struct ToolCall {
        let id: String
        let name: String
        let arguments: String
    }

    enum StreamEvent {
        case textDelta(String)
        case reasoningDelta(String) // API continuation only; never merged into the answer
        case status(String)          // 如"正在联网搜索…"
        case nativeSearchUnavailable // The provider rejected its advertised native-search payload.
        case toolCalls([ToolCall], assistantText: String)
        case usage(promptTokens: Int, completionTokens: Int)   // 服务端返回的真实 token 数
        case finished
    }

    enum ChatError: LocalizedError {
        case missingKey, badResponse(Int, String)
        case incomplete(String)
        var errorDescription: String? {
            switch self {
            case .missingKey: return "未配置对话 API Key"
            case .badResponse(let code, let body): return "请求失败（\(code)）：\(body.prefix(300))"
            case .incomplete(let reason): return "输出尚未完成（\(reason)）。"
            }
        }
    }

    private let profile: ChatProfile
    private let apiKeyProvider: () -> String?
    private let session: URLSession
    init(profile: ChatProfile, apiKeyProvider: @escaping () -> String?, session: URLSession = BoundedHTTPClient.chatSession) {
        self.profile = profile
        self.apiKeyProvider = apiKeyProvider
        self.session = session
    }

    var configurationLabel: String { profile.displayName + " / " + profile.model }

    var prefersNativeSearch: Bool {
        guard AppConfig.preferProviderSearch else { return false }
        switch profile.searchStyle {
        case .none: return false
        case .kimiBuiltin, .zhipuTool, .dashscopeParam, .volcTool: return true
        }
    }

    /// 单次请求流。工具调用通过 toolCalls 事件交给调用方处理，调用方追加 tool 结果后再次调用本方法继续。
    func stream(messages: [[String: Any]], enableTools: Bool, expertID: String = "general", allowSearch: Bool = true, useNativeSearch: Bool? = nil) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let span = PerformanceTrace.begin("AIRequest")
                defer { PerformanceTrace.end("AIRequest", span) }
                var receivedFirstDelta = false
                do {
                    guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else { throw ChatError.missingKey }
                    var request = URLRequest(url: URL(string: "\(profile.baseURL)/chat/completions")!)
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.timeoutInterval = 120

                    var body: [String: Any] = [
                        "model": profile.model,
                        "messages": messages,
                        "stream": true,
                        "temperature": 0.6,
                    ]
                    ModelRequestAdapter.apply(to: &body, profile: profile, purpose: .chat)
                    if enableTools {
                        try applyTools(to: &body, expertID: expertID, allowSearch: allowSearch, useNativeSearch: useNativeSearch ?? prefersNativeSearch)
                    }
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    var (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse,
                       [400, 422].contains(http.statusCode),
                       allowSearch, useNativeSearch ?? prefersNativeSearch {
                        // A configured provider can reject native search for a specific model.
                        // Retry this request with the App tool; never silently repeat the same unsupported payload.
                        var fallbackBody = body
                        fallbackBody.removeValue(forKey: "tools")
                        fallbackBody.removeValue(forKey: "enable_search")
                        try applyTools(to: &fallbackBody, expertID: expertID, allowSearch: allowSearch, useNativeSearch: false)
                        request.httpBody = try JSONSerialization.data(withJSONObject: fallbackBody)
                        continuation.yield(.status("模型内置搜索不可用，已切换 App 搜索…"))
                        continuation.yield(.nativeSearchUnavailable)
                        (bytes, response) = try await session.bytes(for: request)
                    }
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var errBody = ""
                        for try await line in bytes.lines {
                            errBody += line
                            if errBody.utf8.count >= 4096 { break }
                        }
                        throw ChatError.badResponse(
                            http.statusCode,
                            "服务商 \(profile.displayName)｜\(profile.baseURL)/chat/completions｜模型 \(profile.model)\n\(errBody)"
                        )
                    }

                    var text = ""
                    var textBytes = 0
                    var toolBytes = 0
                    var toolCallBuffer: [Int: (id: String, name: String, args: String)] = [:]
                    var searchNotified = false
                    var sse = SSEByteDecoder()
                    var sawDone = false
                    var finishReason: String?

                    func processPayload(_ payload: String) throws -> Bool {
                        if payload == "[DONE]" { sawDone = true; return true }
                        guard let data = payload.data(using: .utf8),
                              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ChatError.incomplete("无效流事件") }
                        if let failure = json["error"] { throw ChatError.incomplete(String(describing: failure).prefix(200).description) }

                        // B01：捕获服务端返回的真实 usage（部分厂商在结尾 chunk 返回）。
                        // 拿不到就由调用方回退到估算，不阻塞流式。
                        if let usage = json["usage"] as? [String: Any] {
                            let p = usage["prompt_tokens"] as? Int ?? 0
                            let c = usage["completion_tokens"] as? Int ?? 0
                            if p > 0 || c > 0 {
                                continuation.yield(.usage(promptTokens: p, completionTokens: c))
                            }
                        }

                        guard let choices = json["choices"] as? [[String: Any]],
                              let choice = choices.first else { return false }
                        if let reason = choice["finish_reason"] as? String { finishReason = reason }

                        if let delta = choice["delta"] as? [String: Any] {
                            if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                                toolBytes += reasoning.utf8.count
                                guard toolBytes <= 1_048_576 else { throw ChatError.incomplete("思考及工具内容超过上限") }
                                continuation.yield(.reasoningDelta(reasoning))
                            }
                            if let content = delta["content"] as? String, !content.isEmpty {
                                if !receivedFirstDelta {
                                    receivedFirstDelta = true
                                    PerformanceTrace.event("FirstDelta", span)
                                }
                                textBytes += content.utf8.count
                                guard textBytes <= 1_048_576 else { throw ChatError.incomplete("输出超过1MB上限") }
                                text += content
                                continuation.yield(.textDelta(content))
                            }
                            if let tcs = delta["tool_calls"] as? [[String: Any]] {
                                if !tcs.isEmpty && !receivedFirstDelta {
                                    receivedFirstDelta = true
                                    PerformanceTrace.event("FirstDelta", span)
                                }
                                for tc in tcs {
                                    let index = tc["index"] as? Int ?? 0
                                    guard (0..<24).contains(index) else { throw ChatError.incomplete("工具索引超过上限") }
                                    var entry = toolCallBuffer[index] ?? (id: "", name: "", args: "")
                                    if let id = tc["id"] as? String { entry.id = id }
                                    if let fn = tc["function"] as? [String: Any] {
                                        if let name = fn["name"] as? String { entry.name += name }
                                        if let args = fn["arguments"] as? String {
                                            toolBytes += args.utf8.count
                                            guard toolBytes <= 1_048_576 else { throw ChatError.incomplete("工具参数总量超过1MB") }
                                            entry.args += args
                                        }
                                    }
                                    toolCallBuffer[index] = entry
                                    if entry.name == "$web_search", !searchNotified {
                                        searchNotified = true
                                        continuation.yield(.status("正在联网搜索…"))
                                    }
                                }
                            }
                        }
                        return false
                    }
                    if let http = response as? HTTPURLResponse,
                       let type = http.value(forHTTPHeaderField: "Content-Type"),
                       !type.lowercased().contains("text/event-stream") {
                        throw ChatError.incomplete("服务端未返回事件流，请检查模型服务地址与配置")
                    }
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        if let payload = try sse.consume(byte), try processPayload(payload) { break }
                    }
                    if !sawDone, let payload = try sse.finish() { _ = try processPayload(payload) }

                    if Task.isCancelled { throw CancellationError() }
                    if finishReason == "length" || finishReason == "content_filter" {
                        throw ChatError.incomplete(finishReason ?? "截断")
                    }
                    guard sawDone || finishReason == "stop" || finishReason == "tool_calls" else {
                        throw ChatError.incomplete("连接提前结束，缺少完成标记")
                    }
                    let calls = toolCallBuffer.sorted { $0.key < $1.key }
                        .map { ToolCall(id: $0.value.id, name: $0.value.name, arguments: $0.value.args) }
                    guard calls.count <= 24, calls.allSatisfy({ !$0.id.isEmpty && !$0.name.isEmpty && $0.arguments.utf8.count <= 262144 }) else {
                        throw ChatError.incomplete("工具调用缺少ID或超过安全上限")
                    }
                    guard !text.isEmpty || !calls.isEmpty else { throw ChatError.incomplete("服务端返回了空回复") }
                    if !calls.isEmpty {
                        continuation.yield(.toolCalls(calls, assistantText: text))
                    } else {
                        continuation.yield(.finished)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 一次性小请求（非流式、无工具）：查询规划等轻任务专用。
    /// thinkingDisabled：方舟等厂商的推理模型会把思考也计入 max_tokens，轻任务务必关闭。
    /// 失败/超时返回 nil —— 调用方必须有规则兜底，规划绝不能阻塞回答。
    static func completeOnce(profile: ChatProfile, apiKey: String, system: String, user: String, maxTokens: Int = 512, thinkingDisabled: Bool = false) async -> String? {
        guard let url = URL(string: "\(profile.baseURL)/chat/completions") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        var body: [String: Any] = [
            "model": profile.model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "stream": false,
            "temperature": 0.2,
            "max_tokens": maxTokens,
        ]
        if thinkingDisabled { body["thinking"] = ["type": "disabled"] }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await BoundedHTTPClient.data(for: request, session: BoundedHTTPClient.searchSession, limit: 262_144),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String, !content.isEmpty else { return nil }
        return content
    }

    /// Search is routed to one backend per request. Native support is declared by the provider adapter;
    /// unsupported providers and rejected native requests use the App-owned web_search tool.
    private func applyTools(to body: inout [String: Any], expertID: String, allowSearch: Bool = true, useNativeSearch: Bool) throws {
        let capability = try ExpertCapabilityCatalog.profile(expertID)
        let nativeSearch = capability.allowSearch && allowSearch && useNativeSearch
        if nativeSearch {
            switch profile.searchStyle {
            case .kimiBuiltin:
                body["tools"] = [["type": "builtin_function", "function": ["name": "$web_search"]]]
            case .zhipuTool:
                body["tools"] = [["type": "web_search", "web_search": ["enable": true]]]
            case .volcTool:
                body["tools"] = [["type": "web_search"]]
            case .dashscopeParam:
                body["enable_search"] = true
            case .none:
                break
            }
        }

        var tools = (body["tools"] as? [[String: Any]]) ?? []
        if capability.allowSearch && allowSearch && !nativeSearch { tools.append(["type": "function", "function": Self.webSearchFunction]) }
        if capability.allowImages { tools.append(["type": "function", "function": Self.generateImageFunction]) }
        tools.append(["type": "function", "function": Self.renderChartFunction])
        var document = Self.createDocumentFunction
        var parameters = document["parameters"] as? [String: Any] ?? [:]
        var properties = parameters["properties"] as? [String: Any] ?? [:]
        properties["format"] = ["type": "string", "enum": capability.documentFormats]
        parameters["properties"] = properties
        document["parameters"] = parameters
        if !capability.documentFormats.isEmpty { tools.append(["type": "function", "function": document]) }
        tools.append(["type": "function", "function": Self.expertSkillFunction(capability)])
        tools.append(["type": "function", "function": ["name": "search_library",
            "description": "在用户上传的本机专业资料中检索证据。企业制度、合同、财务资料优先使用该工具；只检索近200份前20000字符，未命中须说明。",
            "parameters": ["type": "object", "properties": ["query": ["type": "string"]], "required": ["query"]]]])
        body["tools"] = tools
    }

    private static func expertSkillFunction(_ capability: ExpertCapability) -> [String: Any] {
        var properties: [String: Any] = [
            "operation": ["type": "string", "enum": capability.calculators.isEmpty ? ["plan", "validate"] : ["plan", "calculate", "validate"]],
            "inputs_json": ["type": "string", "description": BusinessCalculators.inputGuide],
            "content": ["type": "string", "description": "待结构校验的Markdown正文"],
            "format": ["type": "string", "enum": capability.documentFormats],
        ]
        if !capability.calculators.isEmpty {
            properties["calculator"] = ["type": "string", "enum": capability.calculators]
        }
        return ["name": "expert_skill", "description": "读取本专家技能契约、执行本地确定性经营计算、检查交付章节。权限由App固定专家控制，不接受模型指定专家ID；校验只保证结构，不保证事实正确。",
                "parameters": ["type": "object", "properties": properties, "required": ["operation"]]]
    }

    /// 自定义联网搜索工具（App 本地执行，与模型厂商无关）
    ///
    /// 描述里写死「多实体逐个搜 + 宁缺毋滥」两条硬规则，
    /// 这是「收集 6 款机型参数」这类任务做不准的主要纠正点：
    /// 模型原本只用一句笼统关键词搜一次，然后靠记忆把空格填满。
    static let webSearchFunction: [String: Any] = [
        "name": "web_search",
        "description": """
        联网检索可变事实。搜索词写主体全名和待核实字段，多实体分开检索，优先补缺失字段，避免重复查询；App 有限并行执行并复用本轮证据。
        价格、规格、政策、新闻等时效信息必须核实。最新在售产品可早于近30天发布；仅当用户明确要求今天、本周、本月时限制发布时间。
        搜索摘要仅是线索。正文与对象、地区、版本和时间必须对应；不能用记忆或其他型号填空。字段证据不足写未核实，传闻单独标注，来源冲突保留。
        每个具体结论旁写（来源 N），表格来源列填 N。只引用真正支持结论的来源。App 显示标题与链接，不另写全量检索清单或重复来源表。
        """,
        "parameters": [
            "type": "object",
            "properties": [
                "recency": ["type": "string", "enum": ["any", "day", "week", "month", "year"], "description": "发布时间窗口：今天day、本周week、本月month；最新在售或无明确窗口any。日期未知必须注明未核实。"],
                "query": [
                    "type": "string",
                    "description": "具体搜索关键词：主体全名 + 要查的字段 + 年份（如「完整产品名 官方规格 电池」）",
                ],
            ],
            "required": ["query"],
        ],
    ]

    /// 本地统计图表工具：模型输出结构化数据，App 用 Swift Charts 渲染（数字准确，可放大保存）
    static let renderChartFunction: [String: Any] = [
        "name": "render_chart",
        "description": "把已核实的数值数据渲染成统计图（柱状图/折线图/环形图）。仅在数据全部来自本轮已核实来源或用户提供时调用；数字必须精确，禁止估计值。示意性/装饰性图像请改用 generate_image。",
        "parameters": [
            "type": "object",
            "properties": [
                "type": ["type": "string", "enum": ["bar", "line", "pie"], "description": "图表类型：对比用 bar、趋势用 line、占比用 pie"],
                "title": ["type": "string", "description": "图表标题：对象 + 口径（如「各机型官方起售价（元）」）"],
                "labels": ["type": "array", "items": ["type": "string"], "description": "每个数据点的名称（最多 8 个）"],
                "values": ["type": "array", "items": ["type": "number"], "description": "与 labels 一一对应的数值（最多 8 个）"],
                "unit": ["type": "string", "description": "数值单位（元 / mAh / % 等），无单位可省略"],
                "source_note": ["type": "string", "description": "数据来源说明（如「来源 1、3」或「用户提供」）"],
            ],
            "required": ["type", "title", "labels", "values"],
        ],
    ]

    /// 自定义生图工具定义
    static let generateImageFunction: [String: Any] = {
        let generateImageParameters: [String: Any] = [
            "type": "object",
            "properties": [
                "prompt": [
                    "type": "string",
                    "description": "详细的图像描述（中文），包含主体、风格、构图、文字内容等",
                ],
                "edit_last_image": [
                    "type": "boolean",
                    "description": "是否基于对话中最近一张生成的图片进行编辑修改",
                ],
            ],
            "required": ["prompt"],
        ]
        let functionDefinition: [String: Any] = [
            "name": "generate_image",
            "description": "生成或编辑图片。当用户要求画图、生成海报/配图/示意图，或要求修改对话中已有的图片时调用。注意：数据统计图/图表禁止使用本工具，请改用 Markdown 数据表呈现。返回后图片会自动展示给用户，你只需补充简短说明。",
            "parameters": generateImageParameters,
        ]
        return functionDefinition
    }()

    /// 自定义文档生成工具定义：让 AI 直接产出可下载的 Word/PPT/Excel/PDF
    static let createDocumentFunction: [String: Any] = {
        let parameters: [String: Any] = [
            "type": "object",
            "properties": [
                "format": [
                    "type": "string",
                    "enum": ["word", "ppt", "excel", "pdf"],
                    "description": "要生成的文件类型：word=Word 文档，ppt=PPT 演示，excel=Excel 表格，pdf=PDF",
                ],
                "filename": [
                    "type": "string",
                    "description": "文件名（含中文，不含扩展名），如「2026年经营计划」",
                ],
                "title": [
                    "type": "string",
                    "description": "文档标题",
                ],
                "theme": [
                    "type": "string",
                    "enum": ["business", "vivid", "formal", "academic"],
                    "description": "视觉主题：business=商务深蓝（默认）、vivid=彩色活泼（营销/活动）、formal=公文红头（法务/通知）、academic=学术严谨（报告/白皮书）",
                ],
                "content": [
                    "type": "string",
                    "description": "正文，使用 Markdown：# 一级标题、## 二级标题、- 列表项。PPT 用 --- 分页，每页第一行是标题；Excel 用 Markdown 表格。",
                ],
            ],
            "required": ["format", "filename", "content"],
        ]
        return [
            "name": "create_document",
            "description": "生成可下载的办公文件（Word / PPT / Excel / PDF）并存入资料库。当用户要求「整理成文档」「做成 PPT」「导出成 Word/Excel」「生成报告」时调用。调用后不要再重复输出正文，只做简短说明。",
            "parameters": parameters,
        ]
    }()
}
