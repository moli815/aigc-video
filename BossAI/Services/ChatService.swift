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
        case finished
    }

    enum ChatError: LocalizedError {
        case missingKey, badResponse(Int, String)
        var errorDescription: String? {
            switch self {
            case .missingKey: return "未配置对话 API Key"
            case .badResponse(let code, let body): return "请求失败（\(code)）：\(body.prefix(300))"
            }
        }
    }

    private let profile: ChatProfile
    private let apiKeyProvider: () -> String?
    init(profile: ChatProfile, apiKeyProvider: @escaping () -> String?) {
        self.profile = profile
        self.apiKeyProvider = apiKeyProvider
    }

    /// 单次请求流。工具调用通过 toolCalls 事件交给调用方处理，调用方追加 tool 结果后再次调用本方法继续。
    func stream(messages: [[String: Any]], enableTools: Bool) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else { throw ChatError.missingKey }
                    var request = URLRequest(url: URL(string: "\(profile.baseURL)/chat/completions")!)
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.timeoutInterval = 120

                    var body: [String: Any] = [
                        "model": profile.model,
                        "messages": messages,
                        "stream": true,
                        "temperature": 0.6,
                    ]
                    if enableTools {
                        applyTools(to: &body)
                    }
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var errBody = ""
                        for try await line in bytes.lines { errBody += line }
                        throw ChatError.badResponse(
                            http.statusCode,
                            "服务商 \(profile.displayName)｜\(profile.baseURL)/chat/completions｜模型 \(profile.model)\n\(errBody)"
                        )
                    }

                    var text = ""
                    var toolCallBuffer: [Int: (id: String, name: String, args: String)] = [:]
                    var searchNotified = false

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let choice = choices.first else { continue }

                        if let delta = choice["delta"] as? [String: Any] {
                            if let content = delta["content"] as? String, !content.isEmpty {
                                text += content
                                continuation.yield(.textDelta(content))
                            }
                            if let tcs = delta["tool_calls"] as? [[String: Any]] {
                                for tc in tcs {
                                    let index = tc["index"] as? Int ?? 0
                                    var entry = toolCallBuffer[index] ?? (id: "", name: "", args: "")
                                    if let id = tc["id"] as? String { entry.id = id }
                                    if let fn = tc["function"] as? [String: Any] {
                                        if let name = fn["name"] as? String { entry.name += name }
                                        if let args = fn["arguments"] as? String { entry.args += args }
                                    }
                                    toolCallBuffer[index] = entry
                                    if entry.name == "$web_search", !searchNotified {
                                        searchNotified = true
                                        continuation.yield(.status("正在联网搜索…"))
                                    }
                                }
                            }
                        }
                    }

                    let calls = toolCallBuffer.sorted { $0.key < $1.key }
                        .map { ToolCall(id: $0.value.id, name: $0.value.name, arguments: $0.value.args) }
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
    private func applyTools(to body: inout [String: Any]) {
        // 少数厂商的服务端搜索质量更高，可在设置里开启作为增强
        if AppConfig.preferProviderSearch {
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
        tools.append(["type": "function", "function": Self.webSearchFunction])
        tools.append(["type": "function", "function": Self.generateImageFunction])
        tools.append(["type": "function", "function": Self.createDocumentFunction])
        body["tools"] = tools
    }

    /// 自定义联网搜索工具（App 本地执行，与模型厂商无关）
    static let webSearchFunction: [String: Any] = [
        "name": "web_search",
        "description": "联网搜索最新信息。查资讯、行情、政策、竞品动态、平台规则、价格、新闻时必须调用，不要凭记忆回答时效性问题。",
        "parameters": [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description": "搜索关键词，尽量具体，包含主体与年份（如「2026 年 餐饮加盟 政策」）",
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
