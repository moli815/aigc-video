import SwiftUI
import SwiftData
import UIKit

/// 对话容器。
/// - 已有会话：传 conversation
/// - 草稿态（点了专家但还没发消息）：conversation 为 nil，第一次发送时才落库
struct ChatContainerView: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var credentials: CredentialStore
    @StateObject private var viewModelHolder = ViewModelHolder()
    @State private var showIdentity = false
    @State private var showExportAlert = false
    @State private var exportMessage = ""
    @State private var exporting = false
    @State private var previewFile: StoredFile?

    let conversation: Conversation?
    let expert: Expert
    var onConversationCreated: (Conversation) -> Void = { _ in }
    var initialText: String = ""

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
            Image(systemName: expert.symbol)
                .font(.system(size: 15))
                .foregroundStyle(.white)
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
        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
    @State private var scrollClock = ScrollClock()
    private final class ScrollClock { var lastTime: TimeInterval = 0 }
    @ObservedObject var viewModel: ChatViewModel
    @Binding var previewFile: StoredFile?

    var body: some View {
        VStack(spacing: 0) {
            // 专家对话：顶部固定身份横幅，与其他普通对话区分
            if viewModel.expert.id != ExpertCatalog.general.id {
                ExpertBanner(expert: viewModel.expert)
            }
            TaskControls(viewModel: viewModel)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if viewModel.sortedMessages.isEmpty {
                            EmptyStateView(expert: viewModel.expert, onStarter: { viewModel.inputText = $0 })
                        }
                        ForEach(viewModel.sortedMessages, id: \.id) { message in
                            Group {
                                if message.id == viewModel.streamingMessageId {
                                    StreamingMessageRow(message: message, buffer: viewModel.replyBuffer,
                                                        files: viewModel.files(for: message), onPreview: { previewFile = $0 })
                                } else {
                                    MessageRow(message: message, files: viewModel.files(for: message), onPreview: { previewFile = $0 })
                                }
                            }.id(message.id)
                        }
                        Color.clear.frame(height: 1).id("conversation-bottom")


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
                }
                .defaultScrollAnchor(.bottom)
                .accessibilityIdentifier("chat-scroll")
                .simultaneousGesture(DragGesture(minimumDistance: 5).onChanged { value in
                    if abs(value.translation.height) > abs(value.translation.width), value.translation.height > 5 { followOutput = false }
                })
                .onChange(of: viewModel.sortedMessages.count) { _, _ in
                    if followOutput, let last = viewModel.sortedMessages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onReceive(viewModel.replyBuffer.$text) { _ in
                    let now = ProcessInfo.processInfo.systemUptime
                    if followOutput && now - scrollClock.lastTime >= 0.25 {
                        scrollClock.lastTime = now
                        proxy.scrollTo("conversation-bottom", anchor: .bottom)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !followOutput {
                        Button { followOutput = true; proxy.scrollTo("conversation-bottom", anchor: .bottom) } label: { Label("回到最新", systemImage: "arrow.down") }
                            .buttonStyle(.borderedProminent).padding()
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
            InputBar(viewModel: viewModel)
        }
        .background(theme.canvas)
    }
}

private struct StreamingMessageRow: View {
    let message: Message
    @ObservedObject var buffer: StreamingReplyBuffer
    let files: [StoredFile]
    let onPreview: (StoredFile) -> Void
    var body: some View {
        MessageRow(message: message, streamingText: buffer.text, files: files, onPreview: onPreview)
    }
}

/// 空状态：展示这位专家的技能包（方法论 + 工具）
struct EmptyStateView: View {
    @Environment(\.appTheme) private var theme
    let expert: Expert
    var onStarter: (String) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 90)
            Image(systemName: expert.symbol)
                .font(.system(size: 42))
                .foregroundStyle(Color.accentColor)
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

            Button("填写任务背景", systemImage: "square.and.pencil") {
                onStarter("请协助我完成\(expert.name)任务。\n背景：\n目标：\n已知资料与数据：\n时间和预算限制：\n请先说明缺少哪些关键资料，再给出可核对的结论与行动步骤。")
            }.buttonStyle(.borderedProminent).accessibilityIdentifier("expert-starter")
            Text("输入任务，或上传资料；需要实时事实时选择联网研究")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 90)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct TaskControls: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.appTheme) private var theme
    @State private var chooseResearch = false
    @State private var chooseStyle = false
    var body: some View {
        HStack(spacing: 10) {
            Button { chooseResearch = true } label: {
                Label(viewModel.researchMode.label, systemImage: "globe")
                    .padding(.horizontal, 10).frame(minHeight: 44).contentShape(Rectangle())
                    .background(theme.accentSoft, in: Capsule())
            }
            .accessibilityIdentifier("research-mode")
            .confirmationDialog("选择证据方式", isPresented: $chooseResearch, titleVisibility: .visible) {
                ForEach(ResearchMode.allCases) { mode in Button(mode.label) { viewModel.researchMode = mode } }
                Button("取消", role: .cancel) {}
            }
            Button { chooseStyle = true } label: {
                Label(viewModel.answerStyle.label, systemImage: "text.alignleft")
                    .padding(.horizontal, 10).frame(minHeight: 44).contentShape(Rectangle())
                    .background(theme.accentSoft, in: Capsule())
            }
            .accessibilityIdentifier("answer-style")
            .confirmationDialog("选择回答深度", isPresented: $chooseStyle, titleVisibility: .visible) {
                ForEach(AnswerStyle.allCases) { style in Button(style.label) { viewModel.answerStyle = style } }
                Button("取消", role: .cancel) {}
            }
            Spacer(minLength: 0)
        }
        .buttonStyle(.plain).font(.footnote).padding(.horizontal, 20).padding(.vertical, 6)
        .background(theme.surface).disabled(viewModel.isStreaming)
    }
}
