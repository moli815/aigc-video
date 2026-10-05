import SwiftUI

/// Opt-in offline rendering fixture. No models, search or user conversations are accessed.
struct PerformanceFixtureView: View {
    @State private var streamingText = ""
    @State private var streaming = false
    @State private var streamTask: Task<Void, Never>?
    private let messageCount: Int = {
        let raw = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--fixture-count=") }
        let count = Int(raw?.split(separator: "=").last.map(String.init) ?? "200") ?? 200
        return min(1000, max(20, count))
    }()
    private let sample = """
    ## 决策样本
    - 用户提供：预算1000，周期30天。
    - 假设：转化率待验证。
    **结论**：先做受控实验，再复盘。
    | 指标 | 数值 | 状态 |
    | --- | --- | --- |
    | 预算 | 1000 | 测试数据 |
    """
    var body: some View {
        NavigationStack {
            VStack {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(0..<messageCount, id: \.self) { index in
                            MarkdownView("第\(index + 1)条测试消息\n" + sample, collapseDisabled: true)
                                .padding(12).background(Color(.secondarySystemBackground))
                        }
                        MarkdownView(streamingText, collapseDisabled: true)
                    }
                }
                .accessibilityIdentifier("fixture-scroll")
                Button(streaming ? "生成中" : "模拟流式输出") {
                    streaming = true
                    streamTask = Task { @MainActor in
                        let span = PerformanceTrace.begin("OfflineStreamFixture")
                        defer { PerformanceTrace.end("OfflineStreamFixture", span); streaming = false; streamTask = nil }
                        for index in 0..<100 {
                            streamingText += "\n- 样本增量\(index)：来源需核实。"
                            try? await Task.sleep(nanoseconds: 80_000_000)
                            if Task.isCancelled { break }
                        }
                    }
                }
                .disabled(streaming)
                .accessibilityIdentifier("fixture-stream")
            }
            .navigationTitle("离线性能样本 \(messageCount)")
            .onDisappear { streamTask?.cancel() }
        }
    }
}
