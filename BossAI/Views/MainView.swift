import SwiftUI
import SwiftData
import UIKit

/// 主界面：ChatGPT 风格侧栏（可折叠专家团 + 对话列表 + 资料库）+ 对话区
struct MainView: View {
    @EnvironmentObject var credentials: CredentialStore

    @State private var selectedConversationId: UUID?
    @State private var showLibrary = false
    @State private var showNewChat = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var showPinEntry = false
    @State private var showHiddenSettings = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selectedConversationId: $selectedConversationId,
                        showLibrary: $showLibrary,
                        onNewChat: { showNewChat = true },
                        onHiddenSettings: { showPinEntry = true })
        } detail: {
            Group {
                if showLibrary {
                    LibraryView(onOpenConversation: { id in
                        showLibrary = false
                        selectedConversationId = id
                    })
                } else if let id = selectedConversationId {
                    ChatContainerView(conversationId: id)
                        .id(id)
                } else {
                    WelcomeView(onNewChat: { showNewChat = true })
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .task { ensureProvidersDetected() }
        .onReceive(NotificationCenter.default.publisher(for: .bossAIKeysChanged)) { _ in
            ensureProvidersDetected()
        }
        .sheet(isPresented: $showNewChat) {
            NewChatSheet { conversation in
                showLibrary = false
                selectedConversationId = conversation.id
            }
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

    /// 首次启动：用内置 Key 自动识别服务商（无需任何手动配置）
    private func ensureProvidersDetected() {
        guard !ProviderCatalog.providersDetected else { return }
        Task {
            if let ck = credentials.chatKey,
               let p = await ProviderDetector.detectChat(key: ck) {
                ProviderCatalog.saveChatProvider(p.id)
            }
            if let ik = credentials.imageKey,
               let p = await ProviderDetector.detectImage(key: ik) {
                ProviderCatalog.saveImageProvider(p.id)
            }
        }
    }
}

// MARK: - 侧栏

struct SidebarView: View {
    @Binding var selectedConversationId: UUID?
    @Binding var showLibrary: Bool
    var onNewChat: () -> Void
    var onHiddenSettings: () -> Void = {}

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]

    @State private var expertExpanded = false
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
                        showLibrary = true
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
                                open(expert: expert)
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
                                        delete(conv)
                                    } label: {
                                        Label("删除对话", systemImage: "trash")
                                    }
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        delete(conv)
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
                Color.clear.frame(height: 78)
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

            LiquidGlassButton(title: "新对话", symbol: "plus") {
                onNewChat()
            }
            .padding(.leading, 14)
            .padding(.bottom, 14)
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

    /// 点专家：优先打开该专家最近一次对话，没有就新建
    private func open(expert: Expert) {
        if let existing = conversations.first(where: { $0.expertId == expert.id }) {
            showLibrary = false
            selectedConversationId = existing.id
        } else {
            let conv = Conversation(expertId: expert.id, title: expert.name)
            modelContext.insert(conv)
            try? modelContext.save()
            showLibrary = false
            selectedConversationId = conv.id
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

struct ExpertRow: View {
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
                Text(expert.skill.framework)
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
            }
        }
    }
}

struct ConversationRow: View {
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
        if let last = conversation.messages.sorted(by: { $0.createdAt < $1.createdAt }).last {
            if !last.text.isEmpty { return last.text }
            if last.imageData != nil { return "[图片]" }
            if !last.attachmentIds.isEmpty { return "[文件]" }
        }
        return "暂无消息"
    }
}

// MARK: - 液态玻璃悬浮按钮

/// 液态玻璃风格胶囊按钮：超薄材质 + 高光渐变描边 + 柔和投影
struct LiquidGlassButton: View {
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
    var onNewChat: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.65)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 88, height: 88)
                Text("B")
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            Text("Boss AI")
                .font(.largeTitle.bold())
            Text("企业经营者的 AI 顾问矩阵")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(action: onNewChat) {
                Label("开始一个新对话", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

// MARK: - 新建对话（选专家）

struct NewChatSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]

    var onCreated: (Conversation) -> Void

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
                                    .background(Color(.secondarySystemBackground),
                                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }
                                .buttonStyle(.plain)
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
                                    onCreated(conv)
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
                                    .background(Color(.secondarySystemBackground),
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func create(expert: Expert) {
        let conv = Conversation(expertId: expert.id, title: expert.name)
        modelContext.insert(conv)
        try? modelContext.save()
        dismiss()
        onCreated(conv)
    }
}

// MARK: - 隐藏设置门禁：密码验证

struct HiddenPinGate: View {
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
