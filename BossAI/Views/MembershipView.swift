//
//  MembershipView.swift
//  BossAI
//
//  会员权益 + 自助缴费界面（Views 层）：
//  - 职责：一个 sheet 内完成"浏览档位 → 选档 → 扫码付款 → 提交确认"两步式流程。
//  - 交互流程：进入时从服务端拉取档位列表（features 由服务端下发，客户端只负责渲染）；
//    点击档位卡进入付款页展示收款二维码；用户付款后点"我已完成支付"提交确认；
//    平台核对到账后自动开通（展示"最迟 6 小时"预期）。
//  - 关键设计决策与防呆/安全冗余：
//    1) 不向客户暴露额度金额——页面只出现售价与"额度倍数"，额度区只给百分比与重置倒计时，
//       避免把内部定价/成本结构泄露给终端用户。
//    2) 权益差异项按服务端 features 字典渲染，featureOrder 只控制展示顺序与文案，
//       服务端可随时增删权益而无需发版。
//    3) "我已完成支付"按钮在提交期间禁用并显示进度，防止重复提交造成多次开通请求。
//    4) 二维码加载失败/取不到时给出明确可操作的提示，不留死页面。
//    5) 文件内同时包含 SessionReplacedAlertView（被顶下线全局弹窗，挂在 App 根部，
//       避免污染大视图的类型推断）与 MembershipQuotaRow（设置页额度行）两个轻量组件。
//

import SwiftUI

/// P0-15 会员权益页 + 自助缴费页（合并为一个 sheet，两步式：选档 → 扫码付款）
/// 设计原则：**不向客户暴露额度金额**——只出现售价与「额度倍数」；额度区只给百分比与重置倒计时。
struct MembershipView: View {
    @Environment(\.appTheme) private var theme
    /// 关闭当前 sheet
    @Environment(\.dismiss) private var dismiss
    /// 托管账号单例：读当前档位、拉档位列表与收款码、提交付款确认
    private let account = HostedAccount.shared

    /// 服务端下发的档位列表（key/name/priceCny/quotaMultiple/features）
    @State private var tiers: [[String: Any]] = []
    /// 用户当前选中的档位（非空表示进入付款页）
    @State private var selected: [String: Any]?
    /// 选档后拉到的支付信息（含收款码 URL）
    @State private var payment: [String: Any]?
    /// 档位/收款码加载中
    @State private var loading = true
    /// 付款确认提交中：期间禁用按钮，防止重复提交
    @State private var submitting = false
    /// 提交成功后的提示文案（非空时整页切换为"已提交"卡片）
    @State private var doneMessage: String?
    /// 提交失败信息
    @State private var errorText: String?

    /// 功能差异项（按服务端 features 渲染，客户可读）
    /// - key：服务端 features 字典里的字段名
    /// - label：面向客户的中文权益名
    /// - value：把原始值（Int/Bool/NSNumber）转成客户可读文案；-1/负数约定为"无限"
    private let featureOrder: [(key: String, label: String, value: (Any) -> String)] = [
        ("memoryLimit", "长期记忆", { v in
            let n = (v as? Int) ?? ((v as? NSNumber)?.intValue ?? 0)
            return n < 0 ? "无限" : "\(n) 条"
        }),
        ("fileMb", "单个文件上限", { v in "\(((v as? Int) ?? ((v as? NSNumber)?.intValue ?? 0))) MB" }),
        ("fileCount", "单次文件数", { v in
            let n = (v as? Int) ?? ((v as? NSNumber)?.intValue ?? 0)
            return n < 0 ? "无限" : "\(n) 个"
        }),
        ("exportDoc", "一键导出报告", { v in (v as? Bool) == true ? "支持" : "—" }),
        ("schedules", "定时任务", { v in
            let n = (v as? Int) ?? ((v as? NSNumber)?.intValue ?? 0)
            return n > 0 ? "\(n) 个" : "—"
        }),
        ("deepResearch", "深度研究", { v in (v as? Bool) == true ? "支持" : "—" }),
        ("customExpert", "自定义专家", { v in (v as? Bool) == true ? "支持" : "—" }),
        ("whiteLabel", "品牌定制", { v in (v as? Bool) == true ? "支持" : "—" }),
    ]

    /// 页面主体：三态切换——已提交卡片 / 选档列表 / 付款页；标题与返回按钮随状态变化
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let msg = doneMessage {
                        doneCard(msg)
                    } else if selected == nil {
                        benefitsHeader
                        ForEach(Array(tiers.enumerated()), id: \.offset) { _, tier in
                            tierCard(tier)
                        }
                        commonNote
                    } else {
                        paySection
                    }
                }
                .padding(18)
            }
            .background(theme.canvas.ignoresSafeArea())
            .navigationTitle(selected == nil ? "会员权益" : "扫码缴费")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(selected == nil || doneMessage != nil ? "关闭" : "返回") {
                        if selected != nil, doneMessage == nil { selected = nil; payment = nil }
                        else { dismiss() }
                    }
                }
            }
        }
        .task { await load() }
    }

    // MARK: - 权益页

    /// 顶部说明区：一句话解释档位逻辑（额度高低 + 功能解锁）
    private var benefitsHeader: some View {
        VStack(spacing: 6) {
            Text("选择适合你的会员档位")
                .font(.headline)
            Text("额度越高，能用得越久；功能权益逐档解锁")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 2)
    }

    /// 单个档位卡片：档名 + 当前档标记 + 额度倍数 + 售价 + 权益差异列表；点击进入付款页
    private func tierCard(_ tier: [String: Any]) -> some View {
        // 容错取值：服务端字段缺失时给安全默认值，保证卡片永不崩溃
        let key = tier["key"] as? String ?? "plus"
        let name = tier["name"] as? String ?? key
        let price = (tier["priceCny"] as? NSNumber)?.doubleValue ?? 0
        let multiple = (tier["quotaMultiple"] as? NSNumber)?.doubleValue ?? 1
        let features = tier["features"] as? [String: Any] ?? [:]
        let isCurrent = key == account.tier
        return Button {
            selected = tier
            Task { await loadPayment(tierKey: key) }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(name).font(.title3.bold())
                    if isCurrent {
                        Text("当前")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(theme.accent.opacity(0.18), in: Capsule())
                            .foregroundStyle(theme.accent)
                    }
                    Spacer()
                    // 只展示"额度倍数"不展示具体额度金额——不向客户暴露额度定价细节
                    Text(multiple <= 1 ? "基础额度" : String(format: "额度 ×%.1f", multiple))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.accent)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("¥").font(.headline)
                    Text(String(format: "%.0f", price)).font(.system(size: 30, weight: .heavy, design: .rounded))
                    Text("/ 月").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
                }
                // 按 featureOrder 定义的顺序渲染权益行；服务端没下发的字段就不显示
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(featureOrder, id: \.key) { item in
                        if let raw = features[item.key] {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(theme.accent)
                                Text(item.label).font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                                Text(item.value(raw)).font(.caption2.weight(.medium))
                            }
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlass(RoundedRectangle(cornerRadius: 16, style: .continuous), elevated: key == "ultra")
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isCurrent ? theme.accent.opacity(0.5) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tier-card-" + key)
    }

    /// 底部通用说明：所有档位共有的权益 + 重置规则 + 退款/账号限制条款（合规文案）
    private var commonNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("所有档位均包含").font(.caption.weight(.semibold))
            Text("15 位行业专家 · 联网搜索 · 文件与图片识别 · AI 生图 · 对话本地留存与加密备份 · 单设备登录保护")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("额度按自然日 / 自然周 / 每月重置；账号仅限本人使用，不支持退款。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - 付款页

    /// 付款页：档名 + 价格 + 收款二维码 + "我已完成支付"确认按钮
    @ViewBuilder
    private var paySection: some View {
        if let tier = selected {
            let key = tier["key"] as? String ?? "plus"
            let name = tier["name"] as? String ?? key
            let price = (tier["priceCny"] as? NSNumber)?.doubleValue ?? 0
            // 收款码嵌在 payment.selectedTier.qrUrl 里；服务端结构与档位接口复用同一层
            let qr = (payment?["selectedTier"] as? [String: Any])?["qrUrl"] as? String

            VStack(spacing: 14) {
                Text(name).font(.headline)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("¥").font(.title3)
                    Text(String(format: "%.0f", price)).font(.system(size: 36, weight: .heavy, design: .rounded))
                    Text("/ 月").font(.caption).foregroundStyle(.secondary)
                }
                // 二维码三态：成功 / 失败（给出可操作提示）/ 加载中；白底保证扫码对比度
                if let qr, let url = URL(string: qr) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFit()
                        case .failure:
                            VStack(spacing: 6) {
                                Image(systemName: "qrcode").font(.largeTitle)
                                Text("收款码加载失败，请检查网络后重试").font(.caption2).foregroundStyle(.secondary)
                            }
                        default:
                            ProgressView()
                        }
                    }
                    .frame(width: 200, height: 200)
                    .padding(10)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else if loading {
                    ProgressView().frame(height: 200)
                } else {
                    Text("暂时取不到收款码，请稍后重试").font(.caption).foregroundStyle(.secondary)
                }
                Text("支付宝扫码支付 ¥\(String(format: "%.0f", price))，转账备注你的账号名")
                    .font(.caption2).foregroundStyle(.secondary)

                if let errorText {
                    Text(errorText)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // 付款确认提交：submitting 期间按钮禁用防重复提交
                Button {
                    Task { await submit(tierKey: key, name: name) }
                } label: {
                    HStack {
                        if submitting { ProgressView().tint(.white) }
                        Text(submitting ? "提交中…" : "我已完成支付")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(theme.accentDeepGradient, in: Capsule())
                    .foregroundStyle(.white)
                    .contentShape(Capsule())   // 整块可点
                }
                .disabled(submitting)
                .accessibilityIdentifier("paid-done")

                Text("点击后平台会收到你的付款确认（带档位标签），核对到账后即可开通。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.top, 4)
        }
    }

    /// 提交成功后的整页"已提交"卡片：明确告知核对到账的时限预期
    private func doneCard(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 44)).foregroundStyle(theme.accent)
            Text("已提交").font(.title3.bold())
            Text(message).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("好的") { dismiss() }
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(theme.surface, in: Capsule())
                .contentShape(Capsule())
        }
        .padding(.top, 40)
    }

    // MARK: - 数据

    /// 拉取档位列表（首次进入时）
    private func load() async {
        loading = true
        tiers = await account.fetchTiers()
        loading = false
    }

    /// 按所选档位拉取收款码等支付信息
    private func loadPayment(tierKey: String) async {
        loading = true
        payment = await account.fetchPaymentInfo(tier: tierKey)
        loading = false
    }

    /// 提交付款确认：成功后刷新账号状态并展示时限预期；失败转成友好错误文案
    private func submit(tierKey: String, name: String) async {
        submitting = true
        errorText = nil
        do {
            _ = try await account.submitSelfRenew(tier: tierKey)
            await account.refresh()
            doneMessage = "已收到你对「\(name)」的付款确认。核对到账后会自动开通，最迟 6 小时内完成。"
        } catch {
            errorText = FriendlyError.message(for: error, scene: .generic)
        }
        submitting = false
    }
}


/// P0-15 单设备登录提示：被其他设备顶下线时弹窗（挂在 App 根部，避免污染大视图的类型推断）
struct SessionReplacedAlertView: View {
    @ObservedObject private var account = HostedAccount.shared
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .alert("账号已在其他设备登录", isPresented: Binding(
                get: { account.sessionReplacedNotice != nil },
                set: { if !$0 { account.sessionReplacedNotice = nil } }
            )) {
                Button("知道了", role: .cancel) { account.sessionReplacedNotice = nil }
            } message: {
                Text(account.sessionReplacedNotice ?? "当前设备已退出登录，请重新登录后使用。")
            }
    }
}


/// 单层额度行（设置页用）：百分比 + 距重置倒计时——**不出现金额**（与权益页同一设计原则：不向客户暴露额度金额）
struct MembershipQuotaRow: View {
    /// 额度行名称（如"对话额度"）
    let title: String
    /// 已用百分比（0–100）
    let pct: Double
    /// 下次重置时间；nil 表示不显示倒计时
    let resetAt: Date?

    var body: some View {
        // 钳制到 0–100 防御服务端异常值；剩余 ≤20% 转橙色提醒，视觉先行于文字
        let clamped = min(100, max(0, pct))
        let low = clamped <= 20
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(clamped.rounded()))%")
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(low ? Color.orange : Color.primary)
            }
            ProgressView(value: clamped, total: 100)
                .tint(low ? .orange : Color.accentColor)
            if let resetAt {
                Text("距重置 " + MembershipQuotaRow.countdown(to: resetAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    /// 剩余时长：>1 天显示"天+小时"，否则"小时+分"
    static func countdown(to date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSinceNow))
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 { return "\(days) 天 \(hours) 小时后" }
        if hours > 0 { return "\(hours) 小时 \(minutes) 分后" }
        return "\(minutes) 分钟后"
    }
}
