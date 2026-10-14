import SwiftUI

/// 云端会员用量提示条。
///
/// 额度已合并为**统一池**（对话 + 作图），因此这里只看池档位：
/// 仅「用量偏高 / 已超限」两档渲染，正常状态完全不渲染 —— 不打扰。
struct UsageNoticeBar: View {
    @Environment(\.appTheme) private var theme
    /// 本地缓存的统一池用量档位；normal 表示完全隐藏提示条
    @State private var poolBand: HostedUsageBand = .normal

    /// 应渲染的档位：normal 返回 nil（不渲染）——正常状态不打扰用户
    private var activeBand: HostedUsageBand? {
        poolBand == .normal ? nil : poolBand
    }

    /// 语义色同时承载在描边与图标上，不单靠颜色传达（文字本身已说明状态）
    private var tint: Color {
        poolBand == .limited
            ? Color(red: 0.97, green: 0.44, blue: 0.44)      // 红：已超限
            : Color(red: 0.98, green: 0.75, blue: 0.29)      // 琥珀：用量偏高
    }

    var body: some View {
        Group {
            if let band = activeBand, let text = band.noticeText {
                HStack(spacing: 9) {
                    Image(systemName: band == .limited ? "exclamationmark.triangle.fill" : "gauge.with.needle")
                        .font(.system(size: 13))
                        .foregroundStyle(tint)
                    Text(text)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                // 与 ExpertBanner 同一套深墨玻璃：主题色由描边与辉光承载
                .background {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.bannerFill)
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(GlassDesign.surfaceSheen)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(tint.opacity(0.55), lineWidth: 1)
                }
                .shadow(color: theme.glow, radius: 10, x: 0, y: 4)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(text)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .task { await refresh() }
    }

    /// 拉取最新档位；失败时保留上次值 —— 提示条是辅助信息，不值得为它打扰用户
    /// 进页面拉一次最新档位；失败时保留上次值——提示条是辅助信息，不值得为它打扰用户
    private func refresh() async {
        await HostedAccount.shared.refresh()
        poolBand = HostedAccount.cachedPoolBand
    }
}
