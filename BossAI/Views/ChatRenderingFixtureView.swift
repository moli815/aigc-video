// ChatRenderingFixtureView.swift —— 离线渲染回归夹具（fixture），非用户日常界面。
// 职责：在脱离网络/真实模型的环境下，构造固定的"对话样本"数据（长文、大表格、
//   多来源引用等），复用生产环境的 ChatView / MessageRow / Markdown 渲染链路，
//   用于截图对比与布局回归测试（例如来源表格换行重叠的复现场景）。
// 用户交互流程：无人工交互。由启动参数 --render-mode=<long|rows|sources|table|workbench>
//   决定渲染哪种样本；workbench 模式直接展示 MainView 用于整体界面回归。
// 关键设计决策与防呆/安全冗余：
//   1. 坚持复用生产渲染组件而非复制品，保证"测到的就是用户看到的"，避免夹具与
//      真实实现逐渐漂移。
//   2. .task 里用 guard vm == nil 防止重复构建会话/消息（SwiftUI 的 task 可能
//      因视图重建被多次触发）。
//   3. chatKey / imageKey 传入 { nil }，确保夹具完全不发起网络请求，离线可跑。
//   4. 样本文本均为硬编码常量，保证跨版本可复现（回归对比的前提是输入稳定）。
import SwiftUI
import SwiftData

/// 离线渲染回归夹具：用生产级 ChatView 渲染固定的离线样本文本。
/// Offline opt-in fixture uses the production ChatView, MessageRow and Markdown renderer.
struct ChatRenderingFixtureView: View {
    @Environment(\.modelContext) private var context
    // 延迟创建的聊天视图模型：样本数据写入 SwiftData 后才能构造，因此可选。
    @State private var vm: ChatViewModel?
    // 预览文件绑定占位：ChatView 需要该绑定，夹具场景不使用文件预览。
    @State private var preview: StoredFile?
    /// 从启动参数解析渲染模式（--render-mode=xxx），缺省为 table（来源表格回归样本）。
    private let mode = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--render-mode=") }?.split(separator: "=").last.map(String.init) ?? "table"
    var body: some View {
        Group {
            // workbench 模式直接渲染主界面，用于整体 UI 回归；其余模式进入对话渲染。
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
        // 首次出现时构建样本：防呆双保险——workbench 不需要样本；vm 已存在则跳过，
        // 避免重复插入会话/消息造成数据翻倍。
        .task {
            guard mode != "workbench" else { return }
            guard vm == nil else { return }
            // 建一个固定标题的离线会话作为样本容器。
            let conversation = Conversation(expertId: "general", title: "离线渲染样本")
            context.insert(conversation)
            // 按模式生成不同的边界样本文本：
            // long=多段长文；rows=60 行大表格（滚动性能）；sources=来源引用归属；
            // 默认 table=复现来源表格换行重叠的原始回归场景（第 7 行长标题自动撑高）。
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
            // sources 模式额外挂 85 条引用来源，考验来源面板的展开/滚动渲染。
            let message = Message(role: "assistant", text: text)
            if mode == "sources" {
                let sources = (1...85).map { CitationSource(id: $0, url: "https://example.com/\($0)", title: "测试来源标题\($0)") }
                // 10-24 P0：夹具也不能 try!/强解包——渲染回归测试里崩掉会让整条流水线红。
                if let data = try? JSONEncoder().encode(sources) {
                    message.sourcesJSON = String(data: data, encoding: .utf8) ?? "[]"
                }
            }
            message.conversation = conversation; context.insert(message)
            try? context.save()
            // Key 闭包恒为 nil：夹具不触发任何网络调用，可完全离线运行。
            vm = ChatViewModel(conversation: conversation, expert: ExpertCatalog.find("general"), modelContext: context, chatKey: { nil }, imageKey: { nil })
        }
    }
}
