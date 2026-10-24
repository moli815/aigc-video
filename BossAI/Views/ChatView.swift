import SwiftUI
import SwiftData
import UIKit

// ─────────────────────────────────────────────────────────────────────────────
// 文件职责：对话界面的全部视图层——容器（ChatContainerView，负责创建/持有 VM）、
// 专家横幅、消息列表（含流式打字机行）、输入栏挂载、追问建议、编辑重发、
// 空态与任务控制条。
//
// 在整个 App 中的角色：
//   MainView 按 containerKey 挂载 ChatContainerView；容器用 ViewModelHolder
//   持有 ChatViewModel（外层已按会话 .id() 强制重建，VM 只建一次）。
//
// 关键设计决策：
//   1. 滚动方案（P0-11 / P0-17）：废弃持久化 scrollPosition(id:) 绑定（键盘等
//      布局变化会用过期几何重新锚定，造成顶空/抽动），改为「一次性滚动请求」
//      pendingScrollTarget——消费后立即清空；输入栏放进 safeAreaInset(edge:.bottom)
//      让系统接管键盘避让，滚动区 defaultScrollAnchor(.bottom) 保证视口变化自动贴底，
//      不再监听键盘通知做滚动；
//   2. monogram 徽章（P0-23）：专家头像用「首字 + 固定 frame + 居中」的 Text 徽章
//      替代 SF Symbol——Symbol 之间视觉宽度/重心差异是字体固有的，缩放无法根治；
//      文字天然居中，任何专家、任何字体下都绝对对齐；
//   3. ForEach enumerated 防呆（配合 MainView 侧栏）：显式 id 绑定 element.id，
//      enumerated 索引仅用于画分隔线，不作为视图身份；
//   4. 流式性能：高频 delta 只更新 StreamingMessageRow 内的缓冲对象，
//      打字机 18ms 一帧平滑追帧，滚动用 0.12s trailing debounce 合并。
// ─────────────────────────────────────────────────────────────────────────────

/// 对话容器。
/// - 已有会话：传 conversation
/// - 草稿态（点了专家但还没发消息）：conversation 为 nil，第一次发送时才落库
struct ChatContainerView: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var credentials: CredentialStore
    @StateObject private var viewModelHolder = ViewModelHolder()
    @State private var showIdentity = false
    @State private var showMembership = false
    /// P0-38 配置面板显隐（模型/强度/速度）
    @State private var showConfig = false
    @State private var showExportAlert = false
    @State private var exportMessage = ""
    @State private var exporting = false
    @State private var previewFile: StoredFile?

    let conversation: Conversation?
    let expert: Expert
    var onConversationCreated: (Conversation) -> Void = { _ in }
    var initialText: String = ""
    /// P0-47 方案 A：草稿态预置研究模式（侧栏「深度研究」入口 → 新对话默认联网研究）
    var initialResearchMode: ResearchMode?

    /// P0-46 @Query 派生视图：消息渲染改为 SwiftData 响应式数据源（数据变化自动刷新，
    /// 根治"打开历史对话空白/同步回来不显示"类问题）。草稿态（conversation 为 nil）
    /// 仍走 VM 的 sortedMessages（发送后才落库）。
    @Query private var liveMessages: [Message]

    init(conversation: Conversation?, expert: Expert,
         onConversationCreated: @escaping (Conversation) -> Void = { _ in },
         initialText: String = "",
         initialResearchMode: ResearchMode? = nil) {
        self.conversation = conversation
        self.expert = expert
        self.onConversationCreated = onConversationCreated
        self.initialText = initialText
        self.initialResearchMode = initialResearchMode
        let cid = conversation?.id
        _liveMessages = Query(filter: #Predicate<Message> { $0.conversationID == cid },
                              sort: \Message.createdAt)
    }

    /// VM 延迟持有器：body 首次求值时 VM 还未创建，用 Optional 包一层，
    /// 建好后触发 ChatView 挂载
    final class ViewModelHolder: ObservableObject {
        @Published var vm: ChatViewModel?
    }

    var body: some View {
        Group {
            if let vm = viewModelHolder.vm {
                ChatView(viewModel: vm,
                         liveMessages: liveMessages,
                         useLiveMessages: conversation != nil,
                         previewFile: $previewFile)
            } else {
                Color.clear
            }
        }
        // 外层已按会话 .id() 强制重建，这里只需在首次出现时建 VM
        .task {
            guard viewModelHolder.vm == nil else { return }
            let vm = ChatViewModel(
                conversation: conversation,
                expert: expert,
                modelContext: modelContext,
                chatKey: { credentials.chatKey },
                imageKey: { credentials.imageKey }
            )
            vm.inputText = initialText
            // P0-47 方案 A：预置研究模式（深度研究入口）
            if let initialResearchMode { vm.researchMode = initialResearchMode }
            vm.onConversationCreated = { created in
                onConversationCreated(created)
            }
            viewModelHolder.vm = vm
            // P0-45 打开历史会话时请求一次强制刷新（首帧时序兜底）；
            // 并在 0.8s 后做一次自愈检查：若视图仍为空但会话确有消息（首帧缓存了空结果），
            // 再强制刷新一次——彻底消除"打开历史对话空白且永不自愈"。
            vm.requestMessageReload()
            Task { @MainActor [weak vm] in
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard let vm else { return }
                if vm.sortedMessages.isEmpty, (vm.conversation?.messages.count ?? 0) > 0 {
                    vm.requestMessageReload()
                }
            }
        }
        .onDisappear { viewModelHolder.vm?.stop() }
        .navigationTitle(conversation?.title ?? expert.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // P0-38 配置入口：模型/强度/速度三行面板（对标主流 AI App 的"配置"结构）
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showConfig = true
                } label: {
                    Label("配置", systemImage: "slider.horizontal.3")
                }
                .accessibilityLabel("对话配置：模型与强度速度")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showIdentity = true
                } label: {
                    Label("身份设置", systemImage: "person.crop.circle")
                }
                .accessibilityLabel("身份设置")
            }
            ToolbarItem(placement: .topBarTrailing) {
                if !HostedAccount.cachedExportDocEnabled {
                    // P0-19 全量导出为 Pro+ 权益：Plus 显示锁，点击引导升级
                    Button { showMembership = true } label: {
                        Image(systemName: "lock.fill")
                    }
                    .accessibilityLabel("导出为 Pro 会员功能")
                } else {
                Menu {
                    ForEach(DocumentFormat.allCases) { format in
                        Button {
                            if let vm = viewModelHolder.vm {
                                guard !exporting else { return }
                                exporting = true
                                Task {
                                    exportMessage = await vm.exportConversation(format: format)
                                    exporting = false
                                    showExportAlert = true
                                }
                            } else {
                                exportMessage = "对话尚未就绪"
                            }
                            if viewModelHolder.vm == nil { showExportAlert = true }
                        } label: {
                            Label("导出为 \(format.displayName)", systemImage: format.symbol)
                        }
                    }
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .accessibilityLabel(exporting ? "正在导出" : "导出对话")
                .disabled(exporting)
                }
            }
        }
        .sheet(isPresented: $showMembership) { MembershipView() }
        .alert("导出", isPresented: $showExportAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text(exportMessage)
        }
        .sheet(isPresented: $showIdentity) {
            IdentitySheet()
        }
        // P0-38 配置面板：模型档位写回 viewModel.chatMode，随下一轮请求下发 chatMode 字段；
        // 每次启动默认「标准」（不持久化，避免客户在不知情下长期停在低/高档位）。
        .sheet(isPresented: $showConfig) {
            ChatConfigSheet(chatMode: Binding(
                get: { viewModelHolder.vm?.chatMode ?? HostedAccount.shared.defaultChatMode },
                set: { viewModelHolder.vm?.chatMode = $0 }
            ))
        }
        .sheet(item: $previewFile) { file in
            FilePreviewSheet(file: file)
        }
    }
}

/// 专家对话顶部横幅：标明正在与哪位顾问对话
struct ExpertBanner: View {
    @Environment(\.appTheme) private var theme
    let expert: Expert
    @State private var showSkills = false

    var body: some View {
        HStack(spacing: 10) {
            // P0-26 emoji 优先（云端下发），无 emoji 回退首字徽章；固定 frame 居中对齐
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.white.opacity(0.22))
                if let emoji = expert.emoji, !emoji.isEmpty {
                    Text(emoji).font(.system(size: 15))
                } else {
                    Text(String(expert.name.prefix(1)))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(expert.name)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                Text(expert.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            Spacer()
            Button("技能与工具", systemImage: "slider.horizontal.3") { showSkills = true }
                .font(.caption.weight(.semibold)).foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .liquidGlassCompat(Capsule(), elevated: false)
                .accessibilityIdentifier("expert-skills")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        // 深墨玻璃横幅：白字对比度实测 13:1 以上；主题色由描边与辉光承载
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.bannerFill)
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(GlassDesign.surfaceSheen)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.accent.opacity(0.42), lineWidth: 1)
        }
        .shadow(color: theme.glow, radius: 10, x: 0, y: 4)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
        .sheet(isPresented: $showSkills) { ExpertSkillSheet(expert: expert) }
    }
}

/// 对话区：消息列表 + 状态条 + 输入条
struct ChatView: View {
    @Environment(\.appTheme) private var theme
    @State private var followOutput = true
    // P0-11 滚动层重写（参考 exyte/Chat 成熟实现，1885★）：
    // 废弃持久化 scrollPosition(id:) 绑定——它会在键盘等每次布局变化时用过期几何重新锚定，
    // 是"键盘顶空/抽动"的最后根源。改为「一次性滚动请求」：目标消费后立即清空，不再重复锚定。
    // 10-23：滚动目标改为 AnyHashable —— 支持"底部锚点"字符串，而不只是某条消息 ID
    @State private var pendingScrollTarget: AnyHashable?
    @State private var pendingScrollAnimated = false
    @State private var scrollClock = ScrollClock()
    private final class ScrollClock { var lastTime: TimeInterval = 0; var pending: Task<Void, Never>? }
    @ObservedObject var viewModel: ChatViewModel
    @Binding var previewFile: StoredFile?
    // P0-46 @Query 派生视图：已有会话时用 SwiftData 响应式消息源（自动刷新），
    // 草稿态回退 VM 的 sortedMessages。
    let liveMessages: [Message]
    let useLiveMessages: Bool
    // P0-4 编辑重发
    @State private var editTarget: Message?

    init(viewModel: ChatViewModel, liveMessages: [Message] = [], useLiveMessages: Bool = false,
         previewFile: Binding<StoredFile?>) {
        self.viewModel = viewModel
        self.liveMessages = liveMessages
        self.useLiveMessages = useLiveMessages
        self._previewFile = previewFile
    }

    /// 渲染数据源：已有会话走 @Query（响应式），草稿态走 VM 缓存。
    private var displayMessages: [Message] {
        useLiveMessages ? liveMessages : viewModel.sortedMessages
    }

    /// 一次性贴底请求：写入末条消息 id，由 ScrollViewReader 消费后立即清空（关键：不做持久锚定）。
    private func requestScrollToBottom(animated: Bool = false, delay: TimeInterval = 0) {
        // 10-23 修复：滚到底部锚点，而不是"最后一条消息"——
        // 消息之后还可能渲染生图占位、追问建议、状态提示，滚到最后一条并不等于滚到内容末尾。
        let fire = {
            pendingScrollAnimated = animated
            pendingScrollTarget = AnyHashable("bottom-anchor")
        }
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: fire)
        } else {
            fire()
        }
    }

    /// 消息列表主体：滚动请求消费、下拉暂停跟随、流式 debounce 贴底、
    /// 追问建议 chips、状态条、错误与重试按钮。
    var body: some View {
        VStack(spacing: 0) {
            headerSection
            messageSection
        }
        // P0-17 滚动/键盘：改用业界成熟配方（Apple 示例同款）
        // ① 输入栏放进 safeAreaInset(edge: .bottom) → 键盘避让完全交给系统，不再手动算高度；
        // ② 滚动区加 defaultScrollAnchor(.bottom) → 键盘引起的视口变化由系统自动贴底；
        // ③ 不再监听键盘通知做滚动，避免与系统动画互相打架。
        .safeAreaInset(edge: .bottom, spacing: 0) {
            InputBar(viewModel: viewModel)
        }
        .background(Color.clear)
        // P0-4 编辑重发
        .sheet(item: $editTarget) { msg in
            EditResendSheet(initial: msg.text) { newText in
                viewModel.resendEdited(msg, newText: newText)
            }
        }

    }

    /// 顶部区：专家横幅 + 任务控制 + 云端用量提示。
    /// 拆出成独立表达式：SwiftUI body 过大时会触发类型检查超时。
    @ViewBuilder
    private var headerSection: some View {
        // 专家对话：顶部固定身份横幅，与其他普通对话区分
        if viewModel.expert.id != ExpertCatalog.general.id {
            ExpertBanner(expert: viewModel.expert)
        }
        TaskControls(viewModel: viewModel)
        // 云端会员用量提示（仅「偏高 / 超限」两档出现，正常时不渲染）
        UsageNoticeBar()
            .overlay(alignment: .bottomTrailing) {
                // P0-10：版本号——标题右下方小字，用于确认设备上的构建版本
                Text(AppConfig.displayVersion)
                    .font(.system(size: 10, weight: .medium).monospaced())
                    .foregroundStyle(Color.white.opacity(0.28))
                    .padding(.trailing, 14)
                    .padding(.bottom, 2)
                    .allowsHitTesting(false)
            }
    }

    /// 错误区（10-24）：有结构化信封 → 带真实动作的卡片；否则保持原来的纯文本错误。
    /// 两者不会同时出现，避免同一句话重复两遍。
    @ViewBuilder
    private var errorSection: some View {
        if let env = viewModel.errorEnvelope {
            RecoverableErrorView(envelope: env, busy: viewModel.isRetryingSeries) { action in
                switch action {
                case "renew", "view_quota":
                    showMembership = true
                case "relogin":
                    Task { await HostedAccount.shared.handleSessionFailure("登录状态已更新，请重新登录") }
                default:
                    viewModel.handleErrorAction(action)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 6)
        } else if let error = viewModel.errorMessage {
            Text(error)
                .font(.footnote)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 4)
        }
    }

    /// 消息区：消息列表 + 追问建议 + 滚动控制 + 研究摘要 + 错误与重试
    @ViewBuilder
    private var messageSection: some View {
        ScrollViewReader { proxy in
        ScrollView {
                LazyVStack(spacing: 0) {
                    if displayMessages.isEmpty {
                        EmptyStateView(expert: viewModel.expert)
                    }
                    ForEach(displayMessages, id: \.id) { message in
                        Group {
                            if message.id == viewModel.streamingMessageId {
                                StreamingMessageRow(message: message, buffer: viewModel.replyBuffer,
                                                    files: viewModel.files(for: message), onPreview: { previewFile = $0 },
                                                    isReasoning: viewModel.isReasoning)
                            } else {
                                MessageRow(message: message, files: viewModel.files(for: message), onPreview: { previewFile = $0 },
                                           isLastAssistant: message.role == "assistant" && message.id == displayMessages.last?.id,
                                           onRegenerate: viewModel.canRegenerateLast ? { viewModel.regenerateLastReply() } : nil)
                            }
                        }
                        .id(message.id)
                        .contextMenu {
                            // P0-4：长按自己的消息可编辑并从该点重新生成
                            if message.role == "user", !viewModel.isStreaming {
                                Button { editTarget = message } label: {
                                    Label("编辑并重新发送", systemImage: "pencil")
                                }
                            }
                        }
                    }
                    // P0-50 ChatGPT 式生图加载：工具执行期间在消息流里显示 shimmer 占位行
                    if let job = viewModel.pendingImage {
                        ImageGeneratingRow(title: job)
                    }
                    if !viewModel.isStreaming, viewModel.streamingMessageId == nil,
                       !viewModel.suggestedFollowUps.isEmpty {
                        // ChatGPT 式追问建议：回答结束后给 2-3 条可点的后续问题
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(viewModel.suggestedFollowUps, id: \.self) { suggestion in
                                    Button { viewModel.sendFollowUp(suggestion) } label: {
                                        Text(suggestion)
                                            .font(.footnote)
                                            .padding(.horizontal, 12)
                                            .frame(minHeight: 36)
                                            .background(theme.surface, in: Capsule())
                                            .overlay(Capsule().stroke(theme.border, lineWidth: 0.8))
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("follow-up")
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                        .accessibilityIdentifier("follow-ups")
                    }

                    if let status = viewModel.statusText {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(status)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .frame(maxWidth: 760)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                    }

                    // 10-23 底部锚点：所有贴底滚动都滚到这里——它保证"滚到内容真正末尾"，
                    // 而不是停在最后一条消息（其后还有生图占位、追问建议、状态条）
                    Color.clear.frame(height: 1).id("bottom-anchor")
                }
                .padding(.vertical, 12)
                .scrollTargetLayout()
            }
            // P0-11 一次性滚动：消费即清空——布局变化（含键盘动画）不再重复锚定，杜绝过冲顶空
            .onChange(of: pendingScrollTarget) { _, target in
                guard let target else { return }
                let animated = pendingScrollAnimated
                pendingScrollTarget = nil
                DispatchQueue.main.async {
                    if animated {
                        withAnimation(.easeOut(duration: 0.22)) { proxy.scrollTo(target, anchor: .bottom) }
                    } else {
                        proxy.scrollTo(target, anchor: .bottom)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            // P0-17 成熟配方：底部为默认锚点——键盘弹出/收起引起的视口变化由系统自动贴底
            .defaultScrollAnchor(.bottom)
            .onAppear { requestScrollToBottom() }
            .accessibilityIdentifier("chat-scroll")
            // 用户手势：下拉查看历史即暂停跟随
            .simultaneousGesture(DragGesture(minimumDistance: 5).onChanged { value in
                if abs(value.translation.height) > abs(value.translation.width), value.translation.height > 5 { followOutput = false }
            })
            .onChange(of: displayMessages.count) { _, _ in
                guard followOutput else { return }
                requestScrollToBottom()
            }
            .onChange(of: viewModel.isStreaming) { _, streaming in
                // 发送（开始流式）与回答结束两个节点都强制回到底部
                if streaming {
                    followOutput = true
                    // 新一轮开始：上一轮的错误按钮/重试上下文不再适用
                    viewModel.errorEnvelope = nil
                    viewModel.pendingSeriesRetry = nil
                }
                if followOutput { requestScrollToBottom() }
            }
            .onReceive(viewModel.replyBuffer.$text) { _ in
                // 10-23 修复：把 trailing debounce 改成节流/合并（coalescing）。
                // 高频 token 不再等"静默窗口"，而是每 60ms 最多滚一次——长回答期间持续贴底，
                // 同时避免每个 token 都触发 scrollTo 造成布局抖动。
                guard followOutput else { return }
                guard scrollClock.pending == nil else { return }
                scrollClock.pending = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    scrollClock.pending = nil
                    guard followOutput else { return }
                    requestScrollToBottom()
                }
            }
            .onDisappear { scrollClock.pending?.cancel(); scrollClock.pending = nil }
        }
            .overlay(alignment: .bottomTrailing) {
                if !followOutput {
                    Button {
                        followOutput = true
                        requestScrollToBottom(animated: true)
                    } label: {
                        Label("回到最新", systemImage: "arrow.down")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(theme.accent)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .liquidGlassCompat(Capsule(), elevated: true)
                    }
                    .buttonStyle(.plain)
                    .padding()
                    .accessibilityIdentifier("scroll-to-bottom")
                }
            }

            // P0-5 专家开场提示：空会话时展示在输入框上方，点击填充（可编辑再发送）
            if displayMessages.isEmpty, viewModel.streamingMessageId == nil {
                let starters = ExpertCatalog.starters(for: viewModel.expert)
                if !starters.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(starters, id: \.label) { starter in
                                Button {
                                    viewModel.inputText = starter.content
                                } label: {
                                    Text(starter.label)
                                        .font(.footnote)
                                        .padding(.horizontal, 12)
                                        .frame(minHeight: 36)
                                        .background(theme.surface, in: Capsule())
                                        .overlay(Capsule().stroke(theme.border, lineWidth: 0.8))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("开场提示：" + starter.label)
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
            }

            if let summary = viewModel.researchSummary {
                Text(summary + " · 来源仍需原文核对").font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 20).padding(.vertical, 5)
                    .accessibilityIdentifier("research-summary")
            }
            errorSection

            if let note = viewModel.partialSuccessMessage {
                // 10-23 P0：产物已保存但说明未完成——橙色提示，不显示红错、不提供"重新生成"，
                // 只给一个"补充说明"入口，避免用户重跑整轮再花一次生图费用。
                VStack(alignment: .leading, spacing: 8) {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                    Button {
                        viewModel.sendFollowUp("请只补充说明刚才生成的图片，不要重新生成图片。")
                    } label: {
                        Label("让 AI 补充说明", systemImage: "text.bubble")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("retry-summary")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 6)
            }

            if viewModel.canRetryReply {
                Button { viewModel.retryReply() } label: {
                    Label("重新生成本次回复", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("retry-reply")
                .padding(.bottom, 6)
            }
    }
}

/// P0-50 ChatGPT 式生图加载动效：占位画布 + shimmer 扫光 + 阶段文案（按经过时间推进）。
/// 目标：生图约需 40-100 秒，让用户明确"正在画、画到哪了"，而不是面对静止的等待。
struct ImageGeneratingRow: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    @State private var shimmerOffset: CGFloat = -220
    @State private var elapsed: Int = 0

    private var stageText: String {
        // P0-70 文案云端可配（管理台 IMGPROG_* 即改即生效；未配置时用内置默认值）
        switch elapsed {
        case ..<15: return HostedAccount.cachedImgStage1
        case ..<45: return HostedAccount.cachedImgStage2
        default: return HostedAccount.cachedImgStage3
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(theme.surface.opacity(0.6))
                    .frame(width: 260, height: 340)
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(theme.border, lineWidth: 0.8))
                // shimmer 扫光（reduceMotion 时禁用动画，保持静态占位）
                LinearGradient(colors: [.clear, theme.accent.opacity(0.14), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .frame(width: 260, height: 340)
                    .offset(x: shimmerOffset)
                    .animation(reduceMotion ? nil : .linear(duration: 1.6).repeatForever(autoreverses: false), value: shimmerOffset)
                VStack(spacing: 10) {
                    Image(systemName: "paintbrush.pointed.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(theme.accent)
                    Text("正在绘制「\(title)」")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(stageText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(HostedAccount.cachedImgEta)   // P0-70 云端可配
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 18)
            }
        }
        .padding(.vertical, 6)
        .onAppear {
            shimmerOffset = 220
            // 阶段文案按真实经过时间推进（5 秒一档）
            Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    elapsed += 5
                }
            }
        }
        .accessibilityLabel("正在生成图片：\(title)")
    }
}

/// P0-4 编辑重发编辑器：弹出半屏 TextEditor 修改历史消息文本后重新发送
private struct EditResendSheet: View {
    let initial: String
    let onResend: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(initial: String, onResend: @escaping (String) -> Void) {
        self.initial = initial
        self.onResend = onResend
        _text = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .padding(.horizontal)
                .navigationTitle("编辑并重新发送")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("重新发送") {
                            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !t.isEmpty else { return }
                            dismiss()
                            onResend(t)
                        }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
}

/// 流式消息行：外层仍是 MessageRow，直接展示当前已收到的完整 buffer.text。
/// 10-23 取消逐字符打字机：配合 MarkdownView 的增量解析，直接渲染完整文本，
/// 避免每 18–24ms 重排整段 Markdown 造成的滚动抖动、布局跳变和主线程压力。
private struct StreamingMessageRow: View {
    let message: Message
    @ObservedObject var buffer: StreamingReplyBuffer
    let files: [StoredFile]
    let onPreview: (StoredFile) -> Void
    /// P0-68 深度思考中状态（由调用方传入）
    var isReasoning: Bool = false

    var body: some View {
        MessageRow(message: message, streamingText: buffer.text, files: files, onPreview: onPreview, isReasoning: isReasoning, isLive: true)   // P0-68 / 10-23 P0
    }
}

/// 空状态：展示这位专家的技能包（方法论 + 工具）
struct EmptyStateView: View {
    @Environment(\.appTheme) private var theme
    let expert: Expert

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 90)
            // P0-26 空态大号图标：emoji 优先，回退首字
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(ExpertRow.tint(for: expert.id))
                if let emoji = expert.emoji, !emoji.isEmpty {
                    Text(emoji).font(.system(size: 40))
                } else {
                    Text(String(expert.name.prefix(1)))
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 72, height: 72)
            Text(expert.name)
                .font(.title2.bold())
            Text(expert.subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                    Text(expert.skill.framework)
                        .font(.footnote.weight(.medium))
                }
                HStack(spacing: 6) {
                    ForEach(expert.skill.tools, id: \.self) { tool in
                        HStack(spacing: 3) {
                            Image(systemName: tool.symbol).font(.system(size: 10))
                            Text(tool.displayName).font(.system(size: 11))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(theme.surface, in: Capsule())
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(theme.cardPadding)
            .frame(maxWidth: 420, alignment: .leading)
            .background(theme.surface.opacity(0.6),
                        in: RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))

            Label("输入任务，或上传资料；需要实时事实时选择联网研究", systemImage: "text.bubble")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 90)
        }
        .frame(maxWidth: .infinity)
    }
}

/// 任务控制条选项枚举（研究模式 / 回答风格）
private enum TaskOption: String, Identifiable {
    case research, style
    var id: String { rawValue }
}
/// 任务控制条：展示"自动调度"状态（P0-12 起思考深度与证据方式由系统调度，
/// 不再暴露给用户选择；allowsHitTesting(false) 纯展示不可点）。
private struct TaskControls: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.appTheme) private var theme
    @State private var option: TaskOption?
    /// P1-1 回答速度：极速=关闭深度思考（首字快、省 token）；深度=默认思考
    @AppStorage("bossai.replyFast") private var replyFast = false
    var body: some View {
        HStack(spacing: 8) {
            // P0-12：思考深度与证据方式由系统自动调度（服务端用轻量模型逐轮判定），
            // 不再交给用户选择——成熟产品（豆包/DeepSeek/Kimi）均不暴露此类开关。
            Label("自动调度", systemImage: "wand.and.stars")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(theme.surface, in: Capsule())
                .overlay(Capsule().stroke(theme.border, lineWidth: 0.5))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .background(theme.surface)
        .allowsHitTesting(false)
    }
}
/// 任务选项选择页（研究模式 / 回答风格的 List 选择器）
private struct TaskOptionsSheet: View {
    @ObservedObject var viewModel: ChatViewModel
    let option: TaskOption
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if option == .research {
                    Section {
                        ForEach(ResearchMode.allCases) { mode in
                            Button {
                                viewModel.researchMode = mode
                                dismiss()
                            } label: {
                                row(mode.label, selected: viewModel.researchMode == mode)
                            }
                            .accessibilityLabel(mode.label)
                            .accessibilityIdentifier("research-choice-" + mode.rawValue)
                        }
                    } footer: {
                        Text("仅用现有资料关闭网页检索，仍通过所选模型API处理资料；不代表完全离线。")
                    }
                } else {
                    Section {
                        ForEach(AnswerStyle.allCases) { style in
                            Button {
                                viewModel.setAnswerStyle(style)
                                dismiss()
                            } label: {
                                row(style.label, selected: viewModel.answerStyle == style)
                            }
                            .accessibilityLabel(style.label)
                            .accessibilityIdentifier("style-choice-" + style.rawValue)
                        }
                    } footer: {
                        Text("两种深度都保留要求的对象、字段、证据和未核实项。")
                    }
                }
            }
            .navigationTitle(option == .research ? "选择证据方式" : "选择回答深度")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
    /// 选项行的通用样式（选中打勾，44pt 最小高度保证触控面积）
    private func row(_ title: String, selected: Bool) -> some View {
        HStack {
            Text(title).foregroundStyle(.primary)
            Spacer()
            if selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
        }.frame(minHeight: 44).contentShape(Rectangle())
    }
}
