import SwiftUI
import SwiftData
import UIKit
import Combine

// ─────────────────────────────────────────────────────────────────────────────
// 文件职责：App 主界面骨架——ChatGPT 式左右分栏（可折叠侧栏 + 详情区），
// 以及侧栏内的专家列表、对话列表、额度组件、欢迎工作台、新建对话与隐藏设置门禁。
//
// 在整个 App 中的角色：
//   App 根视图直接挂载 MainView；detailContent 按 containerKey 路由到
//   资料库 / 草稿对话 / 已有会话 / 欢迎页四种状态。
//
// 关键设计决策：
//   1. containerKey 与 selectedConversationId 分离：草稿建出会话时只更新侧栏
//      高亮、不换容器 key，保证正在流式输出的 ChatViewModel 不被销毁重建；
//   2. 草稿唯一 key（P0-19 防呆）：每次"选择专家新建"都拼入随机 UUID，
//      VM 不被复用，杜绝上一次草稿/模板残留进输入框；
//   3. ForEach enumerated 防呆：专家列表用 Array(enumerated()) + id: \.element.id，
//      索引只用于画分隔线，视图身份始终绑定专家 id，不随顺序漂移；
//   4. monogram 徽章 + 稳定配色（P0-23）：专家头像用首字徽章，
//      颜色按 id 散列到固定色板，列表/横幅/任何入口永远同色；
//   5. 数据隔离（P0-16）：侧栏对话列表只显示当前登录账号名下的会话。
// ─────────────────────────────────────────────────────────────────────────────

/// 主界面：ChatGPT 风格侧栏（可折叠专家团 + 对话列表 + 资料库）+ 对话区
struct MainView: View {
    @Environment(\.appTheme) private var theme
    @EnvironmentObject var credentials: CredentialStore
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]

    /// 侧栏高亮用
    @State private var selectedConversationId: UUID?
    /// 详情区当前挂载的身份："draft-<expertId>" 或 "conv-<uuid>"。
    /// 与 selectedConversationId 分开，避免草稿建出会话时把正在流式输出的 VM 换掉。
    @State private var containerKey: String?
    @State private var showLibrary = false
    @State private var draftPrompt = ""
    @State private var draftConversationID: UUID?
    /// P0-47 方案 A：草稿态预置研究模式（侧栏「深度研究」入口用）
    @State private var draftResearchMode: ResearchMode?
    @State private var providerTask: Task<Void, Never>?
    @State private var showNewChat = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var showPinEntry = false
    @State private var showHiddenSettings = false
    // P0-46 强制升级：云端下发 minVersion，本地低于时提示更新
    @State private var showUpdateAlert = false
    @State private var updateMessage = ""
    @State private var updateChecked = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selectedConversationId: Binding(
                get: { selectedConversationId },
                set: { newValue in
                    selectedConversationId = newValue
                    if let id = newValue {
                        containerKey = "conv-\(id.uuidString)"
                        showLibrary = false
                    }
                }
            ),
            showLibrary: $showLibrary,
            onNewChat: { showNewChat = true },
            onOpenExpert: { expert in openExpert(expert) },
            onDeleteConversation: { conv in delete(conv) },
            onOpenLibrary: {
                selectedConversationId = nil
                containerKey = nil
                showLibrary = true
            },
            onHiddenSettings: { showPinEntry = true },
            onOpenResearch: {
                // P0-47 方案 A「深度研究」入口：新开草稿并预置联网研究模式
                startNewDraft(ExpertCatalog.find("general"), researchMode: .online)
            })
        } detail: {
            detailContent
        }
        .navigationSplitViewStyle(.balanced)
        .environmentObject(credentials)
        .task {
            ensureProvidersDetected()
            // P0-26 SaaS 化：登录态下拉取云端专家目录（人设/工具/开场白/侧栏文案在线可改）
            await RemoteCatalogService.refreshIfPossible()
        }
        .onReceive(NotificationCenter.default.publisher(for: .bossAIKeysChanged)) { _ in
            ensureProvidersDetected()
        }
        .sheet(isPresented: $showNewChat) {
            NewChatSheet(
                onSelectExpert: { expert in startNewDraft(expert) },
                onOpenConversation: { conversation in
                    showLibrary = false
                    selectedConversationId = conversation.id
                    containerKey = "conv-\(conversation.id.uuidString)"
                }
            )
        }
        .sheet(isPresented: $showPinEntry) {
            HiddenPinGate {
                // 先收起密码页，再弹出设置页（避免两个 sheet 同时切换）
                showPinEntry = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    showHiddenSettings = true
                }
            }
        }
        .sheet(isPresented: $showHiddenSettings) {
            SetupView(isModal: true)
        }
        // P0-46 强制升级检查：/me 拉取到 appUpdate 后比对版本，低于 minVersion 弹提示。
        // 只在会员模式生效（自备 Key 模式无服务端版本控制）。
        .onReceive(HostedAccount.shared.$appUpdate) { update in
            guard HostedAccount.isHostedActive, !updateChecked,
                  let minVersion = update["minVersion"] as? String, !minVersion.isEmpty else { return }
            updateChecked = true
            if AppConfig.isVersion(AppConfig.appVersion, lowerThan: minVersion) {
                updateMessage = (update["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? "当前版本过低，请更新到最新版以获得最佳体验。"
                showUpdateAlert = true
            }
        }
        .alert("发现新版本", isPresented: $showUpdateAlert) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(updateMessage)
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if showLibrary {
            LibraryView(onOpenConversation: { id in
                showLibrary = false
                selectedConversationId = id
                containerKey = "conv-\(id.uuidString)"
            })
        } else if let key = containerKey {
            if key.hasPrefix("draft-") {
                let expertId = String(key.dropFirst("draft-".count)).components(separatedBy: "~")[0]
                ChatContainerView(conversation: nil,
                                  expert: ExpertCatalog.find(expertId),
                                  onConversationCreated: { created in
                                      // 只更新侧栏高亮，容器不换 —— 保持同一个 VM 继续流式输出
                                      selectedConversationId = created.id
                                      draftConversationID = created.id
                                  }, initialText: draftPrompt,
                                  initialResearchMode: draftResearchMode)
                    .id(key)
            } else {
                let raw = String(key.dropFirst("conv-".count))
                let uuid = UUID(uuidString: raw)
                // P0-45 打开兜底：优先按归属匹配；老数据归属未回填等原因找不到时，
                // 忽略归属再找一次（打开动作本身会触发归属回填）；两者都找不到才显示欢迎页。
                // 此前严格归属过滤失败时静默显示欢迎页——用户感知为"历史对话打不开/记录丢了"。
                let scopedConv = uuid.flatMap { id in
                    conversations.first(where: { $0.id == id && $0.ownerKey == HostedAccount.scopeKey })
                }
                // 10-22 P1 隔离修复：删掉 anyConv 兜底——它会打开另一个账号的会话（跨账号数据泄露）。
                if let conv = scopedConv {
                    ChatContainerView(conversation: conv, expert: conv.expert)
                        .id(key)
                } else {
                    WelcomeView(onNewChat: { showNewChat = true }, onTask: { expert, prompt in
                        draftPrompt = prompt; startNewDraft(expert, keepPrompt: true)
                    })
                }
            }
        } else {
            WelcomeView(onNewChat: { showNewChat = true }, onTask: { expert, prompt in
                        draftPrompt = prompt; startNewDraft(expert, keepPrompt: true)
                    })
        }
    }

    private func startNewDraft(_ expert: Expert, keepPrompt: Bool = false, researchMode: ResearchMode? = nil) {
        if !keepPrompt { draftPrompt = "" }
        draftResearchMode = researchMode
        showLibrary = false
        selectedConversationId = nil
        // Unique key preserves separate drafts; expert ID remains the prefix decoded by detailContent.
        containerKey = "draft-\(expert.id)~\(UUID().uuidString)"
        columnVisibility = .detailOnly
    }

    /// 点专家：已有该专家的对话就打开；没有就进草稿态（发第一条消息时才落库）
    private func openExpert(_ expert: Expert) {
        draftPrompt = ""
        showLibrary = false
        if let existing = conversations.first(where: { $0.expertId == expert.id && $0.ownerKey == HostedAccount.scopeKey }) {
            selectedConversationId = existing.id
            containerKey = "conv-\(existing.id.uuidString)"
        } else {
            // P0-19 防呆：每次"选择专家新建"都生成全新草稿（唯一 key + 清空预填）。
            // 此前用固定 key "draft-\(expert.id)"，VM 被复用会把上一次任务模板/草稿残留进输入框。
            startNewDraft(expert)
        }
        columnVisibility = .detailOnly
    }

    private func delete(_ conv: Conversation) {
        if selectedConversationId == conv.id { selectedConversationId = nil }
        if containerKey == "conv-\(conv.id.uuidString)" || draftConversationID == conv.id { containerKey = nil; draftConversationID = nil }
        // 10-22 同步墓碑：改为软删除，让删除动作能同步出去（否则别的设备会"复活"这条对话）
        conv.isDeleted = true
        conv.updatedAt = Date()
        try? modelContext.save()
    }

    /// 首次启动：用内置 Key 自动识别服务商（无需任何手动配置）
    private func ensureProvidersDetected() {
        guard !ProcessInfo.processInfo.arguments.contains("--render-fixture"),
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              NSClassFromString("XCTestCase") == nil else { return }
        guard !ProviderCatalog.providersDetected else { return }
        providerTask?.cancel()
        let capturedChatKey = credentials.chatKey
        let capturedImageKey = credentials.imageKey
        providerTask = Task {
            if let ck = capturedChatKey,
               let p = await ProviderDetector.detectChat(key: ck) {
                guard !Task.isCancelled, credentials.chatKey == capturedChatKey else { return }
                ProviderCatalog.saveChatProvider(p.id)
            }
            if let ik = capturedImageKey,
               let p = await ProviderDetector.detectImage(key: ik) {
                guard !Task.isCancelled, credentials.imageKey == capturedImageKey else { return }
                ProviderCatalog.saveImageProvider(p.id)
            }
        }
    }
}

// MARK: - 侧栏

/// 左侧分栏：资料库入口、可折叠专家团（独立滚动框）、对话搜索列表、
/// 底部额度组件与新建按钮、顶部品牌区（含连点隐藏入口）。
struct SidebarView: View {
    @Environment(\.appTheme) private var theme
    @Binding var selectedConversationId: UUID?
    @Binding var showLibrary: Bool
    var onNewChat: () -> Void
    var onOpenExpert: (Expert) -> Void = { _ in }
    var onDeleteConversation: (Conversation) -> Void = { _ in }
    var onOpenLibrary: () -> Void = {}
    var onHiddenSettings: () -> Void = {}
    // P0-47 方案 A 实装：顶部「深度研究」入口回调（定时任务走侧栏内部身份页 sheet）
    var onOpenResearch: () -> Void = {}

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]

    @State private var expertExpanded = true
    @State private var searchText = ""
    /// P0-47 方案 A：定时任务入口 → 侧栏自己的身份页 sheet（内含定时任务卡）
    @State private var showIdentitySheet = false
    @State private var renaming: Conversation?
    @State private var renameText = ""
    @State private var tapCount = 0
    @State private var lastTapAt = Date.distantPast

    /// 过滤后的对话列表：先按账号隔离，再按关键词匹配标题/专家名/消息正文
    private var filtered: [Conversation] {
        // P0-16 数据隔离：只显示当前登录账号名下的对话（同设备换账号互不可见）
        let scoped = conversations.filter { $0.ownerKey == HostedAccount.scopeKey && !$0.isDeleted }
        let keyword = searchText.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return scoped }
        return scoped.filter { conv in
            if conv.title.localizedCaseInsensitiveContains(keyword) { return true }
            if conv.expert.name.localizedCaseInsensitiveContains(keyword) { return true }
            return conv.messages.contains { $0.text.localizedCaseInsensitiveContains(keyword) }
        }
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            List(selection: $selectedConversationId) {
                // P0-47 方案 A：一级入口三件套（线性简笔图标，与专家列表视觉语言统一）
                Section {
                    Button {
                        // 身份页内含定时任务卡（Pro 3 / Ultra 10），侧栏自己的 sheet 直接打开
                        showIdentitySheet = true
                    } label: {
                        Label { Text("定时任务") } icon: { Image(systemName: "clock") }
                            .foregroundStyle(Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("entry-tasks")

                    Button {
                        onOpenResearch()
                    } label: {
                        Label { Text("深度研究") } icon: { Image(systemName: "magnifyingglass") }
                            .foregroundStyle(Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("entry-research")

                    Button {
                        onOpenLibrary()
                    } label: {
                        Label { Text("资料库") } icon: { Image(systemName: "folder") }
                            .foregroundStyle(showLibrary ? Color.accentColor : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("entry-library")
                }

                // 可折叠的专家团
                Section {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { expertExpanded.toggle() }
                    } label: {
                        HStack {
                            Label("您的专属军师", systemImage: ExpertCatalog.ui.icon)
                            Spacer()
                            Text("\(ExpertCatalog.all.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Image(systemName: expertExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)

                    if expertExpanded {
                        // P0-11 专家顾问区：独立滚动框 + 行分隔线 + 统一内边距（此前布局散乱）
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(ExpertCatalog.all.enumerated()), id: \.element.id) { index, expert in
                                    Button {
                                        onOpenExpert(expert)
                                    } label: {
                                        ExpertRow(expert: expert)
                                            .padding(.vertical, 7)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    if index < ExpertCatalog.all.count - 1 {
                                        Rectangle()
                                            .fill(theme.border.opacity(0.45))
                                            .frame(height: 0.5)
                                            .padding(.leading, 52)
                                    }
                                }
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 8)
                        }
                        .scrollIndicators(.hidden)
                        .frame(maxHeight: 380)
                        .background(theme.surface.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(theme.border.opacity(0.6), lineWidth: 0.5))
                        .padding(.horizontal, 4)
                    }
                }

                Section {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        TextField("搜索对话", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.footnote)
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if filtered.isEmpty {
                        Text(searchText.isEmpty ? "还没有对话，点左下角新建" : "没有匹配的对话")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(filtered, id: \.id) { conv in
                            ConversationRow(conversation: conv)
                                .tag(Optional(conv.id))
                                .contextMenu {
                                    Button {
                                        renaming = conv
                                        renameText = conv.title
                                    } label: {
                                        Label("重命名", systemImage: "pencil")
                                    }
                                    Button(role: .destructive) {
                                        onDeleteConversation(conv)
                                    } label: {
                                        Label("删除对话", systemImage: "trash")
                                    }
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        onDeleteConversation(conv)
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                        }
                    }
                } header: {
                    Text("对话")
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    QuotaSidebarWidget()
                    // P0-47 方案 A：底部"新对话"大胶囊按钮（预览同款渐变胶囊）
                    Button(action: onNewChat) {
                        Label("新对话", systemImage: "plus")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                    }
                    .buttonStyle(.plain)
                    .background(
                        LinearGradient(colors: [theme.accent, theme.accentDeep],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .clipShape(Capsule())
                    .shadow(color: theme.accent.opacity(0.35), radius: 10, y: 4)
                    .padding([.horizontal, .bottom], 12)
                    .accessibilityIdentifier("new-task")
                }
                // 底部区做成玻璃面板：额度环与新建按钮浮在毛玻璃上
                .background(.ultraThinMaterial)
                .overlay(alignment: .top) {
                    Rectangle().fill(theme.border).frame(height: 0.5)
                }
            }
            .safeAreaInset(edge: .top) {
                // P0-11 品牌区：图形 + 名称分层，不透明毛玻璃衬底 + 底部细分隔线。
                // 此前该区域无背景 → 列表滚动时内容透出与标题重叠；现在内容被衬底遮住且被分隔线划清边界。
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(LinearGradient(colors: [theme.accent, theme.accent.opacity(0.65)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 30, height: 30)
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(HostedAccount.cachedAppName).font(.headline.bold())
                        Text("老板的 AI 顾问").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(theme.border).frame(height: 0.5)
                }
                .contentShape(Rectangle())
                .onTapGesture { registerTap() }
                .accessibilityLabel("中防AI")
            }


        }
        .alert("重命名对话", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("对话名称", text: $renameText)
            Button("取消", role: .cancel) { renaming = nil }
            Button("保存") {
                if let conv = renaming {
                    let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    conv.title = name.isEmpty ? conv.expert.name : name
                    try? modelContext.save()
                }
                renaming = nil
            }
        }
        // P0-47 方案 A：「定时任务」入口打开身份页（含定时任务卡）
        .sheet(isPresented: $showIdentitySheet) { IdentitySheet() }
    }

    private func delete(_ conv: Conversation) {
        if selectedConversationId == conv.id { selectedConversationId = nil }
        // 10-22 同步墓碑：改为软删除，让删除动作能同步出去（否则别的设备会"复活"这条对话）
        conv.isDeleted = true
        conv.updatedAt = Date()
        try? modelContext.save()
    }

    /// 隐藏入口：连点标题 N 次，每次间隔小于 0.8 秒
    private func registerTap() {
        let now = Date()
        if now.timeIntervalSince(lastTapAt) > 0.8 { tapCount = 0 }
        lastTapAt = now
        tapCount += 1
        guard tapCount >= AppConfig.hiddenTriggerTaps else { return }
        tapCount = 0
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onHiddenSettings()
    }
}

/// 侧栏额度组件：
/// - 云端账号模式：**统一额度池**单环（对话 + 作图 合并计费，由服务端统计并下发），
///   对齐 ChatGPT 式的单一用量概念；低于 20% 环自动转红警示
/// - 手动 Key 模式：本地双环（对话 / 生图），额度设为 0（不限）时自动隐藏对应环
struct QuotaSidebarWidget: View {
    @Environment(\.appTheme) private var theme
    @State private var tick = 0
    @State private var showIdentity = false
    @State private var showMembership = false
    private let refresh = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if HostedAccount.isHostedActive && HostedAccount.hasToken {
                hostedTierCard   // P0-19 方案 A（用户选定）：三环并排
            } else {
                let chat = BudgetTracker.chatRemainingPercent()
                let image = BudgetTracker.imageRemainingPercent()
                if chat != nil || image != nil {
                    HStack(spacing: 22) {
                        if let chat {
                            LiquidGlassRing(label: "对话", percent: chat,
                                            tint: theme.accentSecondary, glow: theme.glow)
                        }
                        if let image {
                            // 生图池固定用琥珀色，保证与主题色可区分
                            LiquidGlassRing(label: "生图", percent: image,
                                            tint: Color(red: 0.984, green: 0.749, blue: 0.141),
                                            glow: Color.orange.opacity(0.42))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }
            }
        }
        .onReceive(refresh) { _ in tick += 1 }
        .sheet(isPresented: $showIdentity) { IdentitySheet() }
        .sheet(isPresented: $showMembership) { MembershipView() }
        .accessibilityElement(children: .contain)
    }

    /// P0-19 方案 A：档位徽章 + 剩余天数 + 三环并排 + 身份设置/升级入口
    @ViewBuilder
    private var hostedTierCard: some View {
        VStack(spacing: 10) {
            HStack {
                Text("👑 " + HostedAccount.cachedTierName)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(theme.accent.opacity(0.18), in: Capsule())
                    .foregroundStyle(theme.accent)
                Spacer()
                if let days = HostedAccount.cachedDaysLeft {
                    Text(days >= 0 ? "剩 \(days) 天" : "已到期")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            // 10-22 用户要求：底部不再显示额度金额/百分比，改为「会员到期时间」
            MembershipExpiryRing(daysLeft: HostedAccount.cachedDaysLeft,
                                 until: HostedAccount.cachedMemberUntil)
            HStack(spacing: 8) {
                Button { showIdentity = true } label: {
                    Label("身份设置", systemImage: "gearshape")
                        .font(.caption2.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.1), lineWidth: 1))
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sidebar-identity")
                Button { showMembership = true } label: {
                    Text("升级 / 续费")
                        .font(.caption2.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(theme.accentDeepGradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .foregroundStyle(.white)
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sidebar-upgrade")
            }
        }
        .padding(12)
        .background(
            LinearGradient(colors: [theme.accent.opacity(0.10), theme.accentSecondary.opacity(0.06)],
                           startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }
}

/// 会员有效期环：环心显示剩余天数，环按「剩余/30」比例收缩，下方标注到期日期。
/// 10-22 用户要求用「会员到期」替代原额度金额展示。
struct MembershipExpiryRing: View {
    @Environment(\.appTheme) private var theme
    let daysLeft: Int?
    let until: Date?

    private var days: Int { max(0, daysLeft ?? 0) }
    private var progress: CGFloat {
        // 以 30 天为一个周期估算环进度（到期时间不由本地计算，仅作视觉参考）
        min(1, max(0.02, CGFloat(days) / 30.0))
    }
    private var expired: Bool { (daysLeft ?? 0) <= 0 }
    private var expiryText: String {
        guard let until else { return expired ? "已到期" : "—" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: until) + " 到期"
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.08), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(expired ? Color.red.opacity(0.8) : theme.accent,
                            style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text(expired ? "0" : "\(days)")
                        .font(.system(size: 15, weight: .heavy, design: .rounded).monospacedDigit())
                    Text("天").font(.system(size: 8)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 64, height: 64)
            Text("会员有效期").font(.caption2).foregroundStyle(.secondary)
            Text(expiryText)
                .font(.system(size: 8.5)).foregroundStyle(.tertiary)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel(expired ? "会员已到期" : "会员剩余 \(days) 天，\(expiryText)")
    }
}

/// P0-19 单个额度环：环心百分比 + 标签 + 距重置倒计时（不出现金额）
struct QuotaSidebarRing: View {
    let pct: Double
    let tint: Color
    let label: String
    let resetAt: Date?

    private var clamped: Double { min(100, max(0, pct)) }
    private var low: Bool { clamped <= 20 }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.08), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: CGFloat(max(0.02, clamped / 100)))
                    .stroke(low ? Color.orange : tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text("\(Int(clamped.rounded()))%")
                        .font(.system(size: 13, weight: .heavy, design: .rounded).monospacedDigit())
                    Text("剩余").font(.system(size: 8)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 64, height: 64)
            Text(label).font(.caption2).foregroundStyle(.secondary)
            if let resetAt {
                Text(MembershipQuotaRow.countdown(to: resetAt))
                    .font(.system(size: 8.5)).foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// 液态玻璃环形进度：毛玻璃圆盘 + 斜向反光 + 高光描边 + 渐变进度环 + 环心百分比。
/// 低于 20% 自动转为红色警示。
struct LiquidGlassRing: View {
    let label: String
    let percent: Double
    var tint: Color = .blue
    var glow: Color = .blue

    private var low: Bool { percent < 20 }
    private var lineWidth: CGFloat { 5 }
    private var inset: CGFloat { lineWidth / 2 + 2 }
    /// 进度环配色：正常态用 tint 渐变，低于 20% 用红色
    private var ringGradient: AngularGradient {
        let base = low ? Color.red : tint
        return AngularGradient(colors: [base.opacity(0.55), base], center: .center)
    }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                // ① 玻璃圆盘：毛玻璃 + 一层斜向反光，形成「液态」立体感
                Circle().fill(.ultraThinMaterial)
                Circle().fill(GlassDesign.surfaceSheen)
                // ② 轨道
                Circle().inset(by: inset)
                    .stroke(Color.white.opacity(0.12), lineWidth: lineWidth)
                // ③ 进度环：渐变 + 圆头 + 辉光
                Circle().inset(by: inset)
                    .trim(from: 0, to: max(0.015, percent / 100))
                    .stroke(ringGradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: low ? Color.red.opacity(0.55) : glow, radius: 6)
                // ④ 高光描边：顶部亮、底部暗，模拟玻璃边缘折射
                Circle().strokeBorder(GlassDesign.strokeHighlight, lineWidth: 1)
                // ⑤ 环心百分比
                Text("\(Int(percent.rounded()))%")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(low ? Color.red : Color.primary)
            }
            .frame(width: GlassDesign.ringSize, height: GlassDesign.ringSize)
            .shadow(color: .black.opacity(0.28), radius: 10, x: 0, y: 4)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityLabel("\(label)额度剩余 \(Int(percent.rounded()))%")
    }
}

/// 侧栏专家行：monogram 徽章 + 名称 + 一句话介绍
struct ExpertRow: View {
    @Environment(\.appTheme) private var theme
    let expert: Expert

    var body: some View {
        HStack(spacing: 10) {
            // P0-47 简笔风图标（方案 A 实装）：SF Symbol 线性描边（去 .fill 变体）+ 低饱和底，
            // 替代卡通 emoji——与设计预览一致；symbol 缺失时才回退 emoji/首字徽章。
            // 固定 frame + 居中 = 任何图标形态下都绝对对齐（P0-23 结论保留）。
            // 10-22 用户要求：取消每位专家的独立图标，统一为品牌图标的黑白简笔画（线性描边、无底色）
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .center)
            VStack(alignment: .leading, spacing: 1) {
                Text(expert.name)
                    .font(.subheadline)
                Text(expert.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    /// 简笔线性图标：把 SF Symbol 的 .fill 变体转成描边风格（与方案 A 简笔预览一致）。
    /// 云端 symbol 可随时调整——换图标不出包（专家目录云端下发）。
    static func lineSymbol(for expert: Expert) -> String {
        let base = expert.symbol.isEmpty ? "bubble.left.and.bubble.right.fill" : expert.symbol
        return base.replacingOccurrences(of: ".fill", with: "")
    }

    /// 稳定配色：按专家 id 做字符和散列映射到固定色板（8 色循环），
    /// 不依赖随机数——同一专家在列表、横幅、任何入口颜色都一致。
    static func tint(for id: String) -> Color {
        let palette: [Color] = [.blue, .teal, .indigo, .purple, .pink, .orange, .red, .green]
        let hash = id.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[abs(hash) % palette.count]
    }
}

/// 侧栏单条对话行：图标 + 标题 + 最后一条消息预览 + 专家名胶囊
struct ConversationRow: View {
    @Environment(\.appTheme) private var theme
    let conversation: Conversation

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: conversation.expert.symbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(conversation.title)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(preview)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(conversation.expert.name)
                .font(.system(size: 10))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(.tertiarySystemFill), in: Capsule())
                .foregroundStyle(.secondary)
        }
    }

    /// 预览文案：取最新一条消息的文字；图片/文件分别用占位符；无消息给兜底文案
    private var preview: String {
        guard let last = conversation.messages.max(by: { $0.createdAt < $1.createdAt }) else {
            return "暂无消息"
        }
        if !last.text.isEmpty { return last.text }
        if last.imageData != nil { return "[图片]" }
        if !last.attachmentIds.isEmpty { return "[文件]" }
        return "暂无消息"
    }
}

// MARK: - 液态玻璃悬浮按钮

/// 液态玻璃风格胶囊按钮：超薄材质 + 高光渐变描边 + 柔和投影
struct LiquidGlassButton: View {
    @Environment(\.appTheme) private var theme
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 13)
            .foregroundStyle(Color.primary)
            .background {
                ZStack {
                    Capsule(style: .continuous).fill(.ultraThinMaterial)
                    Capsule(style: .continuous)
                        .fill(LinearGradient(
                            colors: [Color.white.opacity(0.42), Color.white.opacity(0.06), Color.white.opacity(0.22)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                }
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(LinearGradient(
                        colors: [Color.white.opacity(0.85), Color.white.opacity(0.12), Color.white.opacity(0.5)],
                        startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            }
            .clipShape(Capsule(style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 7)
            .shadow(color: .black.opacity(0.06), radius: 2, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

// MARK: - 欢迎页

/// 欢迎工作台：无选中会话时的详情页——任务卡片（查最新信息/做决策/分析资料）
/// 与专家协作卡片网格，点击后带预填提示词进入草稿对话。
struct WelcomeView: View {
    @Environment(\.appTheme) private var theme
    var onNewChat: () -> Void
    var onTask: (Expert, String) -> Void = { _, _ in }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack {
                    Label("中防AI 工作台", systemImage: "square.grid.2x2.fill").font(.headline).foregroundStyle(theme.accent)
                    Spacer()
                    Button("新任务", systemImage: "plus", action: onNewChat).buttonStyle(.bordered)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("把问题变成可以行动的答案").font(.largeTitle.bold()).fontDesign(theme.headingDesign).fixedSize(horizontal: false, vertical: true)
                    Text("提出任务，核对证据，带走成果。").font(.title3).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 14)], spacing: 14) {
                    taskCard("查最新信息", symbol: "globe", detail: "产品、竞品、行业动态与价格", expert: ExpertCatalog.general,
                             prompt: "", id: "task-research")   // P0-19：通用对话不预填模板（用户要求）
                    taskCard("做一项决策", symbol: "chart.bar.xaxis", detail: "方案比较、投入产出与行动步骤", expert: ExpertCatalog.experts.first ?? ExpertCatalog.general,
                             prompt: "请帮我比较方案并做决策。背景：\n备选方案：\n目标：\n预算与时间：\n已知数据：\n请区分事实与假设，列清计算依据、风险和下一步。", id: "task-decision")
                    taskCard("分析现有资料", symbol: "doc.text.magnifyingglass", detail: "上传资料、提炼重点与待确认项", expert: ExpertCatalog.general,
                             prompt: "", id: "task-documents")   // P0-19：通用对话不预填模板
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("专家协作").font(.title2.bold())
                    Text("选择任务方向；计算、检索与交付工具按实际技能配置执行。").font(.subheadline).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
                        ForEach(ExpertCatalog.all) { expert in
                            Button { onTask(expert, "") } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: expert.symbol)
                                        .resizable().scaledToFit()
                                        .frame(width: 15, height: 15)
                                        .foregroundStyle(theme.accent)
                                        .frame(width: 26, height: 26)
                                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(expert.name).font(.headline).foregroundStyle(.primary)
                                        Text(expert.subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: 0)
                                }.padding(theme.cardPadding).frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
                                    .liquidGlass(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous), elevated: false)
                            }.buttonStyle(.plain).accessibilityIdentifier("workbench-expert-" + expert.id)
                        }
                    }
                }
            }.padding(28).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
        }.background(Color.clear).accessibilityIdentifier("workbench")
    }
    /// 生成一张任务卡片按钮（点击把预填 prompt 带进草稿）
    private func taskCard(_ title: String, symbol: String, detail: String, expert: Expert, prompt: String, id: String) -> some View {
        Button { onTask(expert, prompt) } label: {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: symbol).font(.title2).foregroundStyle(theme.accent)
                Text(title).font(.title3.bold()).foregroundStyle(.primary)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(20).frame(maxWidth: .infinity, minHeight: 156, alignment: .leading)
                .liquidGlass(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous), elevated: false)
        }.buttonStyle(.plain).accessibilityIdentifier(id)
    }
}

// MARK: - 新建对话（选专家）

/// 新建对话选择页：上半部分是专家卡片网格（含技能/工具标签），
/// 下半部分是最近 6 条会话快捷入口。
struct NewChatSheet: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @State private var skillExpert: Expert?

    /// 选一位顾问新建对话：走草稿态（发第一条消息才落库），不在这里建空会话
    var onSelectExpert: (Expert) -> Void
    /// 继续最近的对话：打开已有会话
    var onOpenConversation: (Conversation) -> Void

    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("选择一位顾问")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(ExpertCatalog.all) { expert in
                                Button {
                                    create(expert: expert)
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Image(systemName: expert.symbol)
                                            .font(.system(size: 18))
                                            .foregroundStyle(Color.accentColor)
                                        Text(expert.name)
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(Color.primary)
                                        Text(expert.subtitle)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2, reservesSpace: true)
                                            .multilineTextAlignment(.leading)
                                        Text(expert.skill.framework)
                                            .font(.system(size: 10))
                                            .foregroundStyle(Color.accentColor)
                                            .lineLimit(2, reservesSpace: true)
                                            .multilineTextAlignment(.leading)
                                        if let capability = try? ExpertCapabilityCatalog.profile(expert.id) {
                                            Text(capability.calculators.isEmpty ? "证据整理 · 交付校验" : "本地计算 \(capability.calculators.count) 项 · 交付校验")
                                                .font(.caption2).foregroundStyle(.secondary)
                                        }
                                        HStack(spacing: 5) {
                                            ForEach(expert.skill.tools, id: \.self) { tool in
                                                HStack(spacing: 2) {
                                                    Image(systemName: tool.symbol)
                                                        .font(.system(size: 9))
                                                    Text(tool.displayName)
                                                        .font(.system(size: 9))
                                                }
                                                .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12)
                                    .background(theme.surface,
                                                in: RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .contextMenu { Button("查看技能与交付标准") { skillExpert = expert } }
                            }
                        }
                    }

                    if !conversations.filter({ $0.ownerKey == HostedAccount.scopeKey }).isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("继续最近的对话")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.secondary)
                            // 10-22 P1 隔离修复：此前直接 prefix(6) 取全量，切账号后会显示上一账号的会话标题
                            ForEach(conversations.filter { $0.ownerKey == HostedAccount.scopeKey }.prefix(6), id: \.id) { conv in
                                Button {
                                    dismiss()
                                    onOpenConversation(conv)
                                } label: {
                                    HStack {
                                        Image(systemName: conv.expert.symbol)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 20)
                                        Text(conv.title)
                                            .font(.subheadline)
                                            .foregroundStyle(Color.primary)
                                            .lineLimit(1)
                                        Spacer()
                                        Text(conv.expert.name)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 12)
                                    .background(theme.surface,
                                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle("新对话")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $skillExpert) { ExpertSkillSheet(expert: $0) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func create(expert: Expert) {
        // 新建入口走独立草稿，继续对话入口仍打开既有会话。
        // 发第一条消息时才由 ChatViewModel.ensureConversation() 落库，杜绝空对话
        dismiss()
        onSelectExpert(expert)
    }
}

// MARK: - 隐藏设置门禁：密码验证

/// 隐藏设置入口的密码门：输对 AppConfig.hiddenPIN 后回调 onSuccess 打开设置页
struct HiddenPinGate: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var wrong = false
    var onSuccess: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("输入密码", text: $pin)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if wrong {
                        Text("密码错误")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("验证身份")
                } footer: {
                    Text("入口：在侧栏顶部 \"中防AI\" 标题上快速连点 \(AppConfig.hiddenTriggerTaps) 次（间隔小于 0.8 秒）")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("解锁") { check() }
                        .disabled(pin.isEmpty)
                }
            }
        }
    }

    /// 校验密码：正确触发 onSuccess；错误显示提示并清空输入
    private func check() {
        if pin == AppConfig.hiddenPIN {
            onSuccess()
        } else {
            wrong = true
            pin = ""
        }
    }
}
