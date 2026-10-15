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
    @State private var showExportAlert = false
    @State private var exportMessage = ""
    @State private var exporting = false
    @State private var previewFile: StoredFile?

    let conversation: Conversation?
    let expert: Expert
    var onConversationCreated: (Conversation) -> Void = { _ in }
    var initialText: String = ""

    /// VM 延迟持有器：body 首次求值时 VM 还未创建，用 Optional 包一层，
    /// 建好后触发 ChatView 挂载
    final class ViewModelHolder: ObservableObject {
        @Published var vm: ChatViewModel?
    }

    var body: some View {
        Group {
            if let vm = viewModelHolder.vm {
                ChatView(viewModel: vm, previewFile: $previewFile)
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
            vm.onConversationCreated = { created in
                onConversationCreated(created)
            }
            viewModelHolder.vm = vm
        }
        .onDisappear { viewModelHolder.vm?.stop() }
        .navigationTitle(conversation?.title ?? expert.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
    @State private var pendingScrollTarget: UUID?
    @State private var pendingScrollAnimated = false
    @State private var scrollClock = ScrollClock()
    private final class ScrollClock { var lastTime: TimeInterval = 0; var pending: Task<Void, Never>? }
    @ObservedObject var viewModel: ChatViewModel
    @Binding var previewFile: StoredFile?
    // P0-4 编辑重发
    @State private var editTarget: Message?

    /// 一次性贴底请求：写入末条消息 id，由 ScrollViewReader 消费后立即清空（关键：不做持久锚定）。
    private func requestScrollToBottom(animated: Bool = false, delay: TimeInterval = 0) {
        guard let lastID = viewModel.sortedMessages.last?.id else { return }
        let fire = {
            pendingScrollAnimated = animated
            pendingScrollTarget = lastID
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
                Text(AppConfig.appVersion)
                    .font(.system(size: 10, weight: .medium).monospaced())
                    .foregroundStyle(Color.white.opacity(0.28))
                    .padding(.trailing, 14)
                    .padding(.bottom, 2)
                    .allowsHitTesting(false)
            }
    }

    /// 消息区：消息列表 + 追问建议 + 滚动控制 + 研究摘要 + 错误与重试
    @ViewBuilder
    private var messageSection: some View {
        ScrollViewReader { proxy in
        ScrollView {
                LazyVStack(spacing: 0) {
                    if viewModel.sortedMessages.isEmpty {
                        EmptyStateView(expert: viewModel.expert)
                    }
                    ForEach(viewModel.sortedMessages, id: \.id) { message in
                        Group {
                            if message.id == viewModel.streamingMessageId {
                                StreamingMessageRow(message: message, buffer: viewModel.replyBuffer,
                                                    files: viewModel.files(for: message), onPreview: { previewFile = $0 })
                            } else {
                                MessageRow(message: message, files: viewModel.files(for: message), onPreview: { previewFile = $0 },
                                           isLastAssistant: message.role == "assistant" && message.id == viewModel.sortedMessages.last?.id,
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
            .onChange(of: viewModel.sortedMessages.count) { _, _ in
                guard followOutput else { return }
                requestScrollToBottom()
            }
            .onChange(of: viewModel.isStreaming) { _, streaming in
                // 发送（开始流式）与回答结束两个节点都强制回到底部
                if streaming { followOutput = true }
                if followOutput { requestScrollToBottom() }
            }
            .onReceive(viewModel.replyBuffer.$text) { _ in
                // 流式输出：trailing debounce —— 高频 token 只在 0.12s 静默后滚动一次
                guard followOutput else { return }
                scrollClock.pending?.cancel()
                scrollClock.pending = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    guard !Task.isCancelled, followOutput else { return }
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
                            .liquidGlass(Capsule(), elevated: true)
                    }
                    .buttonStyle(.plain)
                    .padding()
                    .accessibilityIdentifier("scroll-to-bottom")
                }
            }

            // P0-5 专家开场提示：空会话时展示在输入框上方，点击填充（可编辑再发送）
            if viewModel.sortedMessages.isEmpty, viewModel.streamingMessageId == nil {
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
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 4)
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

/// 流式消息行：外层仍是 MessageRow，内层用打字机游标（shownCount → targetCount）
/// 平滑展示增长中的文本；离开视图时立即补齐，避免视觉跳变。
private struct StreamingMessageRow: View {
    let message: Message
    @ObservedObject var buffer: StreamingReplyBuffer
    let files: [StoredFile]
    let onPreview: (StoredFile) -> Void
    /// 已平滑展示的字符数（打字机游标）
    @State private var shownCount = 0
    /// 打字机目标长度（随 buffer 增长）
    @State private var targetCount = 0
    @State private var pump: Task<Void, Never>?

    var body: some View {
        MessageRow(message: message, streamingText: String(buffer.text.prefix(shownCount)), files: files, onPreview: onPreview)
            .onChange(of: buffer.text) { _, newText in
                targetCount = newText.count
                startPump()
            }
            .onAppear {
                // 若刷新时已有完整文本（如重新进入会话），直接全量展示，避免从 0 逐字回放
                shownCount = buffer.text.count
                targetCount = buffer.text.count
            }
            .onDisappear {
                // 流式结束：立刻补齐剩余字符，避免从打字机截断长度跳到全文的视觉突变
                shownCount = targetCount
                pump?.cancel(); pump = nil
            }
    }

    /// 平滑打字机：18ms 一帧（≈55fps），积压越多步长越大（≤0.5s 追平模型输出）
    private func startPump() {
        guard pump == nil else { return }
        pump = Task {
            while !Task.isCancelled, shownCount < targetCount {
                let pending = targetCount - shownCount
                shownCount = min(targetCount, shownCount + max(2, pending / 15))
                try? await Task.sleep(nanoseconds: 18_000_000)
            }
            pump = nil
        }
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
                                viewModel.answerStyle = style
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
