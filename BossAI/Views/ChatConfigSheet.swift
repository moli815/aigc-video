import SwiftUI

// ============================================================================
// 文件职责：P0-38 对话配置面板——对标主流 AI App 的「模型 / 强度 / 速度」三行结构。
// 在 App 中的角色：让客户自主选择回答的"能力档位"（标准 / 高 / 最高），
//   在"更快更省"与"更深更准"之间做自己的权衡；档位每次启动回到默认（标准）。
// 关键设计决策：
//   1. 模型真实名称永不出现——面板只显示档位名与价格画像（¥/¥¥/¥¥¥），
//      文案全部来自服务端 /me 下发（管理台可改，无需出包）；服务端未下发时用内置兜底。
//   2. 强度与速度不单独可调——它们由档位联动（标准=关思考快速；高/最高=保留推理），
//      面板以只读行展示联动结果，避免客户设置出自相矛盾的组合（如"最强模型+最快速度"）。
//   3. 选中即生效：写入 ChatViewModel.chatMode，后续每轮请求随 chatMode 字段下发。
// ============================================================================

/// 配置面板：三行（模型 / 强度 / 速度）+ 说明 + 重置 + 完成。
struct ChatConfigSheet: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    /// 当前选中的档位（standard / high / ultra），与 ChatViewModel.chatMode 双向绑定
    @Binding var chatMode: String

    /// 档位元数据来源（服务端下发 + 内置兜底），只读观察。
    /// 用 @StateObject 包装 MainActor 单例——与 HostedLoginView 的既有模式一致。
    @StateObject private var account = HostedAccount.shared

    /// 当前档位对应的展示数据（找不到时用兜底列表的第一项，保证面板永不空缺）
    private var currentOption: ChatModeOption {
        account.chatModes.first { $0.key == chatMode } ?? ChatModeOption.fallback[0]
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部把手（视觉提示可下滑关闭）
            Capsule()
                .fill(Color.white.opacity(0.22))
                .frame(width: 40, height: 4)
                .padding(.top, 10)
                .padding(.bottom, 14)

            Text("配置")
                .font(.headline)
                .padding(.bottom, 18)

            // ── 三行配置卡 ──
            VStack(spacing: 0) {
                // 第 1 行：模型档位（唯一可交互行——点击弹出标准/高/最高选择）
                Menu {
                    ForEach(account.chatModes) { option in
                        Button {
                            chatMode = option.key
                        } label: {
                            // 已选中项带对勾；文案含价格画像帮助客户权衡
                            if option.key == chatMode {
                                Label("\(option.label)（\(option.priceTier)）", systemImage: "checkmark")
                            } else {
                                Text("\(option.label)（\(option.priceTier)）")
                            }
                        }
                    }
                } label: {
                    configRow(title: "模型",
                              value: "\(currentOption.label)",
                              badge: currentOption.priceTier,
                              interactive: true)
                }
                .buttonStyle(.plain)

                Divider().opacity(0.35).padding(.leading, 16)

                // 第 2 行：强度（随档位联动，只读展示）
                configRow(title: "强度",
                          value: currentOption.strength.isEmpty ? "自动" : currentOption.strength,
                          badge: nil,
                          interactive: false)

                Divider().opacity(0.35).padding(.leading, 16)

                // 第 3 行：速度（随档位联动，只读展示）
                configRow(title: "速度",
                          value: currentOption.speed.isEmpty ? "标准" : currentOption.speed,
                          badge: nil,
                          interactive: false)
            }
            .background(theme.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(theme.border.opacity(0.7), lineWidth: 0.5)
            )
            .padding(.horizontal, 20)

            // ── 当前档位说明（云端文案）──
            Text(currentOption.desc)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
                .padding(.top, 14)

            // ── 通用提示：诚实说明档位与额度的关系（不学竞品"更快更贵"话术）──
            Text("标准档更省额度；遇到复杂问题（方案对比、多步测算）建议切到「高」或「最高」。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
                .padding(.top, 6)

            // ── 重置为默认设置 ──
            Button {
                // 回到服务端下发的默认档（当前为 standard），并同步到本轮会话
                chatMode = account.defaultChatMode
            } label: {
                Text("重置为默认设置")
                    .font(.subheadline)
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .padding(.top, 18)

            Spacer(minLength: 12)

            // ── 完成 ──
            Button {
                dismiss()
            } label: {
                Text("完成")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 999, style: .continuous))
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .presentationBackground(.ultraThinMaterial)
    }

    /// 单行配置：左侧标题、右侧值（+ 可选价格徽章 + 可选箭头）。
    /// - Parameters:
    ///   - interactive: 可交互行显示 chevron 提示可点；只读行不显示
    private func configRow(title: String, value: String, badge: String?, interactive: Bool) -> some View {
        HStack {
            Text(title)
                .font(.body)
            Spacer()
            Text(value)
                .font(.body)
                .foregroundStyle(interactive ? .primary : .secondary)
            if let badge, !badge.isEmpty {
                Text(badge)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.cyan.opacity(0.85), in: Capsule())
            }
            if interactive {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}
