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
    }

    /// 对话请求错误，均带用户可读的中文描述
    enum ChatError: LocalizedError {
        // 未配置 Key / 手动 Key 模式的服务端异常
        case missingKey, badResponse(Int, String)
        /// 云端会员模式的结构化错误：状态码 / 服务端错误码 / 服务端中文消息（不泄露上游细节）
        case hosted(Int, String, String)
        /// 输出未正常完成（截断/内容过滤/连接提前断开等），附原因
        case incomplete(String)
        /// 错误的用户可读文案
        var errorDescription: String? {
            switch self {
            case .missingKey: return "未配置对话 API Key"
            case .badResponse(let code, let body): return "请求失败（\(code)）：\(body.prefix(300))"
            case .hosted(_, _, let message): return message
            case .incomplete(let reason): return "输出尚未完成（\(reason)）。"
            }
        }
        /// 会话失效（重置密码/封停/到期）——调用方据此强制登出
        var isSessionFailure: Bool {
            if case .hosted(let status, let code, _) = self {
                return status == 401 || code == "ACCOUNT_SUSPENDED" || code == "MEMBERSHIP_EXPIRED"
            }
            return false
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
                           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let message = obj["message"] as? String {
                            let code = (obj["error"] as? String) ?? ""
                            let hostedErr = ChatError.hosted(http.statusCode, code, message)
                            if hostedErr.isSessionFailure {
                                await HostedAccount.shared.handleSessionFailure(message)
                            }
                            throw hostedErr
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

        // P0-59 可用性预过滤（对照 Hermes check_fn 语义）：不可用的能力不进 tools[]——
        // 模型看不到就不会误调用/不会谎报能做到（"调用顺畅且不易出错"的第一道防线）
        // 10-23：policy.availableToolIDs 已经统一应用「本地可用性 + 云端开关」
        var tools = (body["tools"] as? [[String: Any]]) ?? []
        if canSearch && !nativeSearch && policy.availableToolIDs.contains("web_search") { tools.append(["type": "function", "function": Self.webSearchFunction]) }
        // 10-19 拆 4 工具（仿 Harness 插件契约）：只注册职责隔离的 4 个新工具；
        // 旧 generate_image 不再注册（执行分支仍兼容旧名，防旧模型残留调用）
        if canImage {
            // 10-22 修复：逐个按插件 ID 过滤。此前只检查旧 ID "generate_image" 就整批注册，
            // 导致 availability=false 的 image_decompose / image_series 仍出现在 tools[] 里——
            // 模型看得见就会尝试调用，执行器再拒绝，白白消耗一轮。
            for plugin in Self.imageToolPlugins where policy.availableToolIDs.contains(plugin.name) {
                tools.append(["type": "function", "function": plugin.definition])
            }
        }
        if policy.availableToolIDs.contains("render_chart") { tools.append(["type": "function", "function": Self.renderChartFunction]) }
        // 文档导出工具：可导出格式由 EffectiveToolPolicy 统一给出（云端工具优先，本地档案兜底）
        if !policy.docFormats.isEmpty && policy.availableToolIDs.contains("create_document") {
            var document = Self.createDocumentFunction
            var parameters = document["parameters"] as? [String: Any] ?? [:]
            var properties = parameters["properties"] as? [String: Any] ?? [:]
            properties["format"] = ["type": "string", "enum": policy.docFormats]
            parameters["properties"] = properties
            document["parameters"] = parameters
            tools.append(["type": "function", "function": document])
        }
        if policy.availableToolIDs.contains("expert_skill") { tools.append(["type": "function", "function": Self.expertSkillFunction(capability)]) }
        if policy.availableToolIDs.contains("search_library") {
            tools.append([
                "type": "function",
                "function": [
                    "name": "search_library",
                    "description": "在用户上传的本机专业资料中检索证据。企业制度、合同、财务资料优先使用该工具；只检索近200份前20000字符，未命中须说明。",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "query": ["type": "string"]
                        ],
                        "required": ["query"]
                    ]
                ]
            ])
        }
        body["tools"] = tools
    }

    /// 构造 expert_skill 工具定义：operation 枚举按专家是否带计算器动态收窄，
    /// calculator 参数仅在有可用计算器时暴露，防模型调用不存在的计算器
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
                    "description": "是否以对话中最近一张生成的图片为底图（如「把这张海报改一改」）。若同时要把用户上传的图（Logo/素材）叠加到底图上，edit_last_image 与 use_attached_image 同时设为 true",
                ],
                "use_attached_image": [
                    "type": "boolean",
                    "description": "是否使用用户本轮上传的图片：①单独 true = 编辑上传的图；②与 edit_last_image 同时 true = 双图融合（把上传的 Logo/素材叠加到最近生成的图上，提示词里说明叠加位置），如「把 Logo 加到刚才的海报上」「在图片二上面加我们的 logo」等场景",
                ],
            ],
            "required": ["prompt"],
        ]
        let functionDefinition: [String: Any] = [
            "name": "generate_image",
            "description": "生成或编辑图片（兼容旧名；新代码请用 image_generate / image_edit）。",
            "parameters": generateImageParameters,
        ]
        return functionDefinition
    }()

    // ── 10-19 拆 4 工具（仿 Harness"工具即契约"）：职责隔离，消除"忘带图→退化成文生图" ──

    /// ① 纯文生图：**不存在**任何图片入参（模型想"编辑"只能换工具）
    /// 10-21 新增 structured：把需求拆成 7 个视觉字段，服务端按模板拼装成专业 prompt（信息更可控、文字更准）
    static let imageGenerateFunction: [String: Any] = [
        "name": "image_generate",
        "description": "纯文生图：根据文字描述从零生成一张新图片（海报、插画、示意图等）。**没有任何参考图入参**——用户要修改已有图片时必须改用 image_edit，禁止用本工具处理「改图/加东西/换背景」。数据统计图请改用 Markdown 数据表。**优先用 structured 传结构化字段**（信息更可控、画面文字更准确）；只有确实无法拆分时才用 prompt。",
        "parameters": [
            "type": "object",
            "properties": [
                "prompt": ["type": "string", "description": "（可选，structured 的兜底）详细的图像描述（中文）：主体、场景、构图、光影、材质、文字"],
                "structured": [
                    "type": "object",
                    "description": "结构化视觉字段（推荐）：每字段用完整短句描述，每段独立成句。内容必须来自用户需求，禁止套用示例的具体主体/场景，禁止编造用户未给的店名/地址/电话/价格。",
                    "properties": [
                        "subject": ["type": "string", "description": "主体：是什么、什么状态、在做什么"],
                        "setting": ["type": "string", "description": "场景/环境：地点、前后景、环境元素"],
                        "composition": ["type": "string", "description": "镜头/构图：视角（俯/平/仰）、焦段、主体位置、留白区域"],
                        "lighting": ["type": "string", "description": "光影：光源方向、色温、明暗关系、阴影特征"],
                        "material": ["type": "string", "description": "材质/画质：纹理细节、摄影或插画风格"],
                        "text": ["type": "string", "description": "画面文字：要渲染的精确文案 + 位置（用户没给就不填）"],
                        "negative": ["type": "string", "description": "排除项：不要出现的内容，以「禁止」开头"],
                    ],
                    "required": ["subject", "setting", "composition", "lighting", "material"],
                ],
            ],
            "required": [],
        ],
    ]

    /// ② 图生图编辑：source 必须明确指定底图（enum 强制，不再靠两个 boolean 猜）
    static let imageEditFunction: [String: Any] = [
        "name": "image_edit",
        "description": "编辑已有图片（改风格/加元素/去元素/换背景）。**source 必填**：last=最近生成的图、attached=用户本轮上传的图、both=双图融合（底图+上传素材）。用户说「这张图/这张照片」且刚上传过图 → attached；说「刚才那张/你生成的」→ last；要把 Logo/人物加到生成图上 → both。",
        "parameters": [
            "type": "object",
            "properties": [
                "prompt": ["type": "string", "description": "编辑指令：具体改什么、在哪里、保持什么不变（会由服务端叠加一致性/阴影/保持/排除约束）"],
                "source": [
                    "type": "string",
                    "enum": ["last", "attached", "both"],
                    "description": "底图来源：last=最近生成 | attached=用户上传 | both=双图融合（第一张为底图，第二张为叠加素材）",
                ],
            ],
            "required": ["prompt", "source"],
        ],
    ]

    /// ③ 图层拆分：把图片拆成底图 + 可独立编辑的图层（Seedream Pro/Flash 能力）
    static let imageDecomposeFunction: [String: Any] = [
        "name": "image_decompose",
        "description": "图层拆分：把一张图拆成 1 张底图 + 若干独立图层（便于后续单独替换/移动元素）。用户说「拆图层/分层/把元素分开」时使用。仅支持已有图片（最近生成的图或用户上传的图）。",
        "parameters": [
            "type": "object",
            "properties": [
                "prompt": ["type": "string", "description": "说明要拆哪些元素（可选；不填则整体拆分）"],
                "source": ["type": "string", "enum": ["last", "attached"], "description": "拆分哪张图：last=最近生成 | attached=用户上传"],
            ],
            "required": ["source"],
        ],
    ]

    /// ④ 组图（多张关联图）：仅 Seedream 5.0 Lite 支持（Pro 传参直接 400）
    static let imageSeriesFunction: [String: Any] = [
        "name": "image_series",
        "description": "组图生成：一次生成多张内容关联的图片（漫画分镜、品牌视觉系列）。用户说「生成一组/一套/N张/分镜」时使用。注意：需模型支持组图能力，当前若不可用会返回明确提示。",
        "parameters": [
            "type": "object",
            "properties": [
                "prompt": ["type": "string", "description": "整组图的统一描述（各图差异点写清楚）"],
                "count": ["type": "integer", "description": "生成张数（1-4）"],
            ],
            "required": ["prompt"],
        ],
    ]

    /// 4 工具注册表（仿 Harness 的插件契约表：新增能力只加一项）
    static let imageToolPlugins: [(name: String, definition: [String: Any])] = [
        ("image_generate", imageGenerateFunction),
        ("image_edit", imageEditFunction),
        ("image_decompose", imageDecomposeFunction),
        ("image_series", imageSeriesFunction),
    ]

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