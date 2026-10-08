import SwiftUI
import SwiftData
import UIKit
import Combine

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
    @State private var providerTask: Task<Void, Never>?
    @State private var showNewChat = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var showPinEntry = false
    @State private var showHiddenSettings = false

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
            onHiddenSettings: { showPinEntry = true })
        } detail: {
            detailContent
        }
        .navigationSplitViewStyle(.balanced)
        .environmentObject(credentials)
        .task { ensureProvidersDetected() }
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
                                  }, initialText: draftPrompt)
                    .id(key)
            } else {
                let raw = String(key.dropFirst("conv-".count))
                if let uuid = UUID(uuidString: raw),
                   let conv = conversations.first(where: { $0.id == uuid }) {
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

    private func startNewDraft(_ expert: Expert, keepPrompt: Bool = false) {
        if !keepPrompt { draftPrompt = "" }
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
        if let existing = conversations.first(where: { $0.expertId == expert.id }) {
            selectedConversationId = existing.id
            containerKey = "conv-\(existing.id.uuidString)"
        } else {
            selectedConversationId = nil
            containerKey = "draft-\(expert.id)"
        }
        columnVisibility = .detailOnly
    }

    private func delete(_ conv: Conversation) {
        if selectedConversationId == conv.id { selectedConversationId = nil }
        if containerKey == "conv-\(conv.id.uuidString)" || draftConversationID == conv.id { containerKey = nil; draftConversationID = nil }
        modelContext.delete(conv)
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

struct SidebarView: View {
    @Environment(\.appTheme) private var theme
    @Binding var selectedConversationId: UUID?
    @Binding var showLibrary: Bool
    var onNewChat: () -> Void
    var onOpenExpert: (Expert) -> Void = { _ in }
    var onDeleteConversation: (Conversation) -> Void = { _ in }
    var onOpenLibrary: () -> Void = {}
    var onHiddenSettings: () -> Void = {}

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]

    @State private var expertExpanded = true
    @State private var searchText = ""
    @State private var renaming: Conversation?
    @State private var renameText = ""
    @State private var tapCount = 0
    @State private var lastTapAt = Date.distantPast

    private var filtered: [Conversation] {
        let keyword = searchText.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return conversations }
        return conversations.filter { conv in
            if conv.title.localizedCaseInsensitiveContains(keyword) { return true }
            if conv.expert.name.localizedCaseInsensitiveContains(keyword) { return true }
            return conv.messages.contains { $0.text.localizedCaseInsensitiveContains(keyword) }
        }
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            List(selection: $selectedConversationId) {
                Section {
                    Button {
                        onOpenLibrary()
                    } label: {
                        Label("资料库", systemImage: "folder.fill")
                            .foregroundStyle(showLibrary ? Color.accentColor : Color.primary)
                    }
                    .buttonStyle(.plain)
                }

                // 可折叠的专家团
                Section {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { expertExpanded.toggle() }
                    } label: {
                        HStack {
                            Label("专家顾问", systemImage: "person.2.badge.gearshape.fill")
                            Spacer()
                            Text("\(ExpertCatalog.experts.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Image(systemName: expertExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)

                    if expertExpanded {
                        ForEach(ExpertCatalog.experts) { expert in
                            Button {
                                onOpenExpert(expert)
                            } label: {
                                ExpertRow(expert: expert)
                            }
                            .buttonStyle(.plain)
                        }
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
                    Button(action: onNewChat) { Label("新任务", systemImage: "plus").frame(maxWidth: .infinity).padding(.vertical, 6) }
                        .buttonStyle(.borderedProminent).padding([.horizontal, .bottom], 12)
                        .accessibilityIdentifier("new-task")
                }
                .background(theme.surface)
            }
            .safeAreaInset(edge: .top) {
                HStack {
                    Text("Boss AI")
                        .font(.title2.bold())
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .onTapGesture { registerTap() }
                .accessibilityLabel("Boss AI")
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
    }

    private func delete(_ conv: Conversation) {
        if selectedConversationId == conv.id { selectedConversationId = nil }
        modelContext.delete(conv)
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

/// 侧栏额度组件：对话 / 生图 剩余百分比（额度设为 0 = 不限时自动隐藏）
struct QuotaSidebarWidget: View {
    @Environment(\.appTheme) private var theme
    @State private var tick = 0
    private let refresh = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    var body: some View {
        let chat = BudgetTracker.chatRemainingPercent()
        let image = BudgetTracker.imageRemainingPercent()
        Group {
            if chat != nil || image != nil {
                VStack(alignment: .leading, spacing: 7) {
                    if let chat { quotaRow("对话额度", percent: chat, color: theme.accent) }
                    if let image { quotaRow("生图额度", percent: image, color: .orange) }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        }
        .onReceive(refresh) { _ in tick += 1 }
        .accessibilityElement(children: .combine)
    }

    private func quotaRow(_ label: String, percent: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(percent.rounded()))%")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(percent < 20 ? Color.red : Color.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule().fill(percent < 20 ? Color.red : color)
                        .frame(width: max(4, geo.size.width * percent / 100))
                }
            }
            .frame(height: 4)
        }
    }
}

struct ExpertRow: View {
    @Environment(\.appTheme) private var theme
    let expert: Expert

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: expert.symbol)
                .font(.system(size: 13))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
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
}

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

struct WelcomeView: View {
    @Environment(\.appTheme) private var theme
    var onNewChat: () -> Void
    var onTask: (Expert, String) -> Void = { _, _ in }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack {
                    Label("BossAI 工作台", systemImage: "square.grid.2x2.fill").font(.headline).foregroundStyle(theme.accent)
                    Spacer()
                    Button("新任务", systemImage: "plus", action: onNewChat).buttonStyle(.bordered)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("把问题变成可以行动的答案").font(.largeTitle.bold()).fontDesign(theme.headingDesign).fixedSize(horizontal: false, vertical: true)
                    Text("提出任务，核对证据，带走成果。").font(.title3).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 14)], spacing: 14) {
                    taskCard("查最新信息", symbol: "globe", detail: "产品、竞品、行业动态与价格", expert: ExpertCatalog.general,
                             prompt: "请核实以下最新信息。主题：\n截至日期：今天\n需要的字段：\n优先官方资料，区分已发布事实、未核实信息与传闻，逐项注明依据。", id: "task-research")
                    taskCard("做一项决策", symbol: "chart.bar.xaxis", detail: "方案比较、投入产出与行动步骤", expert: ExpertCatalog.experts.first ?? ExpertCatalog.general,
                             prompt: "请帮我比较方案并做决策。背景：\n备选方案：\n目标：\n预算与时间：\n已知数据：\n请区分事实与假设，列清计算依据、风险和下一步。", id: "task-decision")
                    taskCard("分析现有资料", symbol: "doc.text.magnifyingglass", detail: "上传资料、提炼重点与待确认项", expert: ExpertCatalog.general,
                             prompt: "请分析我上传的资料。关注问题：\n期望成果：\n请按资料中的证据给结论，指出矛盾和缺失；需要外部核实时先明确说明。", id: "task-documents")
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("专家协作").font(.title2.bold())
                    Text("选择任务方向；计算、检索与交付工具按实际技能配置执行。").font(.subheadline).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
                        ForEach(ExpertCatalog.experts) { expert in
                            Button { onTask(expert, "") } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: expert.symbol).foregroundStyle(theme.accent).frame(width: 24)
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(expert.name).font(.headline).foregroundStyle(.primary)
                                        Text(expert.subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: 0)
                                }.padding(theme.cardPadding).frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
                                    .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.cardRadius))
                            }.buttonStyle(.plain).accessibilityIdentifier("workbench-expert-" + expert.id)
                        }
                    }
                }
            }.padding(28).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
        }.background(theme.canvas).accessibilityIdentifier("workbench")
    }
    private func taskCard(_ title: String, symbol: String, detail: String, expert: Expert, prompt: String, id: String) -> some View {
        Button { onTask(expert, prompt) } label: {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: symbol).font(.title2).foregroundStyle(theme.accent)
                Text(title).font(.title3.bold()).foregroundStyle(.primary)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(20).frame(maxWidth: .infinity, minHeight: 156, alignment: .leading)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.cardRadius))
                .overlay(RoundedRectangle(cornerRadius: theme.cardRadius).stroke(theme.border, lineWidth: 0.7))
        }.buttonStyle(.plain).accessibilityIdentifier(id)
    }
}

// MARK: - 新建对话（选专家）

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

                    if !conversations.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("继续最近的对话")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.secondary)
                            ForEach(conversations.prefix(6), id: \.id) { conv in
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
                    Text("入口：在侧栏顶部 \"Boss AI\" 标题上快速连点 \(AppConfig.hiddenTriggerTaps) 次（间隔小于 0.8 秒）")
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

    private func check() {
        if pin == AppConfig.hiddenPIN {
            onSuccess()
        } else {
            wrong = true
            pin = ""
        }
    }
}
