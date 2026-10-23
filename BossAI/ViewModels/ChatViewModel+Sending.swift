import Foundation
import SwiftData

// ============================================================================
// 文件职责：ChatViewModel 的会话发送模块（God File 拆分 P0-46）。
// 从 ChatViewModel.swift 拆出：ensureConversation / send / retry / stop /
//   regenerate / followUp / 检索规划 / 追问建议 / clearConversation。
// 说明：纯移动，逻辑未改；跨文件访问的成员已在主文件改为 internal。
// ============================================================================

extension ChatViewModel {

    // MARK: - 发送

    /// 草稿态 -> 真正会话；已有会话直接返回
    @discardableResult
    func ensureConversation() throws -> Conversation {
        if let conversation { return conversation }
        let created = Conversation(expertId: expert.id, title: expert.name)
        modelContext.insert(created)
        do { try modelContext.save() } catch { modelContext.delete(created); throw error }
        conversation = created
        onConversationCreated?(created)
        return created
    }

    /// 发送用户消息的主入口：额度检查 → 建会话（草稿态落库）→ 插入 user/assistant
    /// 消息 → 启动流式任务。额度超限/正在流式/正在导入时直接返回并给出提示。
    func send() {
        if BudgetTracker.chatExceeded {
            errorMessage = String(format: "本月对话额度已用完（上限 ¥%.0f，已用约 ¥%.2f）。侧栏连点中防AI标题进入设置可调整；生图额度不受影响。",
                                  BudgetTracker.chatLimit(), BudgetTracker.chatSpent())
            return
        }
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pendingAttachments
        guard (!text.isEmpty || !attachments.isEmpty), !isStreaming, !isImporting else { return }

        errorMessage = nil
        partialSuccessMessage = nil
        failedUserMessageID = nil
        failedAssistantMessageID = nil
        autoRetryCount = 0   // P0-60/P0-64 新一轮消息重置自动重试计数
        isReasoning = false   // P0-68 重置思考状态
        suggestedFollowUps = []

        // 草稿态在这里才真正建会话：点专家不会凭空产生对话记录
        let conv: Conversation
        do { conv = try ensureConversation() } catch { errorMessage = "会话保存失败：" + error.localizedDescription; return }
        inputText = ""
        // 注意：必须先判断，再插入消息（插入后 messages 里就有本条了）
        let isFirstUserMessage = conv.messages.filter { $0.role == "user" }.isEmpty

        let userMessage = Message(role: "user", text: text)
        userMessage.attachmentIds = attachments.map { $0.id.uuidString }.joined(separator: ",")
        userMessage.conversation = conv
        userMessage.conversationID = conv.id
        modelContext.insert(userMessage)

        // 第一条消息自动作为会话标题
        let previousTitle = conv.title
        if isFirstUserMessage, !text.isEmpty {
            conv.title = String(text.prefix(20))
        }
        conv.updatedAt = Date()
        // 10-22 关键写入显式处理：保存失败必须回滚并保留输入，绝不「以为存了」却继续发起请求
        do {
            try modelContext.save()
        } catch {
            modelContext.delete(userMessage)
            conv.title = previousTitle
            conv.updatedAt = Date()
            inputText = text
            pendingAttachments = attachments
            errorMessage = "消息保存失败（\(error.localizedDescription)）。你的输入已保留，请重试。"
            return
        }

        // 草稿期上传的附件补记到新会话名下
        for file in attachments where file.sourceConversationId.isEmpty {
            file.sourceConversationId = conv.id.uuidString
        }

        pendingAttachments = []

        // 先创建空的 assistant 消息，流式文本只写内存、结束后才落库
        let assistantMessage = Message(role: "assistant", text: "")
        assistantMessage.conversation = conv
        assistantMessage.conversationID = conv.id
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
        guard !BudgetTracker.chatExceeded else { errorMessage = "本月对话额度已用完，无法重新生成。"; return }
        if let failedID = failedAssistantMessageID,
           let failed = conv.messages.first(where: { $0.id == failedID }) { modelContext.delete(failed) }
        let assistant = Message(role: "assistant", text: "")
        assistant.conversation = conv
        assistant.conversationID = conv.id
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

    /// 停止当前回复：取消流式任务；收尾（保留半截内容/删除空消息）由 runLoop 统一处理
    func stop() {
        guard isStreaming else { return }
        streamTask?.cancel()
        streamTask = nil
    }

    /// 点击追问建议直接发送
    func sendFollowUp(_ text: String) {
        guard !isStreaming, !isImporting else { return }
        inputText = text
        send()
    }

    /// 是否可以重新生成最后一条回复（ChatGPT 式：成功后也允许重生成）
    var canRegenerateLast: Bool {
        !isStreaming && !isImporting
            && sortedMessages.last?.role == "assistant"
            && sortedMessages.last(where: { $0.role == "user" }) != nil
    }

    /// 重新生成最后一条回复：删除最后一条 assistant 消息，重跑最后一条用户消息
    func regenerateLastReply() {
        guard canRegenerateLast, let conv = conversation,
              let lastAssistant = sortedMessages.last, lastAssistant.role == "assistant",
              let lastUser = sortedMessages.last(where: { $0.role == "user" }) else { return }
        guard !BudgetTracker.chatExceeded else { errorMessage = "本月对话额度已用完，无法重新生成。"; return }
        modelContext.delete(lastAssistant)
        let assistant = Message(role: "assistant", text: "")
        assistant.conversation = conv
        assistant.conversationID = conv.id
        modelContext.insert(assistant)
        do { try modelContext.save() } catch {
            modelContext.rollback()
            errorMessage = "重新生成准备失败：" + error.localizedDescription
            return
        }
        orderedMessageCount = -1
        let attachments = lastUser.attachmentIds.split(separator: ",").compactMap { storedFile(id: String($0)) }
        errorMessage = nil
        failedUserMessageID = nil
        failedAssistantMessageID = nil
        suggestedFollowUps = []
        streamingMessageId = assistant.id
        streamingText = ""
        isStreaming = true
        streamTask = Task { [self] in
            await runLoop(userText: lastUser.text, attachments: attachments, conv: conv, assistantMessage: assistant)
        }
    }

    /// LLM 查询规划：意图分析 + 搜索词整理。失败/超时返回 nil，调用方回退规则 seed。
    func planSearchQueries(userText: String, seed: String) async -> SearchPlan? {
        if let injected = injectedSearchPlanner { return await injected(userText, seed) }
        guard !Task.isCancelled else { return nil }
        let profile = ProviderCatalog.currentChat()
        guard let apiKey = chatKey(), !apiKey.isEmpty else { return nil }
        let system = """
        你是联网检索的查询规划器。先做意图分析，再产出搜索执行计划。
        - intent 取值：single=单一事实/产品核实；multi=多实体收集对比（多机型/多品牌/多平台）；browse=资讯浏览；none=无需联网（纯操作指令如"做成统计图"、对已核实内容的追问、寒暄）。
        - multi：列出具体对象（最多 6 个，必须真实存在，禁止编造型号），每个对象一条查询 = 对象全名 + 待核实字段 + 官方。
        - 查询必须具体可搜，禁止"各大厂商""旗舰手机合集"这类泛词；时效信息在查询里补年份。
        - queries 最多 4 条；recency 取值 any/day/week/month/year。
        - 无论用户消息多含糊、多像反问或闲聊，都必须按约定输出合法 JSON，不得输出解释或反问；确实无法判断或无需联网时输出 {"intent":"none","entities":[],"queries":[]}。
        只输出 JSON，不要任何解释：{"intent":"...","entities":["..."],"queries":[{"q":"...","recency":"..."}]}
        """
        let user = "用户本轮消息：\(String(userText.prefix(600)))\n备用检索词（规则提取，仅参照）：\(seed)"
        let text = await ChatService.completeOnce(profile: profile, apiKey: apiKey, system: system, user: user,
                                                  maxTokens: 512, thinkingDisabled: true)
        guard let text else { return nil }
        return SearchPlan.parse(text)
    }

    /// 从回答内容启发式生成 2-3 条追问建议：不额外调用模型，无等待
    func makeFollowUps(from text: String) -> [String] {
        guard text.count > 40 else { return [] }
        var out: [String] = []
        let headings = text.components(separatedBy: .newlines)
            .compactMap { line -> String? in
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("###") else { return nil }
                let title = t.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                return (2...18).contains(title.count) ? title : nil
            }
        if let first = headings.first { out.append("展开讲讲" + first) }
        if text.contains("未核实") { out.append("把未核实的字段再查一轮") }
        if text.contains("|") || text.contains("│") { out.append("把这份对比导出成 Excel 文件") }
        if headings.count > 1, let second = headings.dropFirst().first,
           !out.contains(where: { $0.contains(second) }) {
            out.append("基于" + second + "给出行动清单")
        }
        if out.isEmpty { out.append("总结一下要点"); out.append("接下来该做什么？") }
        return Array(out.prefix(3))
    }

    /// 清空当前会话全部消息并重置失败状态
    func clearConversation() {
        failedUserMessageID = nil
        failedAssistantMessageID = nil
        orderedMessageCount = -1
        for m in conversation?.messages ?? [] { modelContext.delete(m) }
        // 10-23：编辑重发前的删除要显式（失败会导致旧消息残留、新消息重复）
        saveOrWarn()
    }

    // MARK: - 工具调用主循环

    /// 一轮回答的完整执行流程：
    /// 能力/目标校验 → （可选）LLM 查询规划 + 并行预检索 → 工具循环（流式接收、
    /// 执行 web_search/generate_image/create_document 等工具、回注结果）→
    /// 落库与收尾（来源序列化、追问建议、自动命名、滚动摘要、记忆抽取）。
    /// 任何异常路径都要保证：额度补记、部分内容保留、失败状态可重试。
}
