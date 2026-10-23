import Foundation
import SwiftData
import UIKit

// ─────────────────────────────────────────────────────────────────────────────
// 文件职责：单个会话的对话核心逻辑（ChatViewModel）——流式回复、联网检索调度、
// 工具调用主循环、上下文组装、附件导入、会话导出、记忆抽取与滚动摘要。
//
// 在整个 App 中的角色：
//   ChatView 持有本 VM；它向上驱动 UI（流式缓冲、状态条、追问建议），
//   向下编排 ChatService（模型流）、ResearchSearching（检索）、
//   ExpertSkillRuntime / DocumentBuilder / ImageService（工具执行）与
//   SwiftData（消息落库）。
//
// 关键设计决策：
//   1. 引用注册与编号稳定性：每轮回答前 citations 清零重开，本轮内 register
//      保证同 URL 编号稳定；回答结束后来源序列化进 sourcesJSON 随消息落库；
//   2. 深度答 6 秒进度提示（P0-20）：tier=pro 首字延迟可达 10 秒+，6 秒无首字
//      则提示"正在深度分析"，收到首 token 或本轮结束立即撤除（FirstTokenFlag
//      用锁保护的布尔位跨并发域读取，防 data race）；
//   3. 专家能力清单注入 capabilityPrompt（P0-21）：按服务端功能开关动态拼装
//      注入稳定 system 块，根治模型对已支持功能回答"我做不到"；
//   4. 写盘校验防谎报：导出文件后二次校验 FileStore.exists + byteCount > 0，
//      两层都通过才提示"已导出"，宁可报错也不假报成功；
//   5. 流式文本只写内存缓冲（StreamingReplyBuffer），不逐 delta 写 SwiftData，
//      结束后才一次性落库，消除卡顿；
//   6. 成本护栏：每轮请求前后计入 BudgetTracker，异常路径也补记（accounted 标志）。
// ─────────────────────────────────────────────────────────────────────────────

/// 一次 web_search 的执行结果（要在并行 Task 之间传递，需 Sendable）
struct SearchOutcome: Sendable {
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
    @Published var researchMode: ResearchMode = .automatic
    @Published var answerStyle: AnswerStyle = .concise
    /// P0-38 配置面板档位（standard / high / ultra）。按产品要求默认「标准」且不持久化——
    /// 每次启动/新会话回到默认，避免客户在不知情的情况下长期停在低/高档位。
    @Published var chatMode: String = "standard"
    @Published var researchSummary: String?
    @Published var isStreaming = false
    @Published var statusText: String?
    @Published var errorMessage: String?
    @Published var failedUserMessageID: UUID?
    var failedAssistantMessageID: UUID?
    var canRetryReply: Bool { failedUserMessageID != nil && !isStreaming && !isImporting }
    /// 待发送的附件
    @Published var pendingAttachments: [StoredFile] = []
    @Published var isImporting = false
    @Published var isExporting = false
    @Published var toast: String?
    // P0-50 生图占位（ChatGPT 式加载动效）：非 nil 时消息流底部显示 shimmer 占位行
    @Published var pendingImage: String?
    // P0-60 稳定调用：本轮已自动重试次数（防死循环；send 时重置；P0-64 上限云端可调）
    var autoRetryCount = 0
    // P0-68 深度思考状态（最高档推理模型首字延迟 ~11s）：流式期间显示"深度思考中…"，消除空等感
    @Published var isReasoning = false
    /// 流式输出中的文本（不落库，只驱动 UI，消除每 delta 写 SwiftData 的卡顿）
    let replyBuffer = StreamingReplyBuffer()
    /// 流式文本的读写代理（实际存储在 replyBuffer）
    var streamingText: String {
        get { replyBuffer.text }
        set { replyBuffer.text = newValue }
    }
    /// 正在流式输出的消息 id
    @Published var streamingMessageId: UUID?
    /// 本轮回答结束后的追问建议（ChatGPT 式 chips，本地启发式生成，零成本零延迟）
    @Published var suggestedFollowUps: [String] = []

    /// 会话（nil = 草稿态：用户还没发第一条消息，此时不写入数据库）
    var conversation: Conversation?
    /// 草稿态首次发消息、真正建出会话时回调，用于侧栏切换过去
    var onConversationCreated: ((Conversation) -> Void)?
    let expert: Expert

    var chatService: ChatService { injectedChatService ?? ChatService(profile: ProviderCatalog.currentChat(), apiKeyProvider: chatKey) }
    var imageService: ImageService { ImageService(profile: ProviderCatalog.currentImage(), apiKeyProvider: imageKey) }
    var memoryService: MemoryService { MemoryService(profile: ProviderCatalog.currentChat(), apiKeyProvider: chatKey) }
    let injectedChatService: ChatService?
    let researchService: any ResearchSearching
    /// 可注入的检索规划器（测试用 mock）；nil 时用内置 LLM 规划
    let injectedSearchPlanner: (@Sendable (String, String) async -> SearchPlan?)?
    let chatKey: () -> String?
    let imageKey: () -> String?
    let modelContext: ModelContext
    var streamTask: Task<Void, Never>?

    var fileCache: [UUID: StoredFile] = [:]
    /// 10-22 上下文预算可观测：每次构建请求后记录总字符与是否触发裁剪（先可观测，再谈优化）
    /// 10-22 长任务编排（最小版）：记录「上次未跑完的任务」，供下次进入会话时提示继续。
    /// 只存用户原话与开始时间（不存 apiMessages，避免体积与协议配对问题），恢复=重新跑一遍。
    @Published var resumableTaskText: String?
    static let taskProgressKey = "bossai.task.progress"
    /// 10-22：关键保存失败的可观测状态（助手正文/引用/迁移）。UI 可据此提示「已生成但未持久化」。
    @Published var persistenceWarning: String?
    private(set) var lastContextChars: Int = 0
    private(set) var contextTruncated: Bool = false
    var fileCacheLoaded = false
    var filesObserver: NSObjectProtocol?
    /// 本轮联网搜索命中的来源链接，去重后作为「信息来源」附在回答末尾
    var citations = CitationRegistry()

    init(conversation: Conversation?,
         expert: Expert,
         modelContext: ModelContext,
         chatKey: @escaping () -> String?,
         imageKey: @escaping () -> String?,
         chatService: ChatService? = nil,
         researchService: any ResearchSearching = DefaultResearchSearch(),
         searchPlanner: (@Sendable (String, String) async -> SearchPlan?)? = nil) {
        self.conversation = conversation
        // P0-68 注入服务端官方搜索实现（WebSearchService 不依赖 App 层类型——含本文件亦是，
        // 由这里提供闭包实现；服务端未配置/失败时返回 nil，搜索自动降级本地多引擎）
        WebSearchService.hostedSearchProvider = { query, count in
            let token: String? = await MainActor.run {
                HostedAccount.isHostedActive ? HostedAccount.shared.token : nil
            }
            guard let token, !token.isEmpty,
                  let url = URL(string: AppConfig.hostedAPIBase + "/tools/search") else { return nil }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query, "count": count])
            req.timeoutInterval = 15
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = j["results"] as? [[String: Any]], !results.isEmpty else { return nil }
            let hits: [SearchHit] = results.compactMap { r in
                guard let title = r["title"] as? String, let u = r["url"] as? String,
                      !title.isEmpty, !u.isEmpty else { return nil }
                var snippet = (r["summary"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (r["snippet"] as? String) ?? ""
                if let auth = r["authority"] as? Int, auth >= 3 { snippet = "【高权威来源】" + snippet }
                let date = String(((r["date"] as? String) ?? "").prefix(10))
                return SearchHit(title: title, url: u, snippet: String(snippet.prefix(500)), publishedAt: date)
            }
            return hits.isEmpty ? nil : hits
        }
        self.expert = expert
        self.modelContext = modelContext
        self.chatKey = chatKey
        self.imageKey = imageKey
        // P0-16 一次性回填：历史数据没有 ownerKey → 归属当前账号，避免隔离后"记录消失"
        Self.backfillOwnerScopeIfNeeded(modelContext)
        self.injectedChatService = chatService
        self.researchService = researchService
        self.injectedSearchPlanner = searchPlanner
        filesObserver = NotificationCenter.default.addObserver(forName: .bossAIFilesChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.invalidateFileCache() }
        }
        // 10-22 长任务编排：若上次任务在同一会话里异常中断，进入时把它挂出来供用户决定是否继续。
        if let progress = UserDefaults.standard.dictionary(forKey: Self.taskProgressKey),
           let text = progress["text"] as? String, !text.isEmpty,
           let convID = progress["conv"] as? String,
           convID == (conversation?.id.uuidString ?? "") {
            resumableTaskText = text
        }
    }

    deinit {
        streamTask?.cancel()
        if let filesObserver { NotificationCenter.default.removeObserver(filesObserver) }
    }

    var orderedMessageCache: [Message] = []
    var orderedMessageCount = -1
    /// P0-45 消息刷新信号：sortedMessages 的缓存失效由手动控制（数量变化自动失效之外，
    /// 打开历史会话/数据晚到时由 requestMessageReload() 强制失效）。
    /// 该属性是 @Published——视图 body 读取 sortedMessages（内部会读取本属性）即可建立
    /// SwiftUI 依赖，任何强制刷新都会触发重渲染——修复"打开历史对话空白且永不自愈"。
    @Published var messageRevision = 0

    /// 强制消息列表刷新（重置排序缓存 + 触发视图更新）。
    /// 使用场景：①打开历史会话首帧（SwiftData 关系解析时序可能返回空）②切后台回来 ③兜底自愈。
    func requestMessageReload() {
        orderedMessageCount = -1
        messageRevision &+= 1
    }

    /// 会话消息按时间排序（带缓存：消息数不变时直接返回上次结果，
    /// 避免每帧 body 重算排序；数量变化才重建）。
    /// P0-45：getter 内读取 messageRevision 建立 SwiftUI 依赖——视图与刷新信号强绑定。
    var sortedMessages: [Message] {
        _ = messageRevision   // 建立依赖（不要删除）
        let messages = conversation?.messages ?? []
        if orderedMessageCount != messages.count {
            orderedMessageCache = messages.sorted { $0.createdAt < $1.createdAt }
            orderedMessageCount = messages.count
        }
        return orderedMessageCache
    }

    // MARK: - 附件

    // MARK: - P0-16 账号数据隔离

    private static var didBackfillScope = false

    /// 首次运行把「无归属」的历史对话、文件与记忆归属到当前账号（幂等、一次/进程）
    /// 10-23 P0：补齐 MemoryItem 归属回填，避免旧记忆因 ownerKey 为空被当前账号过滤掉
    private static func backfillOwnerScopeIfNeeded(_ context: ModelContext) {
        guard !didBackfillScope else { return }
        didBackfillScope = true
        let key = HostedAccount.scopeKey
        guard !key.isEmpty else { return }
        if let legacy = try? context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.ownerKey == "" })),
           !legacy.isEmpty {
            for c in legacy { c.ownerKey = key }
            try? context.save()
        }
        if let files = try? context.fetch(FetchDescriptor<StoredFile>(predicate: #Predicate { $0.ownerKey == "" })),
           !files.isEmpty {
            for f in files { f.ownerKey = key }
            try? context.save()
        }
        if let memories = try? context.fetch(FetchDescriptor<MemoryItem>(predicate: #Predicate { $0.ownerKey == "" })),
           !memories.isEmpty {
            for m in memories { m.ownerKey = key }
            try? context.save()
        }
        // P0-46 conversationID 冗余字段回填（老数据；@Query 派生视图依赖）
        if let convs = try? context.fetch(FetchDescriptor<Conversation>()) {
            var patched = 0
            for c in convs {
                for m in c.messages where m.conversationID == nil {
                    m.conversationID = c.id; patched += 1
                }
            }
            if patched > 0 { try? context.save() }
        }
    }

    // MARK: - 联网搜索执行（可并行）

    /// 执行一次 web_search：搜索 → 并行抓正文 → 格式化成给模型看的上下文
    ///
    /// Network and DOM parsing do not execute on MainActor; priority order survives concurrency.
    /// P0-50 当前年月（中文格式，搜索时效增强用）
    nonisolated static func currentYearMonth() -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月"
        return f.string(from: Date())
    }

    /// P0-57 取本轮用户上传的第一张图片数据（作为生图参考图）——此前生图只支持编辑 AI 生成的图，
    /// 用户上传的图片（如 Logo、底图）无法作为编辑底图，导致"把 Logo 放到图二上"静默失败。
    func attachedImageData(in conv: Conversation) -> Data? {
        let imgExts = ["png", "jpg", "jpeg", "webp", "heic"]
        let userMsgs = conv.messages.filter { $0.role == "user" && !$0.attachmentIdList.isEmpty }
        guard let lastUser = userMsgs.last else { return nil }
        for file in files(for: lastUser) where imgExts.contains(file.ext.lowercased()) {
            if let data = try? Data(contentsOf: FileStore.url(for: file)) { return data }
        }
        return nil
    }

    /// P0-74 视觉审核（调服务端 qwen3-vl-plus）：判断生成图是否满足"用户要求"。
    /// 返回 nil = 无法验证（未登录/未配置/网络失败）——调用方不阻断出图（验证是增强，不是依赖）。
    nonisolated static func visionCheck(imageData: Data, requirement: String) async -> (ok: Bool, note: String)? {
        let token: String? = await MainActor.run { HostedAccount.isHostedActive ? HostedAccount.shared.token : nil }
        guard let token, !token.isEmpty,
              let url = URL(string: AppConfig.hostedAPIBase + "/vision-check") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "image": "data:image/jpeg;base64," + imageData.base64EncodedString(),
            "question": "用户要求：\(String(requirement.prefix(200)))。生成的图片是否满足该要求？",
        ])
        req.timeoutInterval = 45
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (ok: (j["ok"] as? Bool) ?? true, note: (j["note"] as? String) ?? "")
    }

    /// P0-52 Hermes 式失败重试：上游网关/超时类失败自动重试一次（网络抖动救回；参数/额度不重试）。
    /// 借鉴 Hermes Agent 的健壮工具调用设计——"偶发失败自动恢复"是工具调用可靠性的重要一环。
    /// P0-53 修正：网络错误（URLError）是 URLSession 直接抛出的，不经过 ImageError——
    /// 此前只匹配 ImageError，导致"最该重试的网络超时"反而没被重试。
    nonisolated static func generateImageWithRetry(prompt: String, references: [Data], service: ImageService, structured: [String: Any]? = nil, layerDecomposition: Bool = false) async throws -> Data {
        // 同一次生成（含重试）复用同一 requestId，服务端据此幂等去重
        let idemKey = UUID().uuidString
        // P0-64 重试次数云端可调（在线可修复）：管理台改 APP_IMAGE_RETRY 即生效
        let limit = HostedAccount.isHostedActive ? HostedAccount.cachedImageRetry : 1
        var attempt = 0
        while true {
            do {
                return try await service.generate(prompt: prompt, references: references, structured: structured, requestId: idemKey, layerDecomposition: layerDecomposition)
            } catch {
                let retryable = (error as? URLError) != nil
                    || ((error as? ImageService.ImageError)?.isRetryable ?? false)
                guard retryable, attempt < limit else { throw error }
                attempt += 1
                try await Task.sleep(nanoseconds: 1_200_000_000)
            }
        }
    }

    nonisolated static func searchQuery(_ call: ChatService.ToolCall, fallback: String) -> (String, SearchRecency) {        let args = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any]
        let query = (args?["query"] as? String) ?? fallback
        return (query, (args?["recency"] as? String).flatMap(SearchRecency.init(rawValue:)) ?? SearchRecency.inferred(from: query))
    }
    nonisolated static func runWebSearch(call: ChatService.ToolCall, order: Int, fallback: String, provider: any ResearchSearching) async -> SearchOutcome {
        let span = PerformanceTrace.begin("WebSearch")
        defer { PerformanceTrace.end("WebSearch", span) }
        let args = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any]
        let rawQuery = (args?["query"] as? String) ?? fallback
        // P0-50 搜索时效性增强：行情/价格/新闻类查询且未含年份时，自动附加当前年月——
        // 实测搜索引擎对无时间词的查询倾向返回旧页面快照（用户实机曾搜到一年前的金价数据）。
        let timewords = ["行情", "价格", "多少钱", "最新", "今天", "今日", "新闻", "汇率", "金价", "股价", "报价", "走势", "天气"]
        let hasYear = rawQuery.range(of: #"20\d{2}"#, options: .regularExpression) != nil
        let needsFresh = timewords.contains { rawQuery.contains($0) }
        let query = (needsFresh && !hasYear) ? rawQuery + " " + Self.currentYearMonth() : rawQuery
        let recency = (args?["recency"] as? String).flatMap(SearchRecency.init(rawValue:)) ?? SearchRecency.inferred(from: query)
        let hits = await provider.search(query: query, count: 6, recency: recency)

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
        var pages: [(title: String, url: String, text: String)] = []
        // Priority batches retain slow authoritative pages; nonempty text alone is insufficient.
        for start in stride(from: 0, to: candidates.count, by: 3) {
            if Task.isCancelled || pages.count >= fetchCount { break }
            let batch = Array(candidates[start..<min(start + 3, candidates.count)])
            let raw = await withTaskGroup(of: (Int, String, String, String).self) { group in
                for (i, hit) in batch.enumerated() {
                    group.addTask { (i, hit.title, hit.url, await provider.page(url: hit.url, limit: 3500)) }
                }
                var collected: [(Int, String, String, String)] = []
                for await item in group { collected.append(item) }
                return collected.sorted { $0.0 < $1.0 }
            }
            for item in raw where item.3.count > 80 && ResearchIntent.relevance(query: query, text: item.3) > 0 {
                if pages.count < fetchCount { pages.append((item.1, item.2, item.3)) }
            }
        }

        return SearchOutcome(order: order,
                             callId: call.id,
                             hits: hits, pages: pages, emptyMessage: nil)
    }

    // MARK: - 上下文组装：专家 prompt + 身份 + 记忆 + 附件正文

    /// 组装发送给模型的完整消息数组：
    /// 两条 system（稳定块+易变块，P0-2 缓存稳定化）→ 最近 40 条消息（含附件
    /// 注入与多模态图片）→ 尾部按 48K 字符预算裁剪。稳定块永不变化保证前缀缓存命中。
    /// 统一的关键保存入口：失败不静默，写入 persistenceWarning 供 UI 展示。
    /// 说明：这里不抛错（调用点多为收尾路径，抛错会打断流式收尾）；但失败一定可观测。
    func saveOrWarn() {
        do {
            try modelContext.save()
        } catch {
            persistenceWarning = "内容已生成，但保存到本地失败（\(error.localizedDescription)）。请先复制重要内容，稍后重试。"
        }
    }

    func buildAPIMessages(conv: Conversation) -> [[String: Any]] {
        let span = PerformanceTrace.begin("ContextBuild")
        defer { PerformanceTrace.end("ContextBuild", span) }
        let identity = UserIdentity.load()
        let memories = memoryService.injectionFragment(context: modelContext)

        // P0-2 缓存稳定化：拆成两条 system 消息——
        // ① 稳定块（专家提示词+身份+回复风格）永不变化，保证方舟前缀缓存始终命中；
        // ② 易变块（前情摘要+记忆+任务模式+交付格式）紧随其后，变化时只牺牲短前缀。
        let stableSystem = expert.systemPrompt + identity.promptFragment + identity.replyStyle.prompt
            + Self.capabilityPrompt()
        var volatileSystem = ""
        if !conv.rollingSummary.isEmpty {
            volatileSystem += "【前情摘要】本会话较早部分的要点：\n" + conv.rollingSummary + "\n\n"
        }
        volatileSystem += memories
            + "\n【时效铁律】凡涉及价格、新品、型号、配置、汇率、政策法规、版本号、榜单等易变事实：必须先调用 web_search 获取最新信息并在回答中标注信息日期，禁止仅凭训练记忆作答；检索不可用时明确声明信息可能过时。"
            + "\n【本任务模式】" + researchMode.prompt + "\n【交付格式】" + answerStyle.prompt
            + "\n【当前实际模型配置】" + chatService.configurationLabel

        var messages: [[String: Any]] = [
            ["role": "system", "content": stableSystem],
            ["role": "system", "content": volatileSystem],
        ]
        var injectedBudget = 30000

        for m in sortedMessages.suffix(40) {
            if m.imageData != nil {
                messages.append(["role": "assistant", "content": "[已向用户展示生成的图片]"])
                continue
            }

            let messageText = m.role == "assistant" ? CitationPresentation.historyContext(text: m.text, json: m.sourcesJSON) : m.text
            let attached = files(for: m)
            if attached.isEmpty {
                if !m.text.isEmpty {
                    messages.append(["role": m.role, "content": messageText])
                }
                continue
            }

            // 图片附件 → 多模态；其他附件 → 抽取文本
            var textParts: [String] = []
            if !messageText.isEmpty { textParts.append(messageText) }
            var imageURLs: [String] = []
            // 10-23 408 修复：只允许「最后一条用户消息」携带图片本体。
            // 旧实现每轮都会把历史里所有附件重新转 base64（一张 1.5MB → 约 200 万字符），
            // 多轮对话后请求体膨胀到几十 MB，网关直接 408；同一会话"第一轮能看图、之后全 408"由此而来。
            let isLatestUserMessage = (m.id == sortedMessages.last(where: { $0.role == "user" })?.id)

            for file in attached {
                if file.isImage {
                    // P0-13 真·看图：除 OCR 文本外把原图作为多模态 image_url 输入（10-19 张数 3→6，
                    // 配合参考图压缩 768/0.65，单次 6 张约 0.5MB 仍在云网关限制内）
                    if isLatestUserMessage, imageURLs.count < 6, let dataURL = Self.imageDataURL(for: file) {
                        imageURLs.append(dataURL)
                    } else if !isLatestUserMessage {
                        // 历史图片：不再重发本体，只保留占位说明（模型仍知道"当时看过这张图"）
                        textParts.append("【历史图片：\(file.name)（此前已识别，本轮不重复传输）】")
                    }
                    let ocr = file.contextText(limit: 2000)
                    if !ocr.isEmpty {
                        textParts.append("【图片文字OCR（辅助，可能有误差）：\(file.name)】\n" + ocr)
                    } else {
                        textParts.append("【图片附件：\(file.name)】已作为图片输入，请直接看图回答。")
                    }
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
        for message in messages.dropFirst(2).reversed() {
            // 两条 system 消息（稳定块+易变块）固定在头部，不参与尾部预算
            guard remaining > 0 else { break }
            if let text = message["content"] as? String {
                let clipped = String(text.prefix(remaining))
                remaining -= clipped.count
                selected.append(["role": message["role"] ?? "user", "content": clipped])
            } else if let parts = message["content"] as? [[String: Any]] {
                // P0-13：多模态消息（图片+文本）不能整体丢弃。
                // 10-22 修复：此前只扣预算不截断，超预算仍完整加入——现在按剩余预算截断文本，
                // 图片始终保留（图片是当前任务的关键输入，不占字符预算）。
                let textLen = parts.compactMap { $0["text"] as? String }.joined().count
                if textLen <= remaining {
                    remaining -= textLen
                    selected.append(message)
                } else {
                    var clippedParts: [[String: Any]] = []
                    var budget = remaining
                    for part in parts {
                        if let t = part["text"] as? String {
                            guard budget > 0 else { continue }
                            let clipped = String(t.prefix(budget))
                            budget -= clipped.count
                            clippedParts.append(["type": "text", "text": clipped])
                        } else {
                            clippedParts.append(part)   // 图片等非文本内容保留
                        }
                    }
                    remaining = 0
                    selected.append(["role": message["role"] ?? "user", "content": clippedParts])
                }
            }
        }
        // 10-22 统一预算观测：把「system 固定块 + 参与预算的正文」合计成总字符数留痕。
        // 不改变现有裁剪行为（先可观测，避免高风险改动)；多模态消息里的图片不计字符。
        let systemChars = messages.prefix(2).compactMap { ($0["content"] as? String)?.count }.reduce(0, +)
        let bodyChars = selected.reduce(0) { acc, msg in
            if let t = msg["content"] as? String { return acc + t.count }
            if let parts = msg["content"] as? [[String: Any]] {
                return acc + parts.compactMap { ($0["text"] as? String)?.count }.reduce(0, +)
            }
            return acc
        }
        lastContextChars = systemChars + bodyChars
        contextTruncated = remaining <= 0

        return [messages[0], messages[1]] + selected.reversed()
    }

    /// 读取图片附件 → 交给 ImageCompressor 压缩（长边 1024 / JPEG 0.78）→ data URL。
    /// P0-42：视觉 token ≈ 像素 ÷ 750，压缩到 1K 长边可省约 90% 的识别成本（实测识别质量无损）。
    /// 失败返回 nil：调用方降级为"仅 OCR 文本"，绝不因图片处理失败而中断发送。
    /// 10-22 性能：图片「读取 → 解压 → 缩放 → 重编码 → base64」只做一次并缓存。
    /// 此前每轮模型请求都会对同一批附件重做一遍（最多 6 张），多轮工具循环下开销叠加。
    /// 注：这是最小改动版——彻底方案是把预处理改成异步管道（避免首帧在主线程解码大图）。
    private static var imageURLCache: [UUID: String] = [:]

    static func imageDataURL(for file: StoredFile) -> String? {
        if let cached = imageURLCache[file.id] { return cached }
        let url = FileStore.url(for: file)
        guard let raw = try? Data(contentsOf: url), !raw.isEmpty else { return nil }
        guard let payload = ImageCompressor.compressedData(from: raw) else { return nil }
        let dataURL = "data:image/jpeg;base64," + payload.base64EncodedString()
        imageURLCache[file.id] = dataURL
        return dataURL
    }

    // MARK: - 编辑重发（P0-4）

    /// 删除该消息及其后的全部消息，以编辑后的文本重新发送。
    /// 附件文件本体保留在本地（孤儿文件由既有备份/清理机制统一处理）。
    func resendEdited(_ message: Message, newText: String) {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard message.role == "user", !trimmed.isEmpty, !isStreaming, let conv = conversation else { return }
        let cutoff = message.createdAt
        for m in conv.messages where m.createdAt >= cutoff {
            modelContext.delete(m)
        }
        try? modelContext.save()
        inputText = trimmed
        send()
    }

    // MARK: - 导出

    /// 把当前会话导出为文件并存入资料库，返回提示文案
    func exportConversation(format: DocumentFormat) async -> String {
        guard !isExporting else { return "正在导出，请稍候" }
        isExporting = true
        defer { isExporting = false }
        let title = (conversation?.title.isEmpty ?? true) ? expert.name : (conversation?.title ?? expert.name)
        var lines: [String] = []
        for message in sortedMessages {
            if message.imageData != nil { lines.append("[此消息包含图片，文字导出未嵌入图片]") }
            for file in files(for: message) { lines.append("附件：" + file.name) }
            guard !message.text.isEmpty else { continue }
            let projection = CitationPresentation.projection(text: message.text, json: message.sourcesJSON)
            lines.append(message.role == "user" ? "**我：**\(message.text)" : projection.body)
            let cited = CitationPresentation.cited(projection.sources, in: projection.body)
            if !cited.isEmpty { lines.append("\n信息来源：\n" + CitationPresentation.markdown(cited)) }
            lines.append("")
        }
        guard !lines.isEmpty else { return "当前对话没有可导出的内容" }
        let markdown = "# \(title)\n\n" + lines.joined(separator: "\n")
        do {
            let data = try await DocumentBuilder.buildAsync(format: format, title: title, content: markdown)
            let name = DocumentBuilder.safeFilename(title, fallback: "对话导出")
            let file = "\(name)-\(Self.timestamp()).\(format.ext)"
            // 双重防谎报：FileStore 内部已做写盘校验，这里再确认记录对应的文件真实存在，
            // 只有两层都通过才允许提示"已导出"——宁可报错让用户重试，也不假报成功。
            let record = try await FileStore.storeAsync(data: data, filename: file, kind: .generated,
                                    sourceConversationId: conversation?.id.uuidString ?? "",
                                    textContent: markdown, context: modelContext)
            invalidateFileCache()
            guard FileStore.exists(record), record.byteCount > 0 else {
                return "导出失败：文件落盘校验未通过，请重试"
            }
            return "已导出 \(file)，可在资料库查看"
        } catch {
            return "导出失败：\(error.localizedDescription)"
        }
    }

    /// 会话标题时间戳（yyyyMMdd_HHmmss，导出文件命名用）
    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }

    /// P0-21 专家能力清单注入：实测模型经常对 App 已支持的功能回答"我做不到"
    /// （例如"我无法生成 Excel"——实际导出菜单里有 Excel）。根因是系统提示词
    /// 从未告诉模型这个 App 能做什么。这里按服务端下发的功能开关动态拼装，
    /// 无关功能不出现，未开通的能力也不承诺（保持与档位权益一致）。
    static func capabilityPrompt() -> String {
        var caps: [String] = []
        // 联网能力所有档位都有：web_search 是工具调用，App 端执行后回注证据
        caps.append("联网检索：需要最新事实时可调用 web_search 工具，回答中标注来源编号")
        if HostedAccount.cachedDeepResearchEnabled {
            caps.append("深度研究：最多可并行检索 8 个主题并逐页读取原文，适合多品牌对比、参数核实")
        }
        // 10-23 关键修复：此前清单里完全没有"作图"，模型面对"设计名片/做海报"会退化成给文字方案或 Word。
        caps.append("图片生成：用户说「做一张图 / 设计海报 / 重新设计名片 / 出封面 / 配图 / 画个示意图」时，**必须直接调用 image_generate 出图**（改已有图用 image_edit），不要用文字描述、规格清单或 Word 文档代替图片——用户要的是图，不是排版说明")
        if HostedAccount.cachedExportDocEnabled {
            caps.append("文档导出：回答完成后，用户可点击右上角导出按钮把整段对话生成 Word/PPT/Excel/PDF 文件——当用户要'文件/表格/文档'时，请直接给出完整内容并提醒用户使用导出功能，严禁说'我无法生成文件'")
        }
        if HostedAccount.cachedSchedulesEnabled {
            caps.append("定时任务：用户可在'身份设置→定时任务'里设置每日/每周自动执行的任务（如每日早报），你可以引导用户去配置")
        }
        if HostedAccount.cachedCustomExpertEnabled {
            caps.append("自定义专家：用户可上传公司资料创建专属专家，涉及公司内部知识时可提醒用户在自定义专家里维护资料")
        }
        // P0-59 能力清单 = App 功能（云端权限驱动）+ 工具能力边界（ToolRegistry 单一真相来源）。
        // 后者让模型明确知道每个工具"能做什么/不能做什么"，根治能力幻觉导致的谎报。
        var text = ""
        if !caps.isEmpty {
            text = "\n【你所在的 App 能力清单】以下是中防AI已支持的功能，相关请求不得回答'做不到'：\n"
                + caps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        }
        text += "\n\n" + ToolRegistry.capabilityManifest(cloudExtra: HostedAccount.cachedCapabilityExtra, overrides: HostedAccount.cachedCapabilityOverrides)
        return text
    }
}

/// High-frequency deltas update only the active message, not the whole conversation VM.
@MainActor
final class StreamingReplyBuffer: ObservableObject {
    @Published var text = ""
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

/// 线程安全的首 token 标记：深度答 6 秒进度提示用。
/// 流事件在 AsyncThrowingStream 回调线程到达，定时器任务读取时需跨并发域，
/// 用锁保护的布尔位避免 data race（比 actor 更轻，适合单布尔）。
final class FirstTokenFlag: @unchecked Sendable {
    let lock = NSLock()
    var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}
