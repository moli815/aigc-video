import SwiftUI
import SwiftData

/// Offline opt-in fixture uses the production ChatView, MessageRow and Markdown renderer.
struct ChatRenderingFixtureView: View {
    @Environment(\.modelContext) private var context
    @State private var vm: ChatViewModel?
    @State private var preview: StoredFile?
    private let mode = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--render-mode=") }?.split(separator: "=").last.map(String.init) ?? "table"
    var body: some View {
        Group {
            if mode == "workbench" { MainView() }
            else { NavigationStack {
            Group {
                if let vm { ChatView(viewModel: vm, previewFile: $preview) }
                else { ProgressView() }
            }
            .navigationTitle("真实对话渲染回归")
        }
        }
        }
        .task {
            guard mode != "workbench" else { return }
            guard vm == nil else { return }
            let conversation = Conversation(expertId: "general", title: "离线渲染样本")
            context.insert(conversation)
            let text: String
            switch mode {
            case "long":
                text = (1...10).map { "## 第\($0)段\n这是第\($0)段完整答案。" }.joined(separator: "\n\n") + "\n\n完整答案末尾标记"
            case "rows":
                text = "| 编号 | 内容 |\n| --- | --- |\n" + (1...60).map { "| \($0) | 第\($0)行完整数据 |" }.joined(separator: "\n")
            case "sources":
                text = "结论待核实（来源 7）。本段只引用第7条，其他检索记录没有声称支持结论。"
            default:
                text = "| 编号 | 标题 | 链接 | 第四列 | 第五列 |\n| --- | --- | --- | --- | --- |\n| 7 | 第一行长标题：这是一段用来复现来源表格换行重叠的测试数据，标题应自动撑开整行高度并保留完整文字 | [官方规格](https://example.com/a) | 测试4 | 最右列可见标记 |\n| 14/16 | 第二行较短标题 | [发布公告](https://example.com/b) | 测试5 | 下一行最右内容 |\n| 23 | 第三行 | 待核实 | 测试6 | 第三行最右内容 |"
            }
            let message = Message(role: "assistant", text: text)
            if mode == "sources" {
                let sources = (1...85).map { CitationSource(id: $0, url: "https://example.com/\($0)", title: "测试来源标题\($0)") }
                message.sourcesJSON = String(data: try! JSONEncoder().encode(sources), encoding: .utf8)!
            }
            message.conversation = conversation; context.insert(message)
            try? context.save()
            vm = ChatViewModel(conversation: conversation, expert: ExpertCatalog.find("general"), modelContext: context, chatKey: { nil }, imageKey: { nil })
        }
    }
}
