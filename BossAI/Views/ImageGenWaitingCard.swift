import SwiftUI

/// 生图等待占位（2026-10-25 用户选定方案 C）：
///   · 96pt 见方的粒子场，**纯蓝**粒子从四周向中心聚合
///   · 粒子只在框内活动，不铺满气泡
///   · 三阶段文案：规划画面 ✓ / 生成底图（当前，约 20s）/ 排版文字（等待中）+ 细进度条
/// 用 Canvas + TimelineView 计算位置，不依赖多层嵌套动画，长列表里也不会掉帧。
struct ImageGenWaitingCard: View {
    /// 需求复述（用户原话前若干字），显示在底部
    let title: String
    /// 阶段文案：普通图片 / 名片 / 组图各不相同，由调用方传入
    var stages: [String] = ["规划画面", "生成图片", "整理结果"]

    @State private var stage = 1
    private let ticker = Timer.publish(every: 2.2, on: .main, in: .common).autoconnect()

    /// 粒子初始位置（相对中心的偏移）与相位，8 颗，克制
    private let seeds: [(x: CGFloat, y: CGFloat, r: CGFloat, delay: Double)] = [
        (-34, -26, 2.0, 0.00), (30, -30, 1.6, 0.08), (-26, 30, 1.8, 0.16), (32, 26, 2.0, 0.24),
        (0, -36, 1.6, 0.32), (-36, 2, 1.6, 0.40), (36, 0, 1.8, 0.48), (0, 36, 1.8, 0.56),
    ]

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
                Canvas { canvas, size in
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    let t = ctx.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: 3.2) / 3.2

                    // 粒子：向中心聚合 → 停顿 → 淡出
                    for s in seeds {
                        let local = (t + s.delay).truncatingRemainder(dividingBy: 1.0)
                        let k = min(1.0, local / 0.55)
                        let ease = 1 - pow(1 - k, 3)          // easeOutCubic
                        let px = center.x + s.x * CGFloat(1 - ease)
                        let py = center.y + s.y * CGFloat(1 - ease)
                        let opacity = local > 0.86 ? max(0, (1 - local) / 0.14) : 1
                        let radius = s.r * (0.55 + 0.45 * CGFloat(ease))
                        let rect = CGRect(x: px - radius, y: py - radius,
                                          width: radius * 2, height: radius * 2)
                        canvas.fill(Path(ellipseIn: rect),
                                    with: .color(Color(red: 0.36, green: 0.62, blue: 1.0).opacity(opacity)))
                    }

                    // 聚合本体：后半程出现，像"成形"
                    if t > 0.5 {
                        let p = min(1.0, (t - 0.5) / 0.22)
                        let side = 34 + 20 * CGFloat(p)
                        let rect = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
                        canvas.fill(Path(roundedRect: rect, cornerRadius: 9),
                                    with: .color(Color(red: 0.36, green: 0.62, blue: 1.0).opacity(0.18 * p)))
                        canvas.stroke(Path(roundedRect: rect, cornerRadius: 9),
                                      with: .color(Color(red: 0.36, green: 0.62, blue: 1.0).opacity(0.55 * p)),
                                      lineWidth: 1)
                    }
                }
            }
            .frame(width: 96, height: 96)     // 尺寸受控：固定 96pt，不随气泡拉伸

            VStack(alignment: .leading, spacing: 7) {
                stageRow(index: 0, label: stages[0], state: .done, meta: "已完成")
                stageRow(index: 1, label: stages[1], state: .current, meta: "约 20 秒")
                stageRow(index: 2, label: stages[2], state: .waiting, meta: "等待中")

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule()
                            .fill(LinearGradient(colors: [Color(red: 0.36, green: 0.62, blue: 1.0),
                                                          Color(red: 0.55, green: 0.49, blue: 1.0)],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * progressForStage)
                            .animation(.easeInOut(duration: 0.5), value: stage)
                    }
                }
                .frame(height: 3)
                .padding(.top, 2)

                if !title.isEmpty {
                    Text(title)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .onReceive(ticker) { _ in
            // 三阶段轮播：真实耗时不确定，这里只做"有进展"的表达，不谎报百分比
            if stage < 2 { stage += 1 } else { stage = 1 }
        }
        .accessibilityLabel("正在生成图片：\(title)")
    }

    private enum StageState { case done, current, waiting }

    private var progressForStage: CGFloat {
        switch stage {
        case 1: return 0.45
        default: return 0.78
        }
    }

    @ViewBuilder
    private func stageRow(index: Int, label: String, state: StageState, meta: String) -> some View {
        HStack(spacing: 7) {
            ZStack {
                Circle()
                    .strokeBorder(state == .current ? Color(red: 0.36, green: 0.62, blue: 1.0).opacity(0.7)
                                                    : Color.white.opacity(0.16), lineWidth: 1)
                    .frame(width: 16, height: 16)
                if state == .done {
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color(red: 0.37, green: 0.92, blue: 0.83))
                } else {
                    Text("\(index + 1)").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(state == .current ? Color(red: 0.61, green: 0.75, blue: 1.0)
                                                           : Color.white.opacity(0.35))
                }
            }
            Text(label)
                .font(.system(size: 12.5, weight: state == .current ? .semibold : .regular))
                .foregroundStyle(state == .current ? Color.primary : Color.secondary)
            Spacer(minLength: 0)
            Text(meta).font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }
}
