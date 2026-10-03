import Foundation
import SwiftData

/// 单个对话框（普通对话或某个专家）的会话逻辑：
/// 流式回复、联网搜索状态、generate_image 工具回路、记忆抽取。
@MainActor
final class ChatViewModel: ObservableObject {
    @Published var inputText = ""
    @Published var isStreaming = false
    @Published var statusText: String?      // "正在联网搜索…" / "正在生成图片…"
    @Published var errorMessage: String?

    let conversation: Conversation
    let expert: Expert

    private let chatService: ChatService
    private let imageService: ImageService
    private let memoryService: MemoryService
    private let modelContext: ModelContext

    /// 距上次记忆抽取的轮数
    private var roundsSinceExtraction = 0

    init(conversation: Conversation,
         expert: Expert,
         modelContext: ModelContext,
         chatKey: @escaping () -> String?,
         imageKey: @escaping () -> String?) {
        self.conversation = conversation
        self.expert = expert
        self.modelContext = modelContext
        let chatProfile = ProviderCatalog.currentChat()
        let imageProfile = ProviderCatalog.currentImage()
        self.chatService = ChatService(profile: chatProfile, apiKeyProvider: chatKey)
        self.imageService = ImageService(profile: imageProfile, apiKeyProvider: imageKey)
        self.memoryService = MemoryService(profile: chatProfile, apiKeyProvider: chatKey)
    }

    var sortedMessages: [Message] {
        conversation.messages.sorted { $0.createdAt < $1.createdAt }
    }

    func send() {
        // 月度预算硬闸
        if BudgetTracker.isExceeded() {
            errorMessage = String(format: "已达本月预算上限（¥%.0f，本月已用约 ¥%.2f）。长按侧栏 Boss AI 图标进入设置可调整预算。", BudgetTracker.limit(), BudgetTracker.spent())
            return
        }
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        inputText = ""
        errorMessage = nil

        let userMessage = Message(role: "user", text: text)
        userMessage.conversation = conversation
        modelContext.insert(userMessage)
        try? modelContext.save()

        Task { await runLoop(userText: text) }
    }

    func clearConversation() {
        for m in conversation.messages { modelContext.delete(m) }
        try? modelContext.save()
    }

    // MARK: - 工具调用主循环

    private func runLoop(userText: String) async {
        isStreaming = true
        defer { isStreaming = false; statusText = nil }

        let assistantMessage = Message(role: "assistant", text: "")
        assistantMessage.conversation = conversation
        modelContext.insert(assistantMessage)

        var apiMessages = buildAPIMessages()
        var lastGeneratedImage: Data? = conversation.messages
            .filter { $0.imageData != nil }
            .sorted { $0.createdAt < $1.createdAt }
            .last?.imageData

        do {
            var iteration = 0
            loop: while iteration < AppConfig.maxToolIterations {
                iteration += 1
                var pendingToolCalls: [ChatService.ToolCall] = []
                var assistantText = ""

                for try await event in chatService.stream(messages: apiMessages, enableTools: true) {
                    switch event {
                    case .textDelta(let delta):
                        assistantText += delta
                        assistantMessage.text += delta
                    case .status(let s):
                        statusText = s
                    case .toolCalls(let calls, let text):
                        pendingToolCalls = calls
                        assistantText = text
                    case .finished:
                        break
                    }
                }

                if pendingToolCalls.isEmpty { break loop }

                // 把 assistant 的 tool_calls 追加进上下文
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
                    if call.name == "generate_image" {
                        statusText = "正在生成图片…"
                        let args = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any]
                        let prompt = args?["prompt"] as? String ?? userText
                        let editLast = args?["edit_last_image"] as? Bool ?? false
                        do {
                            let reference = editLast ? lastGeneratedImage : nil
                            let imageData = try await imageService.generate(prompt: prompt, reference: reference)
                            lastGeneratedImage = imageData
                            let imageMessage = Message(role: "assistant", text: "", imageData: imageData)
                            imageMessage.conversation = conversation
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
                        statusText = nil
                    } else if call.name == "$web_search" {
                        // Kimi 内置搜索由服务端执行，回显参数即可继续
                        apiMessages.append([
                            "role": "tool",
                            "tool_call_id": call.id,
                            "content": call.arguments,
                        ])
                        statusText = nil
                    } else {
                        apiMessages.append([
                            "role": "tool",
                            "tool_call_id": call.id,
                            "content": "未知工具",
                        ])
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            if assistantMessage.text.isEmpty && assistantMessage.imageData == nil {
                modelContext.delete(assistantMessage)
            }
        }

        try? modelContext.save()

        // 记账：预算追踪（按字符数粗估 token）
        let promptTokens = BudgetTracker.estimateTokens(userText)
        let completionTokens = BudgetTracker.estimateTokens(
            sortedMessages.suffix(2).map { $0.text }.joined()
        )
        BudgetTracker.add(promptTokens: promptTokens, completionTokens: completionTokens,
                          providerId: ProviderCatalog.currentChat().id)

        // 后台记忆抽取（每 3 轮一次，不阻塞 UI）
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

    // MARK: - 上下文组装：专家 prompt + 身份 + 记忆

    private func buildAPIMessages() -> [[String: Any]] {
        let identity = UserIdentity.load().promptFragment
        let memories = memoryService.injectionFragment(context: modelContext)
        let system = expert.systemPrompt + identity + memories

        var messages: [[String: Any]] = [["role": "system", "content": system]]
        for m in sortedMessages.suffix(40) {
            if m.imageData != nil {
                // 图片消息对模型不可见（文本模型），用占位文本保持上下文连贯
                messages.append(["role": "assistant", "content": "[已向用户展示生成的图片]"])
            } else if !m.text.isEmpty {
                messages.append(["role": m.role, "content": m.text])
            }
        }
        return messages
    }
}
