import SwiftUI

// ============================================================================
// RecoverableErrorView.swift —— 可恢复错误卡片（10-24 新增，实施计划 §8.7）
//
// 职责：把 APIErrorEnvelope 渲染成「一句人话 + 一组真实可点的按钮」。
//
// 硬规则（与计划一致）：
//   1. 按钮只来自客户端白名单（FriendlyError.actions），服务端不能塞任意函数名让 App 执行；
//   2. 未知动作不渲染、不执行；
//   3. 执行中禁用按钮并显示进度，防重复点击造成重复任务/重复扣费；
//   4. 内部错误码只在"问题编号"里出现（那是给客服查日志用的，不是技术堆栈）。
// ============================================================================

struct RecoverableErrorView: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let envelope: APIErrorEnvelope
    /// 有动作正在执行（例如"重试剩余"）——禁用全部按钮
    var busy: Bool = false
    /// 动作回调：仅白名单 ID
    let onAction: (String) -> Void

    /// 元组不支持 KeyPath，包一层 Identifiable 供 ForEach 使用
    private struct RenderedAction: Identifiable {
        let id: String
        let title: String
    }

    private var actions: [RenderedAction] {
        FriendlyError.actions(from: envelope.actions).map { RenderedAction(id: $0.id, title: $0.title) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 5) {
                    Text(envelope.message)
                        .font(.footnote)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)

                    if !envelope.requestId.isEmpty {
                        // 只给编号，不给堆栈/上游原文；用户反馈时可直接报这个号
                        Text("问题编号 \(envelope.requestId)")
                            .font(.system(size: 10.5, weight: .regular).monospaced())
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
            }

            if !actions.isEmpty {
                // 动作按钮会自动换行：小屏/大字号下不挤出屏幕
                FlowLayout(spacing: 8) {
                    ForEach(actions) { action in
                        Button {
                            onAction(action.id)
                        } label: {
                            HStack(spacing: 5) {
                                if busy && action.id == "retry" {
                                    ProgressView().controlSize(.mini)
                                }
                                Text(action.title)
                                    .font(.footnote.weight(.medium))
                            }
                            .padding(.horizontal, 12)
                            .frame(minHeight: 34)
                        }
                        .buttonStyle(.plain)
                        .background(theme.surface, in: Capsule())
                        .overlay(Capsule().stroke(theme.border, lineWidth: 0.8))
                        .foregroundStyle(theme.accent)
                        .disabled(busy)
                        .opacity(busy ? 0.55 : 1)
                        .accessibilityIdentifier("error-action-\(action.id)")
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.28), lineWidth: 0.8)
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: busy)
    }
}

// MARK: - 简易流式布局（按钮换行，避免 HStack 溢出）

/// 只做一件事：把子视图按可用宽度依次排列，放不下就换行。
/// 不引入第三方布局库（计划明确禁止为纯视觉调整新增依赖）。
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [CGFloat] = [0]
        var rowHeights: [CGFloat] = [0]
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            let idx = rows.count - 1
            let needed = rows[idx] == 0 ? size.width : rows[idx] + spacing + size.width
            if needed > maxWidth, rows[idx] > 0 {
                rows.append(size.width)
                rowHeights.append(size.height)
            } else {
                rows[idx] = needed
                rowHeights[idx] = max(rowHeights[idx], size.height)
            }
        }
        let height = rowHeights.reduce(0, +) + CGFloat(max(0, rowHeights.count - 1)) * spacing
        return CGSize(width: maxWidth == .infinity ? (rows.max() ?? 0) : maxWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sv.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
