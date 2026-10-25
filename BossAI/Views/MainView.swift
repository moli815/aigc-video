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
                                  },
                                  onConversationDeleted: {
                                      selectedConversationId = nil
                                      containerKey = nil
                                      draftConversationID = nil
                                  },
                                  initialText: draftPrompt,
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
                    ChatContainerView(conversation: conv, expert: conv.expert,
                                      onConversationDeleted: {
                                          // 10-25：对话区里删掉自己 → 切回欢迎页
                                          selectedConversationId = nil
                                          containerKey = nil
                                      })
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
        // 10-25 历史删除：本地物理级联删 + 云端墓碑（ConversationDeletion 统一负责）。
        // 先把详情区切走，再删数据——顺序反了会是"删了还显示着一条已删会话"。
        let wasOpen = (containerKey == "conv-\(conv.id.uuidString)") || (draftConversationID == conv.id)
        if selectedConversationId == conv.id { selectedConversationId = nil }
        if wasOpen {
            containerKey = nil
            draftConversationID = nil
        }
        let context = modelContext
        Task { @MainActor in
            // 打开的会话被删时，给 SwiftUI 一个卸载窗口：详情区 onDisappear 会 vm.stop()，
            // 先把在途流式请求停掉，再删库，才不会出现"删完又冒出半条回复"。
            if wasOpen { try? await Task.sleep(nanoseconds: 50_000_000) }
            ConversationDeletion.delete(conv, context: context)
        }
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
    /// 10-25 删除确认：非 nil 时弹确认框，**确认后才真正删**（误触删除不可接受）
    @State private var pendingDelete: Conversation?
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
            // 10-23 完整重构：List → ScrollView + VStack，自绘卡片式行与选中态。
            // 保留全部交互：导航三件套、专家折叠、搜索、重命名/删除、新建。
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    // 一级入口
                    VStack(spacing: 2) {
                        sidebarNavRow("定时任务", "clock") { showIdentitySheet = true }
                        sidebarNavRow("深度研究", "magnifyingglass") { onOpenResearch() }
                        sidebarNavRow("资料库", "folder", active: showLibrary) { onOpenLibrary() }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 4)

                    // 专家团（可折叠）
                    sidebarSectionHeader("您的专属军师", count: ExpertCatalog.all.count,
                                         chevron: expertExpanded) {
                        withAnimation(.easeInOut(duration: 0.2)) { expertExpanded.toggle() }
                    }
                    if expertExpanded {
                        VStack(spacing: 1) {
                            ForEach(ExpertCatalog.all) { expert in
                                Button { onOpenExpert(expert) } label: {
                                    ExpertRow(expert: expert)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 10)
                    }

                    // 对话
                    sidebarSectionHeader("对话", count: filtered.count, chevron: nil) {}
                    sidebarSearchField
                    if filtered.isEmpty {
                        Text(searchText.isEmpty ? "还没有对话，点左下角新建" : "没有匹配的对话")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 16)
                    } else {
                        VStack(spacing: 1) {
                            ForEach(filtered, id: \.id) { conv in
                                HStack(spacing: 2) {
                                    Button { selectedConversationId = conv.id } label: {
                                        ConversationRow(conversation: conv)
                                            .background(
                                                selectedConversationId == conv.id ? theme.accent.opacity(0.16) : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            )
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    // 10-25 删除入口（显性）：长按菜单藏得太深，找不到删除是真实反馈。
                                    // 这里给常驻小按钮，点了先弹确认，确认后才真正删除。
                                    Button { pendingDelete = conv } label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: 12, weight: .regular))
                                            .foregroundStyle(Color.secondary.opacity(0.75))
                                            .frame(width: 30, height: 30)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("删除对话「\(conv.title)」")
                                    .accessibilityIdentifier("conv-delete")
                                }
                                .contextMenu {
                                    Button {
                                        renaming = conv
                                        renameText = conv.title
                                    } label: { Label("重命名", systemImage: "pencil") }
                                    Button(role: .destructive) {
                                        pendingDelete = conv
                                    } label: { Label("删除对话", systemImage: "trash") }
                                }
                            }
                        }
                        .padding(.horizontal, 10)
                    }

                    Spacer(minLength: 10)
                }
            }
            .background(.ultraThinMaterial)
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
        // 10-25 删除确认：用 confirmationDialog 而不是第二个 alert——
        // 同一视图上已经挂了「重命名」alert，破坏性动作走 Apple 推荐的动作表也更清楚。
        .confirmationDialog("删除这个对话？",
                            isPresented: Binding(
                                get: { pendingDelete != nil },
                                set: { if !$0 { pendingDelete = nil } }
                            ),
                            titleVisibility: .visible,
                            presenting: pendingDelete) { conv in
            Button("删除", role: .destructive) {
                let target = conv
                pendingDelete = nil
                onDeleteConversation(target)
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: { conv in
            Text("「\(conv.title)」及其全部消息将被删除，且无法恢复。")
        }
        // P0-47 方案 A：「定时任务」入口打开身份页（含定时任务卡）
        .sheet(isPresented: $showIdentitySheet) { IdentitySheet() }
    }

    // MARK: - 侧栏自绘组件（10-23 List → ScrollView 重构配套）

    /// 10-23 P3：侧栏统一行组件。固定 22pt 图标槽、12pt 图标文字间距、10pt 左侧内边距，
    /// 保证一级导航、专家行、对话行的图标列和文字左边缘严格对齐。
    private func sidebarNavRow(_ title: String, _ icon: String, active: Bool = false,
                               action: @escaping () -> Void) -> some View {
        SidebarRow(icon: icon, title: title, active: active, action: action)
    }

    private func sidebarSectionHeader(_ title: String, count: Int, chevron: Bool?,
                                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                if let chevron {
                    Image(systemName: chevron ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var sidebarSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.footnote)
                .foregroundStyle(.secondary)
            TextField("搜索对话", text: $searchText)
                .textFieldStyle(.plain)
                .font(.footnote)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
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
    /// 侧栏会员卡改为观察实时状态（此前读 UserDefaults 静态快照 + 20 秒轮询，
    /// 首次安装/冷启动时快照还没写，就把默认值当成真实会员状态显示成"Plus 已过期"）。
    @ObservedObject private var account = HostedAccount.shared
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

    /// 徽章文案：从未同步且还没有档位信息时，不要说成具体的 Plus（默认值会误导）
    private var tierBadgeText: String {
        MembershipDisplay.tierBadge(tierName: account.tierName,
                                    synced: account.lastRefreshAt != nil,
                                    syncing: account.refreshing)
    }

    /// 剩余天数：优先用 /me 实时值，再退回本地缓存；都没有就返回 nil（交给 UI 显示"未同步"）
    private var effectiveDaysLeft: Int? {
        if let d = account.daysLeft { return d }
        return HostedAccount.cachedDaysLeft
    }

    /// P0-19 方案 A：档位徽章 + 剩余天数 + 三环并排 + 身份设置/升级入口
    @ViewBuilder
    private var hostedTierCard: some View {
        VStack(spacing: 10) {
            HStack {
                Text("👑 " + tierBadgeText)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(theme.accent.opacity(0.18), in: Capsule())
                    .foregroundStyle(theme.accent)
                    .onTapGesture { Task { await account.refresh() } }
                    .accessibilityIdentifier("sidebar-tier")
                Spacer()
                if account.refreshing {
                    ProgressView().controlSize(.mini)
                } else if let days = effectiveDaysLeft {
                    Text(days >= 0 ? "剩 \(days) 天" : "已到期")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Button("未同步·点此刷新") { Task { await account.refresh() } }
                        .font(.caption2).foregroundStyle(.secondary).buttonStyle(.plain)
                }
            }
            // 10-22 用户要求：底部不再显示额度金额/百分比，改为「会员到期时间」
            MembershipExpiryRing(daysLeft: effectiveDaysLeft,
                                 until: account.memberUntil ?? HostedAccount.cachedMemberUntil,
                                 syncing: account.refreshing)
            if let err = account.lastRefreshError, account.lastRefreshAt == nil {
                Text("会员信息没取到：" + err)
                    .font(.system(size: 9)).foregroundStyle(.orange)
                    .lineLimit(2).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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

/// 会员展示的纯计算（抽出来是为了能被单测锁住）。
/// 关键不变量：**"没有数据"必须返回 nil，绝不能被当成 0 天/已到期** ——
/// 侧栏此前读本地快照，首次安装时快照还没写入，于是把默认值渲染成「Plus 基础版 · 已过期」。
enum MembershipDisplay {
    /// 剩余天数：服务端值优先；缺失时按到期日推算；两者都没有 → nil（未知）
    static func daysLeft(serverDays: Int?, until: Date?, now: Date = Date()) -> Int? {
        if let serverDays { return serverDays }
        guard let until else { return nil }
        return Calendar.current.dateComponents([.day], from: now, to: until).day
    }

    /// 是否已到期：未知一律返回 false（宁可显示"未同步"，也不能谎称已过期）
    static func isExpired(daysLeft: Int?) -> Bool {
        guard let daysLeft else { return false }
        return daysLeft <= 0
    }

    /// 徽章文案：从未同步且仍是默认档位时，不冒充具体档位
    static func tierBadge(tierName: String, synced: Bool, syncing: Bool) -> String {
        if synced || tierName != "Plus 基础版" { return tierName }
        return syncing ? "会员同步中…" : "会员"
    }
}

/// 会员有效期环：环心显示剩余天数，环按「剩余/30」比例收缩，下方标注到期日期。
/// 10-22 用户要求用「会员到期」替代原额度金额展示。
struct MembershipExpiryRing: View {
    @Environment(\.appTheme) private var theme
    let daysLeft: Int?
    let until: Date?
    /// 正在向服务端取会员状态（用于区分"还没取到"和"取到了但没有到期日"）
    var syncing: Bool = false

    /// 天数优先用服务端下发；缺失时按到期日自己算（只用于展示，不参与任何计费判断）
    private var computedDays: Int? { MembershipDisplay.daysLeft(serverDays: daysLeft, until: until) }
    /// 没有任何可用数据 = 未知。**未知绝不等于已到期**（这正是"会员显示不正确"的根因）
    private var unknown: Bool { computedDays == nil }
    private var days: Int { max(0, computedDays ?? 0) }
    private var progress: CGFloat {
        // 以 30 天为一个周期估算环进度（到期时间不由本地计算，仅作视觉参考）
        guard !unknown else { return 0.02 }
        return min(1, max(0.02, CGFloat(days) / 30.0))
    }
    private var expired: Bool { MembershipDisplay.isExpired(daysLeft: computedDays) }
    private var centreText: String {
        if unknown { return syncing ? "…" : "—" }
        return expired ? "0" : "\(days)"
    }
    private var expiryText: String {
        if unknown { return syncing ? "同步中…" : "未同步" }
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
                    Text(centreText)
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
        .accessibilityLabel(unknown ? (syncing ? "会员信息同步中" : "会员信息未同步")
                            : (expired ? "会员已到期" : "会员剩余 \(days) 天，\(expiryText)"))
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

/// 10-23 P3：侧栏统一行组件。固定 22pt 图标槽、12pt 间距、10pt 左侧内边距，
/// 保证导航/专家/对话三种行在图标列和文字起始列严格对齐。
struct SidebarRow: View {
    let icon: String
    var iconSize: CGFloat = 14
    let title: String
    var subtitle: String? = nil
    var trailing: String? = nil
    var active: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: iconSize, weight: .regular))
                    .foregroundStyle(active ? Color.accentColor : Color.primary)
                    .frame(width: 22, alignment: .center)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(active ? Color.accentColor : Color.primary)
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if let trailing, !trailing.isEmpty {
                    Text(trailing)
                        .font(.system(size: 10))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 侧栏专家行：复用 SidebarRow 的固定图标槽与间距，保证与导航/对话行严格对齐。
struct ExpertRow: View {
    let expert: Expert

    var body: some View {
        // P0-47 简笔风图标（方案 A 实装）：统一品牌图标线性描边，取消每位专家独立图标
        HStack(spacing: 12) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .center)
            VStack(alignment: .leading, spacing: 1) {
                Text(expert.name)
                    .font(.system(size: 14, weight: .regular))
                Text(expert.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
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

/// 侧栏单条对话行：复用 SidebarRow 的固定图标槽与间距，保证与导航/专家行严格对齐。
struct ConversationRow: View {
    @Environment(\.appTheme) private var theme
    let conversation: Conversation

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: conversation.expert.symbol)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .center)
            VStack(alignment: .leading, spacing: 1) {
                Text(conversation.title)
                    .font(.system(size: 14, weight: .regular))
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
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
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
