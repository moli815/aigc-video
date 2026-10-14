//
//  PerformanceFixtureView.swift
//  BossAI
//
//  离线性能夹具页（Views 层）：
//  - 职责：在完全不访问模型/搜索/用户会话的前提下，构造确定性的重负载渲染场景，
//    用于压测 MarkdownView 渲染管线与流式追加路径（配合 PerformanceTrace 埋点）。
//  - 交互流程：页面按 --fixture-count= 参数（默认 200，钳制 20–1000）生成 N 条
//    含标题/列表/加粗/表格的样本消息；点"模拟流式输出"按钮后，以 80ms 间隔
//    追加 100 段增量文本，模拟真实流式回答的渲染压力。
//  - 关键设计决策：
//    1) 全部数据为内置样本（固定文案），无网络、无随机、无隐私——结果可复现、可对比。
//    2) 流式任务用 Task 承载并记录 PerformanceTrace span，页面消失即取消，
//       防止夹具任务泄漏到其他页面。
//    3) collapseDisabled: true：夹具只关心渲染吞吐，折叠交互不在测量范围内。
//

import SwiftUI

/// Opt-in offline rendering fixture. No models, search or user conversations are accessed.
/// 离线渲染性能夹具：批量样本消息 + 模拟流式追加，压测 Markdown 渲染管线
struct PerformanceFixtureView: View {
    /// 流式模拟的实时文本（不断追加增量）
    @State private var streamingText = ""
    /// 是否正在模拟流式输出
    @State private var streaming = false
    /// 流式任务句柄：页面消失时取消，防泄漏
    @State private var streamTask: Task<Void, Never>?
    /// 样本消息条数：从启动参数 --fixture-count= 读取，缺省 200，钳制在 20–1000
    private let messageCount: Int = {
        let raw = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--fixture-count=") }
        let count = Int(raw?.split(separator: "=").last.map(String.init) ?? "200") ?? 200
        return min(1000, max(20, count))
    }()
    /// 固定样本文本：覆盖标题/列表/加粗/表格，保证每条消息都命中主要渲染路径
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
                // 模拟流式按钮：启动 Task，用 PerformanceTrace 包住整个流式过程便于出报告
                Button(streaming ? "生成中" : "模拟流式输出") {
                    streaming = true
                    streamTask = Task { @MainActor in
                        let span = PerformanceTrace.begin("OfflineStreamFixture")
                        // defer 保证异常/取消路径也收尾 span 并复位状态
                        defer { PerformanceTrace.end("OfflineStreamFixture", span); streaming = false; streamTask = nil }
                        // 100 段增量、每段间隔 80ms：近似真实 LLM 流式输出的节奏
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
            // 页面销毁即取消流式任务，防止夹具任务在后台继续跑
            .onDisappear { streamTask?.cancel() }
        }
    }
}
