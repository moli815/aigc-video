import SwiftUI

// ============================================================================
// ImageWaitingRow.swift —— 生图等待占位（2026-10-25 重做，ChatGPT 风格）
//
// 旧版是 Canvas + TimelineView 的粒子聚合动画：96pt 画布、30fps 重绘、
// 三行阶段清单 + 进度条 + "约 20 秒" 预估。问题很实在：
//   · 视觉存在感太强，抢内容；
//   · 撑大消息气泡；
//   · 30fps 持续画布在长列表/低电量下纯属浪费；
//   · 三行"规划画面 ✓ / 生成底图 / 排版文字"其实是**我们的施工进度**，不是用户关心的东西。
//
// 现在的做法（克制版）：
//   · 一行：三个 4pt 圆点呼吸 + 一句状态文案（文案来自 ImageTaskStatus，全项目唯一来源）；
//   · 没有任何画布/时间轴：动画走 SwiftUI 的 opacity 插值，GPU 合成，列表里不重绘；
//   · 高度约 22pt，宽度上限 220pt，不撑气泡；
//   · Reduce Motion 或低电量时**自动变静态点**（不闪、不呼吸）。
//
// 规矩：这个视图只接受 ImageWaitState，不接受自由文案。
// 想要新文案就改 ImageTaskStatus，不要在调用点拼字符串。
// ============================================================================

struct ImageWaitingRow: View {
    let state: ImageWaitState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 低电量模式下不做持续动画（省电，也避免用户觉得"页面在动"）
    private var isStill: Bool {
        reduceMotion || ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    var body: some View {
        HStack(spacing: 8) {
            BreathingDots(isStill: isStill)
            Text(state.text)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 3)
        .frame(maxWidth: 220, alignment: .leading)   // 紧凑：不随气泡拉伸
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.text)
    }
}

/// 三个点的呼吸：相位差 0.15s，幅度很小（0.3 → 0.75 透明度）。
/// 不做缩放，避免"跳"；静态模式下三个点亮度一致。
private struct BreathingDots: View {
    let isStill: Bool
    @State private var on = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 4, height: 4)
                    .opacity(opacity(for: index))
                    .animation(isStill ? nil
                                       : .easeInOut(duration: 0.9)
                                            .repeatForever(autoreverses: true)
                                            .delay(Double(index) * 0.15),
                               value: on)
            }
        }
        .onAppear { if !isStill { on = true } }
    }

    private func opacity(for index: Int) -> Double {
        if isStill { return 0.45 }
        return on ? 0.75 : 0.30
    }
}
