import Foundation
import SwiftData
import UIKit

/// 单个会话的对话逻辑：
/// 流式回复、联网搜索、generate_image 生图、create_document 生成文档、附件注入、记忆抽取
@MainActor
final class ChatViewModel: ObservableObject {
    @Published var inputText = ""
    @Published var isStreaming = false
    @Published var statusText: String?
    @Published var errorMessage: String?
    /// 待发送的附件
    @Published var pendingAttachments: [StoredFile] = []
    @Published var isImporting = false
    @Published var toast: String?
    /// 流式输出中的文本（不落库，只驱动 UI，消除每 delta 写 SwiftData 的卡顿）
    @Published var streamingText = ""
    /// 正在流式输出的消息 id
    @Published var streamingMessageId: UUID?

    /// 会话（nil = 草稿态：用户还没发第一条消息，此时不写入数据库）
    private(set) var conversation: Conversation?
    /// 草稿态首次发消息、真正建出会话时回调，用于侧栏切换过去
    var onConversationCreated: ((Conversation) -> Void)?
    let expert: Expert

    private var chatService: ChatService { ChatService(profile: ProviderCatalog.currentChat(), apiKeyProvider: chatKey) }
    private var imageService: ImageService { ImageService(profile: ProviderCatalog.currentImage(), apiKeyProvider: imageKey) }
    private var memoryService: MemoryService { MemoryService(profile: ProviderCatalog.currentChat(), apiKeyProvider: chatKey) }
    private let chatKey: () -> String?
    private let imageKey: () -> String?
    private let modelContext: ModelContext
    private var streamTask: Task<Void, Never>?

    private var roundsSinceExtraction = 0
    private var fileCache: [UUID: StoredFile] = [:]
    private var fileCacheLoaded = false
    /// 本轮联网搜索的结果，作为「信息来源」附在回答末尾
    private var lastSearchContext: String?

    init(conversation: Conversation?,
         expert: Expert,
         modelContext: ModelContext,
         chatKey: @escaping () -> String?,
         imageKey: @escaping () -> String?) {
        self.conversation = conversation
        self.expert = expert
        self.modelContext = modelContext
        self.chatKey = chatKey
        self.imageKey = imageKey
    }

    var sortedMessages: [Message] {
        (conversation?.messages ?? []).sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: - 附件

    /// 从文件选择器导入（支持多选、多种类型）
    func attach(urls: [URL]) {
        guard !urls.isEmpty else { return }
        isImporting = true
        Task {
            var added: [StoredFile] = []
            for url in urls {
                let (data, text) = await FileImportService.load(url: url)
                guard !data.isEmpty else { continue }
                let name = url.lastPathComponent
                if let record = try? FileStore.store(data: data,
                                                     filename: name,
                                                     kind: .uploaded,
                                                     sourceConversationId: conversation?.id.uuidString ?? "",
                                                     textContent: text,
                                                     context: modelContext) {
                    added.append(record)
                }
            }
            pendingAttachments.append(contentsOf: added)
            invalidateFileCache()
            isImporting = false
        }
    }

    /// 从相册或相机导入图片
    func attach(images: [UIImage]) {
        guard !images.isEmpty else { return }
        isImporting = true
        Task {
            var added: [StoredFile] = []
            for (index, image) in images.enumerated() {
                guard let data = image.ocrFriendlyJPEG() else { continue }
                let name = "照片_\(Self.timestamp())_\(index + 1).jpg"
                let text = await FileImportService.ocr(imageData: data)
                if let record = try? FileStore.store(data: data,
                                                     filename: name,
                                                     kind: .uploaded,
                                                     sourceConversationId: conversation?.id.uuidString ?? "",
                                                     textContent: text,
                                                     context: modelContext) {
                    added.append(record)
                }
            }
            pendingAttachments.append(contentsOf: added)
            invalidateFileCache()
            isImporting = false
        }
    }

    func removeAttachment(_ file: StoredFile) {
        pendingAttachments.removeAll { $0.id == file.id }
    }

    func files(for message: Message) -> [StoredFile] {
        let ids = message.attachmentIdList
        guard !ids.isEmpty else { return [] }
        ensureFileCache()
        return ids.compactMap { key in
            guard let uuid = UUID(uuidString: key) else { return nil }
            return fileCache[uuid]
        }
    }

    /// 一次性把资料库文件读进内存缓存，避免每条消息各查一次数据库
    private func ensureFileCache() {
        guard !fileCacheLoaded else { return }
        let descriptor = FetchDescriptor<StoredFile>()
        let all = (try? modelContext.fetch(descriptor)) ?? []
        fileCache = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        fileCacheLoaded = true
    }

    private func invalidateFileCache() {
        fileCacheLoaded = false
        fileCache = [:]
    }

    private func storedFile(id: String) -> StoredFile? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        ensureFileCache()
        return fileCache[uuid]
    }

    // MARK: - 发送

    /// 草稿态 -> 真正会话；已有会话直接返回
    @discardableResult
    private func ensureConversation() -> Conversation {
        if let conversation { return conversation }
        let created = Conversation(expertId: expert.id, title: expert.name)
        modelContext.insert(created)
        try? modelContext.save()
        conversation = created
        onConversationCreated?(created)
        return created
    }

    func send() {
        if BudgetTracker.isExceeded() {
            errorMessage = String(format: "已达本月预算上限（¥%.0f，本月已用约 ¥%.2f）。侧栏连点 Boss AI 进入设置可调整。",
                                  BudgetTracker.limit(), BudgetTracker.spent())
            return
        }
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pendingAttachments
        guard (!text.isEmpty || !attachments.isEmpty), !isStreaming else { return }

        inputText = ""
        errorMessage = nil

        // 草稿态在这里才真正建会话：点专家不会凭空产生对话记录
        let conv = ensureConversation()
        // 注意：必须先判断，再插入消息（插入后 messages 里就有本条了）
        let isFirstUserMessage = conv.messages.filter { $0.role == "user" }.isEmpty

        let userMessage = Message(role: "user", text: text)
        userMessage.attachmentIds = attachments.map { $0.id.uuidString }.joined(separator: ",")
        userMessage.conversation = conv
        modelContext.insert(userMessage)

        // 第一条消息自动作为会话标题
        if isFirstUserMessage, !text.isEmpty {
            conv.title = String(text.prefix(20))
        }
        conv.updatedAt = Date()
        try? modelContext.save()

        // 草稿期上传的附件补记到新会话名下
        for file in attachments where file.sourceConversationId.isEmpty {
            file.sourceConversationId = conv.id.uuidString
        }

        pendingAttachments = []

        // 先创建空的 assistant 消息，流式文本只写内存、结束后才落库
        let assistantMessage = Message(role: "assistant", text: "")
        assistantMessage.conversation = conv
        modelContext.insert(assistantMessage)
        streamingMessageId = assistantMessage.id
        streamingText = ""
        isStreaming = true

        streamTask = Task { [self] in
            await runLoop(userText: text, attachments: attachments, conv: conv,
                          assistantMessage: assistantMessage)
        }
    }

    /// 停止当前回复
    func stop() {
        guard isStreaming else { return }
        streamTask?.cancel()
        streamTask = nil
    }

    deinit {
        streamTask?.cancel()
    }

    func clearConversation() {
        for m in conversation?.messages ?? [] { modelContext.delete(m) }
        try? modelContext.save()
    }

    // MARK: - 工具调用主循环

    private func runLoop(userText: String, attachments: [StoredFile], conv: Conversation,
                         assistantMessage: Message) async {
        defer {
            isStreaming = false
            statusText = nil
            streamingText = ""
            streamingMessageId = nil
            streamTask = nil
        }

        var apiMessages = buildAPIMessages()
        var lastGeneratedImage: Data? = conv.messages
            .filter { $0.imageData != nil }
            .sorted { $0.createdAt < $1.createdAt }
            .last?.imageData

        do {
            var iteration = 0
            var fullText = ""
            loop: while iteration < AppConfig.maxToolIterations {
                iteration += 1
                var pendingToolCalls: [ChatService.ToolCall] = []
                var assistantText = ""

                for try await event in chatService.stream(messages: apiMessages, enableTools: true) {
                    if Task.isCancelled { break }
                    switch event {
                    case .textDelta(let delta):
                        assistantText += delta
                        // 只更新内存中的流式文本，不写库、不触发整个列表重绘
                        streamingText = fullText + assistantText
                    case .status(let s):
                        statusText = s
                    case .toolCalls(let calls, let text):
                        pendingToolCalls = calls
                        assistantText = text
                    case .finished:
                        break
                    }
                }

                fullText += assistantText
                assistantMessage.text = fullText

                if Task.isCancelled { break loop }
                if pendingToolCalls.isEmpty { break loop }

                apiMessages.append([
                    "role": "assistant",
                    "content": assistantText.isEmpty ? NSNull() : assistantText,
                    "tool_calls": pendingToolCalls.map { call in
                        [
                            "id": call.id,
                            "type": "function",
                            "function": ["name": call.name, "arguments": call.arguments],
                        ] as [String: Any]
                    },
                ] as [String: Any])

                for call in pendingToolCalls {
                    switch call.name {
                    case "generate_image":
                        statusText = "正在生成图片…"
                        let args = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any]
                        let prompt = args?["prompt"] as? String ?? userText
                        let editLast = args?["edit_last_image"] as? Bool ?? false
                        do {
                            let reference = editLast ? lastGeneratedImage : nil
                            let imageData = try await imageService.generate(prompt: prompt, reference: reference)
                            lastGeneratedImage = imageData
                            let imageMessage = Message(role: "assistant", text: "", imageData: imageData)
                            imageMessage.conversation = conv
                            modelContext.insert(imageMessage)
                            apiMessages.append([
                                "role": "tool",
                                "tool_call_id": call.id,
                                "content": "图片已生成并展示给用户。",
                            ])
                        } catch {
                            apiMessages.append([
                                "role": "tool",
                                "tool_call_id": call.id,
                                "content": "图片生成失败：\(error.localizedDescription)，请用文字回复用户并致歉。",
                            ])
                        }

                    case "create_document":
                        statusText = "正在生成文件…"
                        let args = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any]
                        let formatRaw = (args?["format"] as? String ?? "word").lowercased()
                        let filename = args?["filename"] as? String ?? "文档"
                        let title = (args?["title"] as? String) ?? filename
                        let content = args?["content"] as? String ?? ""
                        let format: DocumentFormat = {
                            switch formatRaw {
                            case "ppt", "pptx", "powerpoint", "slide": return .ppt
                            case "excel", "xlsx", "sheet", "table": return .excel
                            case "pdf": return .pdf
                            default: return .word
                            }
                        }()
                        do {
                            let data = try DocumentBuilder.build(format: format, title: title, content: content)
                            let safe = DocumentBuilder.safeFilename(filename, fallback: title)
                            let ext = format.ext
                            let finalName = safe.hasSuffix(".\(ext)") ? safe : "\(safe).\(ext)"
                            let record = try FileStore.store(data: data,
                                                            filename: finalName,
                                                            kind: .generated,
                                                            sourceConversationId: conv.id.uuidString,
                                                            textContent: content,
                                                            context: modelContext)
                            let fileMessage = Message(role: "assistant", text: "")
                            fileMessage.attachmentIds = record.id.uuidString
                            fileMessage.conversation = conv
                            modelContext.insert(fileMessage)
                            apiMessages.append([
                                "role": "tool",
                                "tool_call_id": call.id,
                                "content": "文件已生成：\(finalName)，已存入资料库并展示给用户。请简短告知用户，不要再重复正文内容。",
                            ])
                            invalidateFileCache()
                            toast = "已生成 \(finalName)"
                        } catch {
                            apiMessages.append([
                                "role": "tool",
                                "tool_call_id": call.id,
                                "content": "文件生成失败：\(error.localizedDescription)",
                            ])
                        }

                    case "web_search":
                        statusText = "正在联网搜索…"
                        let args = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any]
                        let query = (args?["query"] as? String) ?? userText
                        let hits = await WebSearchService.search(query: query, count: 6)
                        if hits.isEmpty {
                            apiMessages.append([
                                "role": "tool",
                                "tool_call_id": call.id,
                                "content": "搜索无结果或网络不可用。请基于已有知识回答，并明确告知用户该信息未能联网核实。",
                            ])
                        } else {
                            // 抓取前 N 篇正文，给模型更完整的信息
                            var pages: [(title: String, url: String, text: String)] = []
                            let fetchCount = min(AppConfig.searchPageFetchCount, hits.count)
                            if fetchCount > 0 {
                                statusText = "正在阅读网页…"
                                for hit in hits.prefix(fetchCount) {
                                    let text = await WebSearchService.fetchPageText(url: hit.url, limit: 3500)
                                    if !text.isEmpty {
                                        pages.append((hit.title, hit.url, text))
                                    }
                                }
                            }
                            lastSearchContext = WebSearchService.format(hits: hits, pages: pages)
                            apiMessages.append([
                                "role": "tool",
                                "tool_call_id": call.id,
                                "content": lastSearchContext,
                            ])
                        }

                    case "$web_search":
                        // 厂商服务端搜索（开启增强时出现）：回显参数即可继续
                        apiMessages.append([
                            "role": "tool",
                            "tool_call_id": call.id,
                            "content": call.arguments,
                        ])

                    default:
                        apiMessages.append([
                            "role": "tool",
                            "tool_call_id": call.id,
                            "content": "未知工具",
                        ])
                    }
                    statusText = nil
                }
            }
        } catch {
            let isCancel = error is CancellationError
                || (error as? URLError)?.code == .cancelled
            if !isCancel {
                errorMessage = error.localizedDescription
                if assistantMessage.text.isEmpty && assistantMessage.imageData == nil {
                    modelContext.delete(assistantMessage)
                }
            }
        }

        // 用户主动停止：无论走 break 还是抛 CancellationError，统一在这里收尾
        if Task.isCancelled {
            if assistantMessage.text.isEmpty && assistantMessage.imageData == nil {
                modelContext.delete(assistantMessage)
            } else if !assistantMessage.text.isEmpty {
                assistantMessage.text += "\n\n*（已停止生成）*"
            }
        }

        conv.updatedAt = Date()
        try? modelContext.save()

        // 附上信息来源，方便核对
        if let context = lastSearchContext, !assistantMessage.text.isEmpty {
            let sources = context.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("http") }
            if !sources.isEmpty {
                let list = sources.prefix(5).map { "· \($0)" }.joined(separator: "\n")
                assistantMessage.text += "\n\n---\n信息来源（联网检索）：\n\(list)"
            }
        }
        lastSearchContext = nil
        try? modelContext.save()

        let promptTokens = BudgetTracker.estimateTokens(userText + attachments.map(\.textContent).joined())
        let completionTokens = BudgetTracker.estimateTokens(
            sortedMessages.suffix(2).map { $0.text }.joined()
        )
        BudgetTracker.add(promptTokens: promptTokens, completionTokens: completionTokens,
                          providerId: ProviderCatalog.currentChat().id)

        roundsSinceExtraction += 1
        if roundsSinceExtraction >= 3 {
            roundsSinceExtraction = 0
            let recent = sortedMessages.suffix(6)
                .map { "\($0.role == "user" ? "用户" : "AI"): \($0.text)" }
                .joined(separator: "\n")
            let service = memoryService
            let context = modelContext
            Task { await service.extract(from: recent, context: context) }
        }
    }

    // MARK: - 上下文组装：专家 prompt + 身份 + 记忆 + 附件正文

    private func buildAPIMessages() -> [[String: Any]] {
        let identity = UserIdentity.load()
        let memories = memoryService.injectionFragment(context: modelContext)
        let system = expert.systemPrompt + identity.promptFragment + identity.replyStyle.prompt + memories

        var messages: [[String: Any]] = [["role": "system", "content": system]]
        var injectedBudget = 30000

        for m in sortedMessages.suffix(40) {
            if m.imageData != nil {
                messages.append(["role": "assistant", "content": "[已向用户展示生成的图片]"])
                continue
            }

            let attached = files(for: m)
            if attached.isEmpty {
                if !m.text.isEmpty {
                    messages.append(["role": m.role, "content": m.text])
                }
                continue
            }

            // 图片附件 → 多模态；其他附件 → 抽取文本
            var textParts: [String] = []
            if !m.text.isEmpty { textParts.append(m.text) }
            var imageURLs: [String] = []

            for file in attached {
                if file.isImage, let data = try? Data(contentsOf: FileStore.url(for: file)) {
                    imageURLs.append("data:image/jpeg;base64,\(data.base64EncodedString())")
                } else {
                    let body = file.contextText()
                    guard !body.isEmpty, injectedBudget > 0 else { continue }
                    let clipped = String(body.prefix(min(body.count, injectedBudget)))
                    injectedBudget -= clipped.count
                    textParts.append("【用户上传的文件：\(file.name)】\n\(clipped)")
                }
            }

            if imageURLs.isEmpty {
                messages.append(["role": m.role, "content": textParts.joined(separator: "\n\n")])
            } else {
                var content: [[String: Any]] = []
                content.append(["type": "text", "text": textParts.joined(separator: "\n\n")])
                for url in imageURLs {
                    content.append(["type": "image_url", "image_url": ["url": url]])
                }
                messages.append(["role": m.role, "content": content])
            }
        }
        return messages
    }

    // MARK: - 导出

    /// 把当前会话导出为文件并存入资料库，返回提示文案
    func exportConversation(format: DocumentFormat) -> String {
        let title = (conversation?.title.isEmpty ?? true) ? expert.name : (conversation?.title ?? expert.name)
        var lines: [String] = []
        for message in sortedMessages {
            guard !message.text.isEmpty else { continue }
            lines.append(message.role == "user" ? "**我：**\(message.text)" : message.text)
            lines.append("")
        }
        guard !lines.isEmpty else { return "当前对话没有可导出的内容" }
        let markdown = "# \(title)\n\n" + lines.joined(separator: "\n")
        do {
            let data = try DocumentBuilder.build(format: format, title: title, content: markdown)
            let name = DocumentBuilder.safeFilename(title, fallback: "对话导出")
            let file = "\(name)-\(Self.timestamp()).\(format.ext)"
            _ = try FileStore.store(data: data, filename: file, kind: .generated,
                                    sourceConversationId: conversation?.id.uuidString ?? "",
                                    textContent: markdown, context: modelContext)
            invalidateFileCache()
            return "已导出 \(file)，可在资料库查看"
        } catch {
            return "导出失败：\(error.localizedDescription)"
        }
    }

    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }
}

extension UIImage {
    /// 压缩到适合上传给模型的尺寸（长边 1600，JPEG 0.8）
    func ocrFriendlyJPEG() -> Data? {
        let maxSide: CGFloat = 1600
        let longSide = max(size.width, size.height)
        var targetSize = size
        if longSide > maxSide {
            let scale = maxSide / longSide
            targetSize = CGSize(width: size.width * scale, height: size.height * scale)
        }
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let scaled = renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return scaled.jpegData(compressionQuality: 0.8)
    }
}
