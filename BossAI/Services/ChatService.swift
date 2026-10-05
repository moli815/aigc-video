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
        case status(String)          // 如"正在联网搜索…"
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

    /// 单次请求流。工具调用通过 toolCalls 事件交给调用方处理，调用方追加 tool 结果后再次调用本方法继续。
    func stream(messages: [[String: Any]], enableTools: Bool, expertID: String = "general") -> AsyncThrowingStream<StreamEvent, Error> {
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
                    if enableTools {
                        try applyTools(to: &body, expertID: expertID)
                    }
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await session.bytes(for: request)
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

    /// 挂载工具。联网搜索改为 App 自带的本地工具（web_search），
    /// 不再依赖模型厂商的搜索能力 —— 换任何模型商都不会掉联网功能。
    private func applyTools(to body: inout [String: Any], expertID: String) throws {
        let capability = try ExpertCapabilityCatalog.profile(expertID)
        // 少数厂商的服务端搜索质量更高，可在设置里开启作为增强
        if capability.allowSearch && AppConfig.preferProviderSearch {
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
        if capability.allowSearch { tools.append(["type": "function", "function": Self.webSearchFunction]) }
        if capability.allowImages { tools.append(["type": "function", "function": Self.generateImageFunction]) }
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
        联网搜索最新信息。查资讯、行情、政策、竞品动态、平台规则、价格、产品参数、发布时间、新闻时必须调用。

        【使用规则，必须严格遵守】
        1. 不要凭记忆回答任何可能随时间变化的事实（发布时间、价格、规格参数、政策条文、榜单排名），一律先搜后答。
        2. 涉及多个实体（多个机型、多家竞品、多个平台、多个品牌）时，必须**为每个实体单独发起一次搜索**。\
        严禁只用一句笼统关键词（如"旗舰手机参数对比"）试图一次覆盖全部实体 —— 那样必然漏字段、串行错位。
        3. 你可以在同一轮里**同时发起多个 web_search 调用**，系统会并行执行，不会变慢。
        4. 搜索词要带主体全名 + 具体字段，例如「小米18 Pro 参数 屏幕 电池 影像」「Mate 80 发布时间 售价」，\
        而不是「手机参数」。查某个字段就写清那个字段。
        5. 某个字段搜不到时，一律填「未核实」或「未公开」。\
        绝对禁止用记忆里的数字、其他型号的数字、或从无关来源拼接出来的数字去填空。宁可空着，也不能错。
        6. 汇总成大表格之前，先列出本轮实际引用到的来源链接清单，再输出表格。
        7. 不同来源给出冲突数值时，保留冲突并在表格里标注「来源不一致」，不要擅自选一个。
        """,
        "parameters": [
            "type": "object",
            "properties": [
                "recency": ["type": "string", "enum": ["any", "day", "week", "month", "year"], "description": "资讯时效：今天day、本周week、最新month；无明确时效any。日期未知必须注明未核实。"],
                "query": [
                    "type": "string",
                    "description": "具体搜索关键词：主体全名 + 要查的字段 + 年份（如「小米18 Pro 参数 屏幕 电池 影像」）",
                ],
            ],
            "required": ["query"],
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
            "description": "生成或编辑图片。当用户要求画图、生成海报/配图/示意图，或要求修改对话中已有的图片时调用。返回后图片会自动展示给用户，你只需补充简短说明。",
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
