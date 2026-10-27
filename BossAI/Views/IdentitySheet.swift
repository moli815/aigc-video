// IdentitySheet.swift —— 个人中心（身份设置聚合页）。
// 职责：一个页面集中管理用户身份信息、AI 回复风格、强调色主题、长期记忆、
//   云端同步、定时任务、自定义专家入口与账户操作（改密/退出/备份导入导出）。
// 用户交互流程：浏览头卡与各分区卡片 → 修改字段或选项 → 点"保存"落盘并关闭；
//   破坏性操作（清空记忆、退出登录）均走 confirmationDialog 二次确认。
// 关键设计决策与防呆/安全冗余：
//   1. 采用"头卡 + 分区卡片"组合布局（方案 B 头卡 + 方案 A 卡片，用户选定），
//      大屏 iPad 上信息分区清晰；记忆删除用行内按钮（卡片布局不支持下划手势）。
//   2. 头卡瘦身（P0-19）：只显示名称与档位，行业/身份下移到身份卡，避免拥挤。
//   3. 云端会员态（hostedActive）决定展示哪些卡：定时任务/自定义专家/账户卡
//      均按会员档位条件渲染，Plus 用户看到升级引导而非空功能。
//   4. 安全设计：明示"本机不保存任何模型 API Key"（Key 全在服务端）；退出登录
//      与清空记忆都需确认弹窗，且说明退出不影响本机数据，降低误操作焦虑。
//   5. 同步防呆：syncing 期间禁用按钮并显示进度；手动同步后刷新 lastSyncShown。
//   6. sheet ownership：所有弹层（改密/会员/自定义专家/备份导入导出）都挂在本
//      NavigationStack 根视图上，统一归属、避免嵌套 sheet 丢失。
import SwiftUI
import SwiftData

/// P0-19 身份设置（个人中心）：方案 B 头卡 + 方案 A 分区卡片（用户选定组合）。
/// 头卡：头像 + 姓名·公司 + 档位/行业/身份 + 会员剩余天数大数字。
/// 卡片：对话身份 / AI 回复风格 / 强调色 / 长期记忆 / 云端同步 / 账户操作。
/// 所有原有功能保留；记忆删除改为行内按钮（卡片布局不支持下划手势）。
struct IdentitySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @Environment(\.modelContext) private var modelContext
    // 按创建时间倒序查询长期记忆，最新的显示在最上面。
    @Query(sort: \MemoryItem.createdAt, order: .reverse) private var memories: [MemoryItem]
    /// 10-22 P1 隔离修复：@Query 拿的是全量（跨账号），展示与清空都必须限定当前账号
    private var scopedMemories: [MemoryItem] {
        memories.filter { $0.ownerKey == HostedAccount.scopeKey && !$0.isDeleted }
    }

    // 初始化身份：优先本机已存身份；称呼为空时回退到云端账号昵称（P0-19），
    // 让新用户第一次打开就有像样的默认称呼。
    @State private var identity: UserIdentity = {
        var id = UserIdentity.load()
        // P0-19 称呼默认 = 开通账号时的客户称呼（用户未自行设置时）
        if id.name.isEmpty, !HostedAccount.cachedDisplayName.isEmpty {
            id.name = HostedAccount.cachedDisplayName
        }
        return id
    }()
    // 清空记忆/导出/导入的弹层开关（均需二次确认或独立 sheet）。
    @State private var showClearConfirm = false
    @State private var showExport = false
    @State private var showImport = false
    @AppStorage(ThemeStore.key) private var themeRaw = AppTheme.blue.rawValue

    // 云端会员账号
    @State private var showChangePassword = false
    @State private var showLogoutConfirm = false
    // P0-15 会员权益页 / 自助缴费
    @State private var showMembership = false
    // P0-18 云端同步
    @AppStorage("bossai.sync.autoEnabled") private var autoSync = true
    @State private var syncing = false
    @State private var lastSyncShown: Date?
    @ObservedObject private var cloudSync = SyncService.shared
    // P0-19 定时任务
    @State private var schedules: [[String: Any]] = []
    @State private var schedulesLimit = 0
    @State private var loadingSchedules = false
    @State private var scheduleError: String?
    // P0-19 自定义专家
    @State private var showCustomExperts = false

    /// 云端会员是否处于有效登录态（档位有效且持有 token），决定多个卡片的显隐。
    private var hostedActive: Bool { HostedAccount.isHostedActive && HostedAccount.hasToken }

    /// 头卡显示名：优先云端昵称，回退身份设置里的称呼
    private var heroName: String {
        let n = HostedAccount.cachedDisplayName
        if hostedActive, !n.isEmpty { return n }
        return identity.name.isEmpty ? "未设置称呼" : identity.name
    }
    private var heroAvatarChar: String { String(heroName.prefix(1)) }
    /// 头卡副标题：会员显示档位（皇冠），非会员显示公司名或引导文案。
    private var heroSubtitle: String {
        // P0-19 头卡瘦身：只保留名称与档位（行业/身份移到下方身份卡），避免拥挤
        if hostedActive { return "👑 " + HostedAccount.cachedTierName }
        return identity.company.isEmpty ? "完善身份让回答更懂你" : identity.company
    }

    /// 云端同步状态文案：优先显示本次手动同步的时间，其次服务端记录的上次同步时间。
    private var cloudSyncText: String {
        let date = lastSyncShown ?? SyncService.shared.lastSyncAt
        guard let date else { return "尚未同步" }
        return "上次 " + Self.syncTimeText(date)
    }

    /// 格式化同步时间：今天显示"今天 HH:mm"，否则显示"M月d日 HH:mm"（中文习惯）。
    private static func syncTimeText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = Calendar.current.isDateInToday(date) ? "今天 HH:mm" : "M月d日 HH:mm"
        return f.string(from: date)
    }

    /// 从云端拉取定时任务列表与档位配额；defer 保证 loading 状态必定复位。
    private func loadSchedules() async {
        loadingSchedules = true
        defer { loadingSchedules = false }
        let payload = await HostedAccount.shared.fetchSchedules()
        schedules = (payload["list"] as? [[String: Any]]) ?? []
        schedulesLimit = (payload["limit"] as? NSNumber)?.intValue ?? 0
    }

    /// 新建定时任务（默认 7 点），成功后刷新列表；失败转为友好错误文案。
    private func addSchedule(_ type: String) async {
        scheduleError = nil
        do {
            _ = try await HostedAccount.shared.createSchedule(type: type, hour: 7)
            await loadSchedules()
        } catch {
            scheduleError = FriendlyError.message(for: error, scene: .generic)
        }
    }

    /// 删除定时任务：删除请求尽力而为（失败不提示），随后刷新列表反映实际状态。
    private func removeSchedule(_ id: String) async {
        _ = try? await HostedAccount.shared.deleteSchedule(id: id)
        await loadSchedules()
    }

    /// 手动触发云端同步：syncing 锁住按钮防重复点击，结束后更新显示时间。
    private func runManualSync() async {
        syncing = true
        _ = await SyncService.shared.syncNow(context: modelContext)
        lastSyncShown = SyncService.shared.lastSyncAt
        syncing = false
    }

    /// 显式声明工具栏内容（避免大视图下的类型推断歧义）
    @ToolbarContentBuilder
    private var sheetToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("取消") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("保存") {
                identity.save()
                dismiss()
            }
            .fontWeight(.semibold)
        }
    }

    // MARK: - 通用卡片容器

    /// 通用分区卡片容器：图标 + 标题 + 内容，统一的玻璃质感背景。
    private func card<Content: View>(_ title: String, symbol: String, tint: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .foregroundStyle(tint)
                Text(title).font(.subheadline.weight(.bold))
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    /// 单行输入框：小标题 + 文本框；axis=true 时为可增高的多行输入（用于长文本）。
    private func fieldRow(_ title: String, text: Binding<String>, axis: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            if axis {
                TextField(title, text: text, axis: .vertical)
                    .lineLimit(2...4)
                    .padding(10)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.white.opacity(0.1), lineWidth: 1))
                    .font(.subheadline)
            } else {
                TextField(title, text: text)
                    .padding(10)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.white.opacity(0.1), lineWidth: 1))
                    .font(.subheadline)
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    heroCard
                    card("对话身份", symbol: "person.crop.circle", tint: theme.accent) {
                        VStack(spacing: 10) {
                            fieldRow("姓名 / 称呼", text: $identity.name)
                            fieldRow("公司", text: $identity.company)
                            fieldRow("行业", text: $identity.industry)
                            fieldRow("身份（如：创始人 / 总经理）", text: $identity.role)
                            fieldRow("当前最想解决的经营问题", text: $identity.goal, axis: true)
                        }
                    }
                    card("AI 回复风格", symbol: "text.bubble", tint: theme.accentSecondary) {
                        // P0-19 参考 WorkBuddy：标题 + 描述的可选列表（而非分段按钮）
                        VStack(spacing: 7) {
                            ForEach(ReplyStyle.allCases) { style in
                                let on = identity.replyStyle == style
                                Button {
                                    identity.replyStyle = style
                                } label: {
                                    HStack(alignment: .top, spacing: 9) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(style.displayName).font(.footnote.weight(on ? .bold : .semibold))
                                                .foregroundStyle(on ? theme.accent : Color.primary)
                                            Text(style.styleDescription).font(.caption2).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if on {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(theme.accent)
                                        }
                                    }
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(on ? theme.accent.opacity(0.12) : Color.white.opacity(0.04),
                                                in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .stroke(on ? theme.accent.opacity(0.55) : Color.white.opacity(0.08), lineWidth: 1))
                                    .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("回复风格 \(style.displayName)")
                            }
                        }
                    }
                    card("强调色", symbol: "paintpalette", tint: .cyan) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(AppTheme.allCases) { t in
                                    let selected = t.rawValue == themeRaw
                                    Button { themeRaw = t.rawValue } label: {
                                        VStack(spacing: 6) {
                                            ZStack {
                                                Circle()
                                                    .fill(t.accentGradient)
                                                    .frame(width: 40, height: 40)
                                                    .overlay {
                                                        Circle().strokeBorder(.white.opacity(selected ? 0.9 : 0.28),
                                                                              lineWidth: selected ? 2 : 1)
                                                    }
                                                    .shadow(color: selected ? t.glow : .clear, radius: 8)
                                                if selected {
                                                    Image(systemName: "checkmark")
                                                        .font(.system(size: 14, weight: .bold))
                                                        .foregroundStyle(.white)
                                                }
                                            }
                                            Text(t.displayName).font(.caption2)
                                                .foregroundStyle(selected ? Color.primary : Color.secondary)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("主题 \(t.displayName)")
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    card("长期记忆（\(scopedMemories.count) 条）", symbol: "brain", tint: .purple) {
                        if scopedMemories.isEmpty {
                            Text("暂无记忆。随着对话进行，中防AI会自动记住你的公司、项目和偏好。")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            // 记忆条目：内容 + 来源标注；来源缺失时提示"需核对"，
                            // 与产品"可溯源"原则一致。行内删除按钮即时生效并落盘。
                            VStack(spacing: 8) {
                                ForEach(scopedMemories, id: \.id) { item in
                                    HStack(alignment: .top, spacing: 8) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(item.content).font(.footnote)
                                            Text(item.source.isEmpty ? "来源未记录，需核对" : "来源：" + item.source)
                                                .font(.caption2).foregroundStyle(.tertiary)
                                        }
                                        Spacer()
                                        Button {
                                            modelContext.delete(item)
                                            try? modelContext.save()
                                        } label: {
                                            Image(systemName: "trash")
                                                .font(.caption)
                                                .foregroundStyle(.red.opacity(0.8))
                                                .frame(width: 30, height: 30)
                                                .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("删除这条记忆")
                                    }
                                    .padding(9)
                                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                            }
                            Button {
                                showClearConfirm = true
                            } label: {
                                Text("清空全部记忆")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.red.opacity(0.9))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    card("云端同步", symbol: "arrow.triangle.2.circlepath", tint: .green) {
                        VStack(spacing: 9) {
                            HStack {
                                Text(cloudSyncText).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button {
                                    Task { await runManualSync() }
                                } label: {
                                    HStack(spacing: 5) {
                                        if syncing { ProgressView().controlSize(.mini) }
                                        Text(syncing ? "同步中…" : "立即同步").font(.caption.weight(.semibold))
                                    }
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(theme.accent.opacity(0.18), in: Capsule())
                                    .foregroundStyle(theme.accent)
                                    .contentShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                .disabled(syncing)
                                .accessibilityIdentifier("sync-now")
                            }
                            Toggle(isOn: $autoSync) {
                                Text("自动同步对话、图片和文件").font(.caption)
                            }
                            .tint(theme.accent)
                            if cloudSync.lastSyncError != nil {
                                Text("部分内容暂未同步，已保留在本机。联网后可点「立即同步」重试。")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                    if hostedActive {
                        card("定时任务", symbol: "alarm", tint: .pink) {
                            scheduleContent
                        }
                        .task { if hostedActive { await loadSchedules() } }
                    }
                    if hostedActive {
                        card("我的自定义专家", symbol: "person.crop.square.badge.plus", tint: .indigo) {
                            VStack(alignment: .leading, spacing: 9) {
                                Text("上传公司资料与产品知识，生成只懂你业务的专属专家。")
                                    .font(.caption).foregroundStyle(.secondary)
                                if HostedAccount.cachedCustomExpertEnabled {
                                    Button { showCustomExperts = true } label: {
                                        Label("管理我的专家", systemImage: "arrow.right.circle.fill")
                                            .font(.footnote.weight(.semibold))
                                            .frame(maxWidth: .infinity, minHeight: 38)
                                            .background(theme.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                            .foregroundStyle(theme.accent)
                                            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("open-custom-experts")
                                } else {
                                    Button { showMembership = true } label: {
                                        Label("Ultra 旗舰版权益 · 去了解", systemImage: "crown.fill")
                                            .font(.footnote.weight(.semibold))
                                            .frame(maxWidth: .infinity, minHeight: 38)
                                            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .stroke(Color.white.opacity(0.12), lineWidth: 1))
                                            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    accountCard
                }
                .padding(16)
            }
            .navigationTitle("个人中心")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showChangePassword) { HostedChangePasswordView() }
            .sheet(isPresented: $showMembership) { MembershipView() }
            .sheet(isPresented: $showCustomExperts) { CustomExpertView() }
            .confirmationDialog("确认退出登录？", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
                Button("退出登录", role: .destructive) {
                    HostedAccount.shared.logout()
                    dismiss()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("退出后需要重新输入账号密码。本机对话记录与资料库不受影响。")
            }
            .toolbar { sheetToolbar }
            // 清空全部记忆：必须经 confirmationDialog 二次确认（destructive 角色），
            // 防止一键误删长期记忆。
            .confirmationDialog("确定清空全部长期记忆？", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("清空", role: .destructive) {
                    for m in scopedMemories { modelContext.delete(m) }
                    try? modelContext.save()
                }
                Button("取消", role: .cancel) {}
            }
            // 备份导入/导出弹层：与个人中心同级的独立 sheet，互不嵌套。
            .sheet(isPresented: $showExport) {
                BackupExportSheet()
            }
            .sheet(isPresented: $showImport) {
                BackupImportSheet()
            }
        }
    }

    // MARK: - 头卡（方案 B 保留项）

    /// 头卡：头像首字圆形 + 名称/副标题 + 会员剩余天数大数字（仅会员显示）。
    @ViewBuilder
    private var heroCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(theme.accentGradient)
                Text(heroAvatarChar)
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(.white)
            }
            .frame(width: 54, height: 54)
            VStack(alignment: .leading, spacing: 4) {
                Text(heroName)
                    .font(.headline.weight(.bold))
                    .lineLimit(1)
                Text(heroSubtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            // 剩余天数防呆：负数按 0 显示，避免出现"剩余 -3 天"的奇怪文案。
            if hostedActive, let days = HostedAccount.cachedDaysLeft {
                VStack(spacing: 1) {
                    Text(days >= 0 ? "\(days)" : "0")
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .foregroundStyle(theme.accent)
                    Text("会员剩余天数")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [theme.accent.opacity(0.22), theme.accentSecondary.opacity(0.14)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(theme.accent.opacity(0.3), lineWidth: 1))
    }

    // MARK: - 定时任务卡内容（Pro 3 / Ultra 10；Plus 引导升级）

    /// 定时任务卡内容：无配额（Plus/未获取）显示升级引导；有配额显示任务列表
    /// 与添加按钮。同类型任务已有则禁用对应按钮（每种任务只允许一个，防重复）。
    @ViewBuilder
    private var scheduleContent: some View {
        if schedulesLimit <= 0 && schedules.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("每天自动生成经营早报、每周一生成周报，写进你的会话。")
                    .font(.caption).foregroundStyle(.secondary)
                Button { showMembership = true } label: {
                    Label("升级 Pro / Ultra 解锁", systemImage: "crown.fill")
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background(theme.accentDeepGradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .foregroundStyle(.white)
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("schedule-upsell")
            }
        } else {
            VStack(spacing: 8) {
                if schedules.isEmpty, loadingSchedules {
                    Text("加载中…").font(.caption).foregroundStyle(.tertiary)
                }
                // enumerated + id:\.offset：服务端返回的字典字段可能缺 id，无法用
                // \.self 稳定标识，用下标做 ForEach 身份最稳妥（防重复 key 崩溃）。
                ForEach(Array(schedules.enumerated()), id: \.offset) { _, sched in
                    let id = (sched["_id"] as? String) ?? (sched["id"] as? String) ?? ""
                    let type = sched["type"] as? String ?? "morning"
                    let hour = (sched["hour"] as? NSNumber)?.intValue ?? 7
                    HStack {
                        Image(systemName: type == "morning" ? "sun.max.fill" : "calendar")
                            .foregroundStyle(.pink)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(type == "morning" ? "每日早报" : "每周简报").font(.footnote.weight(.semibold))
                            Text("每天 \(hour) 点后首次打开 App 自动生成").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            Task { await removeSchedule(id) }
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                                .foregroundStyle(.red.opacity(0.8))
                                .frame(width: 30, height: 30)
                                .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("删除定时任务")
                    }
                    .padding(9)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                HStack(spacing: 8) {
                    Button { Task { await addSchedule("morning") } } label: {
                        Label("早报", systemImage: "plus")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(schedules.contains { ($0["type"] as? String) == "morning" })
                    Button { Task { await addSchedule("weekly") } } label: {
                        Label("周报", systemImage: "plus")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(schedules.contains { ($0["type"] as? String) == "weekly" })
                }
                if let scheduleError {
                    Text(scheduleError).font(.caption2).foregroundStyle(.orange)
                }
                Text("生成内容会写入「每日早报 / 每周简报」会话，并同步到云端。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - 账户卡（登录态 + 改密 + 退出）

    /// 账户卡：按登录态三分支展示——已登录（账号/改密/退出）、会员档位有效但
    /// 未登录（引导回登录页）、自备 Key 模式（说明不计会员额度）。
    @ViewBuilder
    private var accountCard: some View {
        card("账户", symbol: "shield.lefthalf.filled", tint: .orange) {
            if hostedActive {
                VStack(spacing: 10) {
                    HStack {
                        Text("登录账号").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(HostedAccount.cachedDisplayName.isEmpty ? "已登录" : HostedAccount.cachedDisplayName)
                            .font(.caption.weight(.medium))
                    }
                    Button {
                        showChangePassword = true
                    } label: {
                        Label("修改密码", systemImage: "key")
                            .font(.footnote.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    Button {
                        showLogoutConfirm = true
                    } label: {
                        Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                            .font(.footnote.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .foregroundStyle(.red.opacity(0.9))
                            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    Text("模型服务由中防AI 云端提供，本机不保存任何模型 API Key。")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            } else if HostedAccount.isHostedActive {
                Text("登录状态：未登录，请返回登录页输入账号密码。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("当前使用自备 API Key 模式，不消耗会员额度。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
