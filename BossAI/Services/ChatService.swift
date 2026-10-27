import Foundation

//
//  ChatService.swift
//  BossAI（中防AI iPad App）— Services 层
//
//  文件职责：对话服务核心。对接 OpenAI 兼容的 Chat Completions 流式接口（SSE），
//  解析流式增量、工具调用与 usage，把各类事件通过 AsyncThrowingStream 交给上层。
//
//  在整个 App 中的角色：聊天的网络层单点。默认接 Kimi（Moonshot），内置 $web_search
//  由服务端执行；generate_image / render_chart / create_document 等自定义工具由
//  ChatViewModel 回调本地执行。搜索路由"每请求一个后端"：厂商原生搜索优先，
//  不支持或被拒绝时回退到 App 自有 web_search 工具。
//
//  关键设计决策：
//  - 流式解析用逐字节 SSEByteDecoder，逐段 processPayload，收到 [DONE] 或合法
//    finish_reason 才算完成——防"连接断开即当作正常结束"的隐性截断。
//  - 资源限额：正文/思考/工具参数各 1MB 上限、工具索引 ≤24、单个参数 ≤256KB，
//    防模型失控输出撑爆内存。
//  - 错误脱敏：手动 Key 模式不回显 baseURL/模型名/完整报文；云端会员模式只透出
//    服务端中文 message，不泄露上游细节。
//  - 原生搜索被拒（400/422）时自动改用 App 工具重试一次，绝不静默重复同一载荷。
//
//  防呆/安全冗余理由：
//  - 输出未完成（length/content_filter/缺完成标记）一律抛 incomplete，让上层
//    明确告知用户"回答可能不完整"而不是静默截断。
//  - usage 缺失时调用方回退估算，不阻塞流式。
//
/// 对话服务：OpenAI 兼容 Chat Completions 流式（SSE）+ 工具调用。
/// 默认接 Kimi（Moonshot）：内置 $web_search 由服务端执行；
/// generate_image 为本地自定义工具，由 ChatViewModel 回调执行。
final class ChatService {
    /// 一次工具调用的完整信息：模型流式返回的 id、工具名与合并后的参数 JSON 串
    struct ToolCall {
        /// 调用唯一 ID（回传结果时需要）
        let id: String
        /// 工具名（如 web_search / generate_image）
        let name: String
        /// 参数 JSON 字符串（流式分片已合并）
        let arguments: String
    }

    /// 流式过程中向上层抛出的各类事件
    enum StreamEvent {
        /// 正文增量片段
        case textDelta(String)
        /// 思考链增量（仅 API 续传用，绝不并入正文答案）
        case reasoningDelta(String) // API continuation only; never merged into the answer
        /// 状态提示（如"正在联网搜索…"）
        case status(String)          // 如"正在联网搜索…"
        /// 厂商拒绝其宣称支持的原生搜索载荷，已回退 App 工具
        case nativeSearchUnavailable // The provider rejected its advertised native-search payload.
        /// 模型请求调用工具（附带已累积的助手文本）
        case toolCalls([ToolCall], assistantText: String)
        /// 服务端返回的真实 token 数（用于精确计费/预算）
        case usage(promptTokens: Int, completionTokens: Int)   // 服务端返回的真实 token 数
        /// 流正常结束
        case finished
        /// 模型侧"有活动"信号（10-23 P0）：收到首个合法 SSE 帧即发一次。
        /// 用于首包 watchdog 判定——只出工具调用、只出思考链、只下发空 delta 的响应，
        /// 也证明上游已经响应，不能因为"没有正文"就被误判成超时。
        case activity
    }

    /// 对话请求错误，均带用户可读的中文描述
    enum ChatError: LocalizedError, APIErrorCarrying {
        // 未配置 Key / 手动 Key 模式的服务端异常
        case missingKey, badResponse(Int, String)
        /// 云端会员模式的结构化错误：状态码 / 服务端错误码 / 服务端中文消息（不泄露上游细节）
        case hosted(Int, String, String)
        /// 10-24：带完整信封（actions / requestId / retryable）的云端错误。
        /// 有了它，对话类错误也能在 UI 上给出「再试一次 / 修改描述 / 去续费」这些真实按钮。
        case envelope(APIErrorEnvelope)
        /// 输出未正常完成（截断/内容过滤/连接提前断开等），附原因
        case incomplete(String)
        /// 错误的用户可读文案
        var errorDescription: String? {
            switch self {
            case .missingKey: return "未配置对话 API Key"
            case .badResponse(let code, let body): return "请求失败（\(code)）：\(body.prefix(300))"
            case .hosted(_, _, let message): return message
            case .envelope(let e): return e.message
            case .incomplete(let reason): return "输出尚未完成（\(reason)）。"
            }
        }
        /// 会话失效（重置密码/封停/到期）——调用方据此强制登出
        var isSessionFailure: Bool {
            if case .envelope(let e) = self { return e.isSessionFailure }
            if case .hosted(let status, let code, _) = self {
                return status == 401 || code == "ACCOUNT_SUSPENDED" || code == "MEMBERSHIP_EXPIRED"
            }
            return false
        }

        /// 结构化信封（旧服务端为 nil）
        var envelope: APIErrorEnvelope? {
            if case .envelope(let e) = self { return e }
            return nil
        }
    }

    private let profile: ChatProfile
    /// API Key 提供者（闭包注入，便于测试与运行时切换）
    private let apiKeyProvider: () -> String?
    /// 聊天专用会话（带超时与响应体上限约束）
    private let session: URLSession
    /// - Parameters:
    ///   - profile: 对话服务商档案（baseURL/模型名/搜索样式等）
    ///   - apiKeyProvider: 返回 API Key 的闭包
    ///   - session: 使用的 URLSession，默认聊天专用会话
    init(profile: ChatProfile, apiKeyProvider: @escaping () -> String?, session: URLSession = BoundedHTTPClient.chatSession) {
        self.profile = profile
        self.apiKeyProvider = apiKeyProvider
        self.session = session
    }

    /// 当前对话配置的展示标签（服务商名 / 模型名）
    var configurationLabel: String { profile.displayName + " / " + profile.model }

    /// 当前是否优先使用厂商原生搜索：需用户开启"优先服务商搜索"，且该服务商
    /// 声明支持某种原生搜索样式；否则走 App 自有 web_search 工具
    var prefersNativeSearch: Bool {
        guard AppConfig.preferProviderSearch else { return false }
        switch profile.searchStyle {
        case .none: return false
        case .kimiBuiltin, .zhipuTool, .dashscopeParam, .volcTool: return true
        }
    }

    /// 单次请求流。工具调用通过 toolCalls 事件交给调用方处理，调用方追加 tool 结果后再次调用本方法继续。
    func stream(messages: [[String: Any]], enableTools: Bool, expertID: String = "general", allowSearch: Bool = true, useNativeSearch: Bool? = nil, tier: String = "flash", fastMode: Bool = false, expertTools: [ExpertTool]? = nil, chatMode: String? = nil) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let span = PerformanceTrace.begin("AIRequest")
                defer { PerformanceTrace.end("AIRequest", span) }
                var receivedFirstDelta = false
                do {
                    guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else { throw ChatError.missingKey }
                    guard let url = URL(string: "\(profile.baseURL)/chat/completions") else {
                        throw ChatError.incomplete("服务地址无效")
                    }
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    // 声明接受事件流：让服务端明确走 SSE，而不是一次性返回 JSON
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    // P0-64 超时云端可调（在线可修复）：管理台改 APP_CHAT_TIMEOUT 即生效
                    request.timeoutInterval = HostedAccount.isHostedActive ? HostedAccount.cachedChatTimeout : 120

                    var body: [String: Any] = [
                        "model": profile.model,
                        "messages": messages,
                        "stream": true,
                        "temperature": 0.6,
                    ]
                    ModelRequestAdapter.apply(to: &body, profile: profile, purpose: .chat,
                                              thinking: fastMode ? .fast : .default)
                    // 混合路由：tier=pro 时服务端切到重思考旗舰（在线研究等深度任务）
                    if tier == "pro" { body["tier"] = "pro" }
                    if let cm = chatMode { body["chatMode"] = cm }   // P0-38 配置面板档位（标准/高/最高）
                    if enableTools {
                        try applyTools(to: &body, expertID: expertID, allowSearch: allowSearch, useNativeSearch: useNativeSearch ?? prefersNativeSearch, expertTools: expertTools)
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
                        try applyTools(to: &fallbackBody, expertID: expertID, allowSearch: allowSearch, useNativeSearch: false, expertTools: expertTools)
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
                        // 云端会员模式：服务端返回结构化中文错误——只透出 message，
                        // 不泄露上游细节；会话失效（重置密码/封停/到期）统一强制登出
                        if profile.id == "hosted",
                           let data = errBody.data(using: .utf8),
                           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            // 10-24：先尝试完整信封（含 actions / requestId），
                            // 拿不到再退回旧的两字段形态，保证老服务端兼容。
                            if let env = APIErrorEnvelope.parse(status: http.statusCode, json: obj) {
                                let err = ChatError.envelope(env)
                                if err.isSessionFailure {
                                    await HostedAccount.shared.handleSessionFailure(env.message)
                                }
                                throw err
                            }
                            if let message = obj["message"] as? String {
                                let code = (obj["error"] as? String) ?? ""
                                let hostedErr = ChatError.hosted(http.statusCode, code, message)
                                if hostedErr.isSessionFailure {
                                    await HostedAccount.shared.handleSessionFailure(message)
                                }
                                throw hostedErr
                            }
                        }
                        // 手动 Key 模式：脱敏——不回显 baseURL / 模型名 / 完整上游报文
                        throw ChatError.badResponse(
                            http.statusCode,
                            "服务商响应异常（\(http.statusCode)），请稍后重试或检查 Key 配置。\(String(errBody.suffix(200)))"
                        )
                    }

                    var text = ""
                    var textBytes = 0
                    var toolBytes = 0
                    var toolCallBuffer: [Int: (id: String, name: String, args: String)] = [:]
                    var searchNotified = false
                    var sse = SSEByteDecoder()
                    var sawDone = false
                    var sawFirstActivity = false
                    var finishReason: String?

                    /// 处理一条 SSE payload：解析 JSON 增量、累积工具调用、捕获 usage。
                    /// 返回 true 表示流应结束（[DONE]）；非法 JSON 或服务端内嵌 error 则抛 incomplete
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
                        // 10-23 P0：任何合法 chunk（哪怕 delta 为空、只有 role 或只有工具分片）
                        // 都说明模型已经响应；先发一次活动信号，再看具体增量。
                        if !sawFirstActivity {
                            sawFirstActivity = true
                            continuation.yield(.activity)
                        }
                        if let reason = choice["finish_reason"] as? String { finishReason = reason }

                        if let delta = choice["delta"] as? [String: Any] {
                            // 思考链：计入工具/思考字节预算（1MB），防止推理失控
                            if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                                toolBytes += reasoning.utf8.count
                                guard toolBytes <= 1_048_576 else { throw ChatError.incomplete("思考及工具内容超过上限") }
                                continuation.yield(.reasoningDelta(reasoning))
                            }
                            // 正文增量：记录首包时延（性能观测）并计入 1MB 输出预算
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
                            // 工具调用分片：按 index 累积（厂商会把一次调用的
                            // id/name/arguments 拆成多个 chunk 陆续下发）
                            if let tcs = delta["tool_calls"] as? [[String: Any]] {
                                if !tcs.isEmpty && !receivedFirstDelta {
                                    receivedFirstDelta = true
                                    PerformanceTrace.event("FirstDelta", span)
                                }
                                for tc in tcs {
                                    // 索引防越界：超过 24 个并行工具调用视为异常流
                                    let index = tc["index"] as? Int ?? 0
                                    guard (0..<24).contains(index) else { throw ChatError.incomplete("工具索引超过上限") }
                                    var entry = toolCallBuffer[index] ?? (id: "", name: "", args: "")
                                    // P0-45 修复（实测千问流式格式）：分片会携带 "id":""（空串）——
                                    // 旧代码 `if let id` 会把空串当成有效值，覆盖首片的真实 ID，
                                    // 最终触发"工具调用缺少ID"并把整条回复丢掉。空串一律不覆盖。
                                    if let id = tc["id"] as? String, !id.isEmpty { entry.id = id }
                                    if let fn = tc["function"] as? [String: Any] {
                                        // name 与 arguments 都可能分片下发，必须累加而非覆盖
                                        if let name = fn["name"] as? String { entry.name += name }
                                        if let args = fn["arguments"] as? String {
                                            toolBytes += args.utf8.count
                                            guard toolBytes <= 1_048_576 else { throw ChatError.incomplete("工具参数总量超过1MB") }
                                            entry.args += args
                                        }
                                    }
                                    toolCallBuffer[index] = entry
                                    // 首次命中内置搜索时向上层发状态提示，之后不再重复
                                    if entry.name == "$web_search", !searchNotified {
                                        searchNotified = true
                                        continuation.yield(.status("正在联网搜索…"))
                                    }
                                }
                            }
                        }
                        return false
                    }
                    // 校验响应类型：非 SSE 说明配置错误（如地址指到了非流式端点），提前失败
                    if let http = response as? HTTPURLResponse,
                       let type = http.value(forHTTPHeaderField: "Content-Type"),
                       !type.lowercased().contains("text/event-stream") {
                        throw ChatError.incomplete("服务端未返回事件流，请检查模型服务地址与配置")
                    }
                    // 主循环：逐字节喂给 SSE 解码器，攒出完整 payload 再处理；[DONE] 即止
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        if let payload = try sse.consume(byte), try processPayload(payload) { break }
                    }
                    // 兜底：部分厂商不发 [DONE] 就关流，把解码器残余缓冲处理完
                    if !sawDone, let payload = try sse.finish() { _ = try processPayload(payload) }

                    if Task.isCancelled { throw CancellationError() }
                    // 截断判定：length=长度上限截断，content_filter=内容过滤——都属"未完成"
                    if finishReason == "length" || finishReason == "content_filter" {
                        throw ChatError.incomplete(finishReason ?? "截断")
                    }
                    // 完整性校验：既没有 [DONE] 也没有合法 finish_reason，视为异常断流
                    guard sawDone || finishReason == "stop" || finishReason == "tool_calls" else {
                        throw ChatError.incomplete("连接提前结束，缺少完成标记")
                    }
                    // 工具调用汇总与归一化（P0-45，借鉴 DeepSeek Harness 的"管道归一化"原则）：
                    // 畸形调用（缺 ID / 缺名 / 超参）只丢弃自身，绝不牵连整轮回复——
                    // 只要能解析出正文或至少一个有效调用，就正常完成；全部无效才视为服务端异常。
                    let rawCalls = toolCallBuffer.sorted { $0.key < $1.key }
                        .map { ToolCall(id: $0.value.id, name: $0.value.name, arguments: $0.value.args) }
                    let validCalls = Array(rawCalls
                        .filter { !$0.id.isEmpty && !$0.name.isEmpty && $0.arguments.utf8.count <= 262_144 }
                        .prefix(24))
                    if validCalls.count < rawCalls.count {
                        PerformanceTrace.event("ToolCallsNormalized")   // 观测：被归一化丢弃的畸形调用次数
                    }
                    // 空回复防呆：既无正文也无有效工具调用，视为服务端异常
                    guard !text.isEmpty || !validCalls.isEmpty else { throw ChatError.incomplete("服务端返回了空回复") }
                    if !validCalls.isEmpty {
                        continuation.yield(.toolCalls(validCalls, assistantText: text))
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
    /// 按专家能力组装请求体中的 tools 列表。
    /// 搜索只路由到一个后端：厂商声明支持原生搜索且未被禁用时用原生样式；
    /// 不支持或被拒绝的厂商改挂 App 自有 web_search 工具。
    /// 另外始终追加 render_chart；按专家能力追加 generate_image、create_document
    /// （format 枚举按专家文档格式动态收窄）、expert_skill 与 search_library。
    /// - Throws: 专家能力档案缺失时抛出
    // MARK: - P0-40 工具权限解析（纯函数，供单测）

    /// 某位专家当前可用的工具权限集合。
    struct ToolPermissions: Equatable {
        let canSearch: Bool
        let canImage: Bool
        /// 可导出的文档格式（word/ppt/excel/pdf 的 rawValue 子集）
        let docFormats: [String]
    }

    /// 解析工具权限：**以云端下发的专家工具列表为单一数据源**；列表缺失（nil）时回退本地能力档案。
    /// 这是"云端开了生图、App 却未挂工具、模型如实拒绝"历史缺陷的回归锚点——
    /// 任何未来改动都必须保持：expertTools 提供的工具一定生效，不被本地档案否决。
    static func resolveToolPermissions(expertID: String, expertTools: [ExpertTool]?) throws -> ToolPermissions {
        let capability = try ExpertCapabilityCatalog.profile(expertID)
        let canSearch = expertTools?.contains(.search) ?? capability.allowSearch
        let canImage = expertTools?.contains(.image) ?? capability.allowImages
        let docFormats: [String]
        if let et = expertTools {
            docFormats = et.filter { [.word, .ppt, .excel, .pdf].contains($0) }.map { $0.rawValue }
        } else {
            docFormats = capability.documentFormats
        }
        return ToolPermissions(canSearch: canSearch, canImage: canImage, docFormats: docFormats)
    }

    /// P0-40 工具挂载以「专家的实际工具列表」为准（云端下发），本地能力档案只作兜底——
    /// 此前用本地 ExpertSkills.json 的 allowImages 判定，导致"云端已开放生图、App 仍不挂工具、模型如实拒绝"的不一致。
    /// 10-23：统一使用 EffectiveToolPolicy 作为单一事实源，避免注册表、能力清单、执行器权限不一致。
    private func applyTools(to body: inout [String: Any], expertID: String, allowSearch: Bool = true, useNativeSearch: Bool, expertTools: [ExpertTool]? = nil) throws {
        let capability = try ExpertCapabilityCatalog.profile(expertID)
        let policy = try EffectiveToolPolicy.forExpertID(expertID, expertTools: expertTools)
        let canSearch = policy.canSearch && allowSearch
        let canImage = policy.canImage
        let nativeSearch = canSearch && useNativeSearch
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
        tools += ToolManifest.definitions(policy: policy, capability: capability, includeSearch: canSearch && !nativeSearch)
        body["tools"] = tools
    }

    // Compatibility accessors; schemas are declared only by ToolManifest.
    static var webSearchFunction: [String: Any] { ToolManifest.webSearchFunction }
    static var renderChartFunction: [String: Any] { ToolManifest.renderChartFunction }
    static var generateImageFunction: [String: Any] { ToolManifest.generateImageFunction }
    static var imageGenerateFunction: [String: Any] { ToolManifest.imageGenerateFunction }
    static var imageEditFunction: [String: Any] { ToolManifest.imageEditFunction }
    static var imageDecomposeFunction: [String: Any] { ToolManifest.imageDecomposeFunction }
    static var imageSeriesFunction: [String: Any] { ToolManifest.imageSeriesFunction }
    static var imageToolPlugins: [(name: String, definition: [String: Any])] { ToolManifest.imageToolPlugins }
    static var createDocumentFunction: [String: Any] { ToolManifest.createDocumentFunction }
}
