import SwiftUI
import SwiftData
import QuickLook
import UIKit

/// 对话容器：按会话 id 取持久会话，注入 ViewModel
struct ChatContainerView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var credentials: CredentialStore
    @Query private var conversations: [Conversation]
    @StateObject private var viewModelHolder = ViewModelHolder()
    @State private var showIdentity = false
    @State private var showExportAlert = false
    @State private var exportMessage = ""

    let conversationId: UUID

    final class ViewModelHolder: ObservableObject {
        @Published var vm: ChatViewModel?
    }

    init(conversationId: UUID) {
        self.conversationId = conversationId
        let id = conversationId
        _conversations = Query(filter: #Predicate<Conversation> { $0.id == id })
    }

    var body: some View {
        Group {
            if let vm = viewModelHolder.vm, vm.conversation.id == conversationId {
                ChatView(viewModel: vm)
            } else {
                Color.clear
            }
        }
        // 任务挂在稳定的 Group 上（不要挂在条件分支内，否则切换时可能不触发）
        .task(id: conversationId) {
            guard viewModelHolder.vm?.conversation.id != conversationId else { return }
            guard let conv = conversations.first else { return }
            viewModelHolder.vm = ChatViewModel(
                conversation: conv,
                expert: conv.expert,
                modelContext: modelContext,
                chatKey: { credentials.chatKey },
                imageKey: { credentials.imageKey }
            )
        }
        .navigationTitle(conversations.first?.title ?? "对话")
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
                                exportMessage = vm.exportConversation(format: format)
                            } else {
                                exportMessage = "对话尚未就绪"
                            }
                            showExportAlert = true
                        } label: {
                            Label("导出为 \(format.displayName)", systemImage: format.symbol)
                        }
                    }
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .accessibilityLabel("导出对话")
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
    }
}

/// 对话区：消息列表 + 状态条 + 输入条
struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if viewModel.sortedMessages.isEmpty {
                            EmptyStateView(expert: viewModel.expert)
                        }
                        ForEach(viewModel.sortedMessages, id: \.id) { message in
                            MessageRow(message: message, files: viewModel.files(for: message))
                                .id(message.id)
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
                }
                .onChange(of: viewModel.sortedMessages.count) { _, _ in
                    if let last = viewModel.sortedMessages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .onChange(of: viewModel.sortedMessages.last?.text) { _, _ in
                    if let last = viewModel.sortedMessages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
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

            InputBar(viewModel: viewModel)
        }
        .background(Color(.systemBackground))
    }
}

/// 空状态：开场
struct EmptyStateView: View {
    let expert: Expert

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 100)
            Image(systemName: expert.symbol)
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
            Text(expert.name)
                .font(.title2.bold())
            Text(expert.subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("有什么可以帮你的？")
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            VStack(alignment: .leading, spacing: 6) {
                CapabilityHint(symbol: "paperclip", text: "点输入框左侧「+」上传文件、拍照或传图")
                CapabilityHint(symbol: "globe", text: "问最新资讯时会自动联网搜索")
                CapabilityHint(symbol: "doc.badge.plus", text: "说「整理成 Word / PPT」会直接生成文件")
            }
            .padding(.top, 14)
            Spacer(minLength: 100)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct CapabilityHint: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.footnote)
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
