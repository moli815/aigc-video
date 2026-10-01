import SwiftUI
import SwiftData

/// 对话容器：按专家取/建持久会话，注入 ViewModel。
struct ChatContainerView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var credentials: CredentialStore
    @Query private var conversations: [Conversation]
    @StateObject private var viewModelHolder = ViewModelHolder()
    @State private var showIdentity = false

    let expert: Expert

    final class ViewModelHolder: ObservableObject {
        @Published var vm: ChatViewModel?
    }

    private var conversation: Conversation {
        if let existing = conversations.first(where: { $0.expertId == expert.id }) {
            return existing
        }
        let created = Conversation(expertId: expert.id, title: expert.name)
        modelContext.insert(created)
        try? modelContext.save()
        return created
    }

    init(expert: Expert) {
        self.expert = expert
        let id = expert.id
        _conversations = Query(filter: #Predicate<Conversation> { $0.expertId == id })
    }

    var body: some View {
        Group {
            if let vm = viewModelHolder.vm {
                ChatView(viewModel: vm, expert: expert)
            } else {
                ProgressView()
                    .onAppear {
                        viewModelHolder.vm = ChatViewModel(
                            conversation: conversation,
                            expert: expert,
                            modelContext: modelContext,
                            chatKey: { credentials.chatKey },
                            imageKey: { credentials.imageKey }
                        )
                    }
            }
        }
        .navigationTitle(expert.name)
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
        }
        .sheet(isPresented: $showIdentity) {
            IdentitySheet()
        }
    }
}

/// 对话区：消息列表 + 状态条 + 输入条（ChatGPT 风格，内容居中限宽）
struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    let expert: Expert

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if viewModel.sortedMessages.isEmpty {
                            EmptyStateView(expert: expert)
                        }
                        ForEach(viewModel.sortedMessages, id: \.id) { message in
                            MessageRow(message: message)
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
                            .frame(maxWidth: 720)
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
                    .padding(.horizontal, 20)
                    .padding(.bottom, 4)
            }

            InputBar(viewModel: viewModel)
        }
        .background(Color(.systemBackground))
    }
}

/// 空状态：ChatGPT 风格的开场
struct EmptyStateView: View {
    let expert: Expert

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 120)
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
            Spacer(minLength: 120)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
