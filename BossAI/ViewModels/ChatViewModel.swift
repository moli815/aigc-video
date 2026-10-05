import Foundation
import SwiftData
import UIKit

/// 一次 web_search 的执行结果（要在并行 Task 之间传递，需 Sendable）
private struct SearchOutcome: Sendable {
    /// 在本轮工具调用中的顺序，回填时按此排序
    let order: Int
    let callId: String
    let hits: [SearchHit]
    let pages: [(title: String, url: String, text: String)]
    let emptyMessage: String?
}

/// 单个会话的对话逻辑：
/// 流式回复、联网搜索、generate_image 生图、create_document 生成文档、附件注入、记忆抽取
@MainActor
final class ChatViewModel: ObservableObject {
    @Published var inputText = ""
    @Published var isStreaming = false
    @Published var statusText: String?
    @Published var errorMessage: String?
    @Published private(set) var failedUserMessageID: UUID?
    private var failedAssistantMessageID: UUID?
    var canRetryReply: Bool { failedUserMessageID != nil && !isStreaming && !isImporting }
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

    private var chatService: ChatService { injectedChatService ?? ChatService(profile: ProviderCatalog.currentChat(), apiKeyProvider: chatKey) }
    private var imageService: ImageService { ImageService(profile: ProviderCatalog.currentImage(), apiKeyProvider: imageKey) }
    private var memoryService: MemoryService { MemoryService(profile: ProviderCatalog.currentChat(), apiKeyProvider: chatKey) }
    private let injectedChatService: ChatService?
    private let chatKey: () -> String?
    private let imageKey: () -> String?
    private let modelContext: ModelContext
    private var streamTask: Task<Void, Never>?

    private var fileCache: [UUID: StoredFile] = [:]
    private var fileCacheLoaded = false
    private var filesObserver: NSObjectProtocol?
    /// 本轮联网搜索命中的来源链接，去重后作为「信息来源」附在回答末尾
    private var citations = CitationRegistry()

    init(conversation: Conversation?,
         expert: Expert,
         modelContext: ModelContext,
         chatKey: @escaping () -> String?,
         imageKey: @escaping () -> String?,
         chatService: ChatService? = nil) {
        self.conversation = conversation
        self.expert = expert
        self.modelContext = modelContext
        self.chatKey = chatKey
        self.imageKey = imageKey
        self.injectedChatService = chatService
        filesObserver = NotificationCenter.default.addObserver(forName: .bossAIFilesChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.invalidateFileCache() }
        }
    }

    private var orderedMessageCache: [Message] = []
    private var orderedMessageCount = -1
    var sortedMessages: [Message] {
        let messages = conversation?.messages ?? []
        if orderedMessageCount != messages.count {
            orderedMessageCache = messages.sorted { $0.createdAt < $1.createdAt }
            orderedMessageCount = messages.count
        }
        return orderedMessageCache
    }

    // MARK: - 附件

    /// 从文件选择器导入（支持多选、多种类型）
    func attach(urls: [URL]) {
        guard !urls.isEmpty, !isImporting else { return }
        isImporting = true
        Task {
            var added: [StoredFile] = []
            for url in urls {
                let (data, text) = await FileImportService.load(url: url)
                guard !data.isEmpty else { errorMessage = "文件读取失败或超过32MB：" + url.lastPathComponent; continue }
                let name = url.lastPathComponent
                do {
                let record = try FileStore.store(data: data,
                                                     filename: name,
                                                     kind: .uploaded,
                                                     sourceConversationId: conversation?.id.uuidString ?? "",
                                                     textContent: text,
                                                     context: modelContext)
                    added.append(record)
                } catch { errorMessage = "附件保存失败：" + error.localizedDescription }
            }
            pendingAttachments.append(contentsOf: added)
            invalidateFileCache()
            isImporting = false
        }
    }

    /// 从相册或相机导入图片
    func attach(images: [UIImage]) {
        guard !images.isEmpty, !isImporting else { return }
        isImporting = true
        Task {
            var added: [StoredFile] = []
            for (index, image) in images.enumerated() {
                guard let data = image.ocrFriendlyJPEG() else { continue }
                let name = "照片_\(Self.timestamp())_\(index + 1).jpg"
                let text = await FileImportService.ocr(imageData: data)
                do {
                let record = try FileStore.store(data: data,
                                                     filename: name,
                                                     kind: .uploaded,
                                                     sourceConversationId: conversation?.id.uuidString ?? "",
                                                     textContent: text,
                                                     context: modelContext)
                    added.append(record)
                } catch { errorMessage = "附件保存失败：" + error.localizedDescription }
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
    private func ensureConversation() throws -> Conversation {
        if let conversation { return conversation }
        let created = Conversation(expertId: expert.id, title: expert.name)
        modelContext.insert(created)
        do { try modelContext.save() } catch { modelContext.delete(created); throw error }
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
        guard (!text.isEmpty || !attachments.isEmpty), !isStreaming, !isImporting else { return }

        errorMessage = nil
        failedUserMessageID = nil
        failedAssistantMessageID = nil

        // 草稿态在这里才真正建会话：点专家不会凭空产生对话记录
        let conv: Conversation
        do { conv = try ensureConversation() } catch { errorMessage = "会话保存失败：" + error.localizedDescription; return }
        inputText = ""
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

    /// Regenerate the failed reply using the existing user message, not a new send.
    func retryReply() {
        guard canRetryReply, let conv = conversation, let id = failedUserMessageID,
              let user = conv.messages.first(where: { $0.id == id && $0.role == "user" }),
              sortedMessages.last(where: { $0.role == "user" })?.id == id else { return }
        guard !BudgetTracker.isExceeded() else { errorMessage = "已达到本月预算上限，无法重新生成。"; return }
        if let failedID = failedAssistantMessageID,
           let failed = conv.messages.first(where: { $0.id == failedID }) { modelContext.delete(failed) }
        let assistant = Message(role: "assistant", text: "")
        assistant.conversation = conv
        modelContext.insert(assistant)
        do { try modelContext.save() } catch {
            modelContext.rollback()
            errorMessage = "重试准备失败：" + error.localizedDescription
            return
        }
        orderedMessageCount = -1
        let attachments = user.attachmentIds.split(separator: ",").compactMap { storedFile(id: String($0)) }
        errorMessage = nil
        failedUserMessageID = nil
        failedAssistantMessageID = nil
        streamingMessageId = assistant.id
        streamingText = ""
        isStreaming = true
        streamTask = Task { [self] in
            await runLoop(userText: user.text, attachments: attachments, conv: conv, assistantMessage: assistant)
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
        if let filesObserver { NotificationCenter.default.removeObserver(filesObserver) }
    }

    func clearConversation() {
        failedUserMessageID = nil
        failedAssistantMessageID = nil
        orderedMessageCount = -1
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

        let turnSpan = PerformanceTrace.begin("ChatTurn")
        defer { PerformanceTrace.end("ChatTurn", turnSpan) }
        guard let capability = try? ExpertCapabilityCatalog.profile(expert.id) else {
            errorMessage = "专家技能配置未加载，无法执行工具。"
            modelContext.delete(assistantMessage)
            try? modelContext.save()
            return
        }
        citations = CitationRegistry()
        var apiMessages = buildAPIMessages()
        var lastGeneratedImage: Data? = conv.messages
            .filter { $0.imageData != nil }
            .sorted { $0.createdAt < $1.createdAt }
            .last?.imageData

        // B01：服务端返回的真实 token 数（拿不到就回退估算）
        var requestPromptTokens = 0
        var requestCompletionTokens = 0
        var requestPromptEstimate = 0
        var accounted = true

        var fullText = ""
        var assistantText = ""
        var currentTextCommitted = true
        do {
            var iteration = 0
            var executedToolIDs = Set<String>()
            var exhausted = true
            loop: while iteration < AppConfig.maxToolIterations {
                iteration += 1
                var pendingToolCalls: [ChatService.ToolCall] = []
                assistantText = ""
                currentTextCommitted = false
                requestPromptTokens = 0
                requestCompletionTokens = 0
                requestPromptEstimate = BudgetTracker.estimateTokens(String(describing: apiMessages))
                accounted = false
                var lastPublishTime = ProcessInfo.processInfo.systemUptime

                for try await event in chatService.stream(messages: apiMessages, enableTools: true, expertID: expert.id) {
                    if Task.isCancelled { break }
                    switch event {
                    case .textDelta(let delta):
                        assistantText += delta
                        // 合并发布内存缓冲，不逐delta写库；实际视图重算范围需Instruments确认。
                        let now = ProcessInfo.processInfo.systemUptime
                        if streamingText.isEmpty || now - lastPublishTime >= 0.08 {
                            streamingText = fullText + assistantText
                            lastPublishTime = now
                        }
                    case .status(let s):
                        statusText = s
                    case .toolCalls(let calls, let text):
                        pendingToolCalls = calls
                        assistantText = text
                    case .usage(let p, let c):
                        requestPromptTokens = p
                        requestCompletionTokens = c
                    case .finished:
                        break
                    }
                }

                fullText += assistantText
                currentTextCommitted = true
                BudgetTracker.add(promptTokens: requestPromptTokens > 0 ? requestPromptTokens : requestPromptEstimate,
                                  completionTokens: requestCompletionTokens > 0 ? requestCompletionTokens : BudgetTracker.estimateTokens(assistantText),
                                  providerId: ProviderCatalog.currentChat().id)
                accounted = true
                streamingText = fullText
                assistantMessage.text = fullText

                if Task.isCancelled { break loop }
                if pendingToolCalls.isEmpty { exhausted = false; break loop }

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

                // 本轮所有联网搜索并行执行。
                // 收集类任务（如「6 款旗舰机参数」）会一次发多个 web_search，
                // 串行等待会让耗时翻倍，模型就会偷懒退化成"只搜一次 + 靠记忆补齐"。
                let searchOrders = pendingToolCalls.indices.filter { pendingToolCalls[$0].name == "web_search" && capability.allowSearch }
                var searchOutcomes: [SearchOutcome] = []
                if !searchOrders.isEmpty {
                    statusText = "正在联网搜索…"
                    searchOutcomes = await withTaskGroup(of: SearchOutcome.self) { group in
                        for order in searchOrders.prefix(4) {
                            let call = pendingToolCalls[order]
                            group.addTask { await Self.runWebSearch(call: call, order: order, fallback: userText) }
                        }
                        var collected: [SearchOutcome] = []
                        for await outcome in group { collected.append(outcome) }
                        return collected.sorted { $0.order < $1.order }
                    }
                }
                var searchCursor = 0

                for call in pendingToolCalls {
                    try Task.checkCancellation()
                    guard executedToolIDs.insert(call.id).inserted else {
                        apiMessages.append(["role": "tool", "tool_call_id": call.id, "content": "重复工具ID已拒绝，避免重复扣费或写入文件。"]); continue
                    }
                    if BudgetTracker.isExceeded() { throw ExpertSkillError.denied("本月预算已达上限，停止继续请求") }
                    guard ExpertSkillRuntime.permits(call.name, profile: capability) else {
                        apiMessages.append(["role": "tool", "tool_call_id": call.id,
                                            "content": "当前专家禁止该工具：\(call.name)"])
                        continue
                    }
                    switch call.name {
                    case "search_library":
                        do {
                            let args = try JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: Any]
                            let result = try ExpertKnowledgeService.toolResult(args?["query"] as? String ?? userText, context: modelContext)
                            apiMessages.append(["role": "tool", "tool_call_id": call.id, "content": result])
                        } catch { apiMessages.append(["role": "tool", "tool_call_id": call.id, "content": error.localizedDescription]) }
                    case "expert_skill":
                        do {
                            let span = PerformanceTrace.begin("ExpertSkill")
                            defer { PerformanceTrace.end("ExpertSkill", span) }
                            let result = try ExpertSkillRuntime.execute(arguments: call.arguments, expertID: expert.id)
                            apiMessages.append(["role": "tool", "tool_call_id": call.id, "content": result])
                        } catch {
                            apiMessages.append(["role": "tool", "tool_call_id": call.id,
                                                "content": error.localizedDescription])
                        }
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
                            BudgetTracker.addImageGeneration()   // B01：生图计入预算
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
                        guard ["word", "docx", "ppt", "pptx", "powerpoint", "slide", "excel", "xlsx", "sheet", "table", "pdf"].contains(formatRaw) else {
                            apiMessages.append(["role": "tool", "tool_call_id": call.id, "content": "不支持该文档格式；仅支持Word/PPT/Excel/PDF。"])
                            continue
                        }
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
                            let validation = try ExpertSkillRuntime.validateDocument(content, format: format.rawValue, profile: capability)
                            guard validation.structurePassed else {
                                throw ExpertSkillError.invalidInput("交付结构未通过；缺少：\(validation.missingSections.joined(separator: "、"))；\(validation.warnings.joined(separator: "；"))")
                            }
                            let span = PerformanceTrace.begin("DocumentBuild")
                            let data: Data
                            do { data = try DocumentBuilder.build(format: format, title: title, content: content) }
                            catch { PerformanceTrace.end("DocumentBuild", span); throw error }
                            PerformanceTrace.end("DocumentBuild", span)
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
                            // Local document packaging has no additional model API fee.
                        } catch {
                            apiMessages.append([
                                "role": "tool",
                                "tool_call_id": call.id,
                                "content": "文件生成失败：\(error.localizedDescription)",
                            ])
                        }

                    case "web_search":
                        // 结果已在上面并行取回，这里按调用顺序回填给模型
                        if searchCursor >= searchOutcomes.count {
                            apiMessages.append(["role": "tool", "tool_call_id": call.id, "content": "本轮最多并行检索4个主题，请分轮检索剩余主题。"])
                        }
                        if searchCursor < searchOutcomes.count {
                            let outcome = searchOutcomes[searchCursor]
                            searchCursor += 1
                            apiMessages.append([
                                "role": "tool",
                                "tool_call_id": outcome.callId,
                                "content": outcome.emptyMessage ?? WebSearchService.format(hits: outcome.hits, pages: outcome.pages, sourceIDs: outcome.hits.map { citations.register($0.url) }),
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
            if exhausted && !Task.isCancelled {
                errorMessage = "已达到工具执行上限；当前结果尚未完成，请缩小任务范围后继续。"
            }
        } catch {
            if !accounted && (!assistantText.isEmpty || requestPromptTokens > 0 || requestCompletionTokens > 0) {
                BudgetTracker.add(promptTokens: requestPromptTokens > 0 ? requestPromptTokens : requestPromptEstimate,
                                  completionTokens: requestCompletionTokens > 0 ? requestCompletionTokens : BudgetTracker.estimateTokens(assistantText),
                                  providerId: ProviderCatalog.currentChat().id)
            }
            assistantMessage.text = fullText + (currentTextCommitted ? "" : assistantText)
            let isCancel = error is CancellationError
                || (error as? URLError)?.code == .cancelled
            if !isCancel {
                failedUserMessageID = sortedMessages.last(where: { $0.role == "user" })?.id
                failedAssistantMessageID = assistantMessage.id
                let received = !assistantMessage.text.isEmpty || assistantMessage.imageData != nil
                errorMessage = (received ? "回复中断，已保留部分内容。重新生成将替换这次回复。\n" : "未收到有效回复，可重新生成。\n") + error.localizedDescription
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

        // 附上信息来源，方便核对。带编号，与回答里的「（来源 N）」对应，可逐条追溯。
        if !citations.urls.isEmpty, !assistantMessage.text.isEmpty {
            assistantMessage.text += "\n\n---\n信息来源（编号在整轮对话中保持一致）：\n" + citations.markdown
        }
        citations = CitationRegistry()
        try? modelContext.save()

        // R01 修复：抽取计数持久化到 UserDefaults，VM 重建后不归零
        // （旧版 roundsSinceExtraction 是实例属性，切会话重建 VM 就归零，每 3 轮抽取名存实亡）
        guard !Task.isCancelled, errorMessage == nil else { return }
        let memoryRoundKey = "bossai.memory_rounds." + conv.id.uuidString
        var rounds = UserDefaults.standard.integer(forKey: memoryRoundKey) + 1
        if rounds >= 3 {
            UserDefaults.standard.set(0, forKey: memoryRoundKey)
            let recent = sortedMessages.suffix(6)
                .filter { $0.role == "user" }
                .map { "用户：\($0.text)" }
                .joined(separator: "\n")
            let service = memoryService
            let context = modelContext
            let source = conv.title
            Task { await service.extract(from: recent, source: source, context: context) }
        } else {
            UserDefaults.standard.set(rounds, forKey: memoryRoundKey)
        }
    }

    // MARK: - 联网搜索执行（可并行）

    /// 执行一次 web_search：搜索 → 并行抓正文 → 格式化成给模型看的上下文
    ///
    /// 并行抓取正文是关键：参数类信息分散在不同站点，
    /// 串行抓 3 篇要等 3 个 RTT，模型容易因为"太慢"而减少搜索次数。
    /// nonisolated：必须脱离 MainActor，否则多个搜索会被排到主线程上排队，并行失效
    nonisolated private static func runWebSearch(call: ChatService.ToolCall, order: Int, fallback: String) async -> SearchOutcome {
        let span = PerformanceTrace.begin("WebSearch")
        defer { PerformanceTrace.end("WebSearch", span) }
        let args = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any]
        let query = (args?["query"] as? String) ?? fallback
        let recency = (args?["recency"] as? String).flatMap(SearchRecency.init(rawValue:)) ?? SearchRecency.inferred(from: query)
        let hits = await WebSearchService.search(query: query, count: 6, recency: recency)

        if hits.isEmpty {
            return SearchOutcome(
                order: order,
                callId: call.id,
                hits: [], pages: [], emptyMessage: """
                搜索「\(query)」无结果或网络不可用。
                请在最终答案里把对应字段明确标注为「未核实」，\
                不要用记忆中的数字、其他型号的数字或拼凑的数字填空 —— 留空不算错，填错才算错。
                """
            )
        }

        // 并行抓取正文，多给 3 个候选。
        // 部分站点会反爬返回空，只抓前 N 个会因为个别失败而白白少拿一份资料 —— 这里凑够为止。
        let fetchCount = min(AppConfig.searchPageFetchCount, hits.count)
        guard fetchCount > 0 else {
            return SearchOutcome(order: order, callId: call.id,
                                 hits: hits, pages: [], emptyMessage: nil)
        }
        let candidates = Array(hits.prefix(fetchCount + 3))
        let raw = await withTaskGroup(of: (Int, String, String, String).self) { group in
            for (i, hit) in candidates.enumerated() {
                group.addTask {
                    (i, hit.title, hit.url, await WebSearchService.fetchPageText(url: hit.url, limit: 3500))
                }
            }
            var collected: [(Int, String, String, String)] = []
            for await item in group {
                collected.append(item)
                if collected.filter({ !$0.3.isEmpty }).count >= fetchCount { group.cancelAll(); break }
            }
            return collected.sorted { $0.0 < $1.0 }
        }

        let pages = Array(raw.filter { !$0.3.isEmpty }
            .map { (title: $0.1, url: $0.2, text: $0.3) }
            .prefix(fetchCount))
        return SearchOutcome(order: order,
                             callId: call.id,
                             hits: hits, pages: pages, emptyMessage: nil)
    }

    // MARK: - 上下文组装：专家 prompt + 身份 + 记忆 + 附件正文

    private func buildAPIMessages() -> [[String: Any]] {
        let span = PerformanceTrace.begin("ContextBuild")
        defer { PerformanceTrace.end("ContextBuild", span) }
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
                if file.isImage {
                    textParts.append("【图片附件OCR，可能有识别误差：\(file.name)】\n" + file.contextText(limit: 3000))
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
        var remaining = 48000
        var selected: [[String: Any]] = []
        for message in messages.dropFirst().reversed() {
            guard let content = message["content"] as? String else { continue }
            guard remaining > 0 else { break }
            let clipped = String(content.prefix(remaining))
            remaining -= clipped.count
            selected.append(["role": message["role"] ?? "user", "content": clipped])
        }
        return [messages[0]] + selected.reversed()
    }

    // MARK: - 导出

    /// 把当前会话导出为文件并存入资料库，返回提示文案
    func exportConversation(format: DocumentFormat) -> String {
        let title = (conversation?.title.isEmpty ?? true) ? expert.name : (conversation?.title ?? expert.name)
        var lines: [String] = []
        for message in sortedMessages {
            if message.imageData != nil { lines.append("[此消息包含图片，文字导出未嵌入图片]") }
            for file in files(for: message) { lines.append("附件：" + file.name) }
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
