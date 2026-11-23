import SwiftUI

/// 会员登录页。
///
/// 设计前提：模型 API Key 全部由服务端持有，客户端只保存会员 token，
/// 因此这里只需要账号与密码，不再让用户接触任何 Key。
///
/// 职责：提供品牌展示 + 账密登录表单；登录成功后刷新 CredentialStore 并广播
/// Key 变更通知，由根视图自动切换到主界面。
/// 用户交互流程：输入账号（回车跳到密码）→ 输入密码（回车直接登录）→
/// 登录中按钮禁用并显示进度 → 失败显示红色错误卡片。
/// 防呆/安全冗余：
///   1. busy 状态锁 + guard 防止重复提交；登录中禁用按钮并降低透明度。
///   2. 输入框关闭自动大写与自动纠错，避免账号被 iOS "自作聪明"改写。
///   3. 错误信息只落在表单内（优先取 LocalizedError 描述），不中断流程。
///   4. 键盘处理：scrollDismissesKeyboard(.interactively) 允许下拉交互式收起键盘；
///      表单限宽 460 居中，兼顾 iPad 大屏与小窗分屏。
struct HostedLoginView: View {
    /// 全局凭据仓库；登录成功后 reload 使新 token 立即生效。
    @EnvironmentObject private var credentials: CredentialStore
    @Environment(\.appTheme) private var theme
    /// 会员账号状态（单例），负责实际的登录请求。
    @StateObject private var account = HostedAccount.shared

    @State private var username = ""
    @State private var password = ""
    /// 网络请求进行中的锁：防重复提交 + 驱动按钮的进度/禁用态。
    @State private var busy = false
    @State private var errorText: String?
    /// 焦点管理：实现"账号回车跳密码、密码回车提交"的键盘流。
    @FocusState private var focus: Field?

    /// 输入框焦点标识。
    private enum Field { case user, pass }

    var body: some View {
        ZStack {
            AmbientBackground(theme: theme)

            // ScrollView 而非固定布局：键盘弹出/小屏时内容可滚动，配合交互式收起键盘。
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 48)

                    // 品牌
                    VStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .fill(theme.accentDeepGradient)
                                .frame(width: 84, height: 84)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                                        .strokeBorder(GlassDesign.strokeHighlight, lineWidth: 1)
                                }
                                .shadow(color: theme.glow, radius: 16, y: 6)
                            Text("中")
                                .font(.system(size: 42, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                        }
                        Text("中防AI")
                            .font(.largeTitle.bold())
                        Text("企业经营者的 AI 顾问矩阵")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    // 表单
                    VStack(spacing: 14) {
                        Text("会员登录")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        field(icon: "person", placeholder: "登录账号", text: $username, secure: false, tag: .user)
                        field(icon: "lock", placeholder: "登录密码", text: $password, secure: true, tag: .pass)

                        if let shownError = errorText ?? account.lastErrorMessage {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                Text(shownError)
                                    .font(.footnote)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .foregroundStyle(.red)
                            .padding(12)
                            .background(.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(.red.opacity(0.28), lineWidth: 1)
                            }
                        }

                        Button {
                            Task { await signIn() }
                        } label: {
                            HStack(spacing: 8) {
                                if busy { ProgressView().controlSize(.small).tint(Color(red: 0.016, green: 0.071, blue: 0.122)) }
                                Text(busy ? "登录中…" : "登录")
                                    .font(.headline)
                            }
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))   // 整块可点（plain 样式默认只命中文字）
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(GlassDesign.inkGlyph)
                        .background(theme.accentDeepGradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(GlassDesign.strokeHighlight, lineWidth: 1)
                        }
                        .shadow(color: theme.glow, radius: 12, y: 4)
                        .disabled(busy)
                        .opacity(busy ? 0.75 : 1)
                        .accessibilityIdentifier("hosted-login")

                        Text("账号由服务人员分配。忘记密码请联系服务人员重置。")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 2)
                    }
                    .padding(22)
                    .liquidGlass(RoundedRectangle(cornerRadius: 18, style: .continuous), elevated: false)
                    .padding(.top, 34)

                    Spacer(minLength: 60)
                }
                .padding(.horizontal, 22)
                .frame(maxWidth: 460)
                .frame(maxWidth: .infinity)
            }
            // 下拉交互式收起键盘：输入长密码时不想打字可顺势滑下键盘。
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear {
            // 进入页面自动聚焦账号框，减少一次点击；已有输入则不打扰。
            if username.isEmpty { focus = .user }
        }
    }

    /// 构建带图标、焦点高亮、回车流转的输入行。
    /// secure 决定密码/明文框；tag 用于焦点定位与 submitLabel 切换。
    @ViewBuilder
    private func field(icon: String, placeholder: String, text: Binding<String>, secure: Bool, tag: Field) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.accent)
                .frame(width: 20)
            Group {
                if secure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            // 账号框回车=跳到密码；密码框回车=直接登录。
            .submitLabel(tag == .user ? .next : .go)
            .onSubmit {
                if tag == .user { focus = .pass } else { Task { await signIn() } }
            }
            .focused($focus, equals: tag)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 50)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(focus == tag ? theme.accent.opacity(0.55) : theme.border, lineWidth: 1)
        }
    }

    /// 执行登录：busy 锁防重入 → 调用 HostedAccount.login → 成功后刷新凭据并
    /// 广播 Key 变更通知（根视图据此切换界面）；失败展示可读错误。
    private func signIn() async {
        guard !busy else { return }
        busy = true
        errorText = nil
        account.lastErrorMessage = nil
        do {
            try await account.login(username: username, password: password)
            // 登录成功后重新读取凭据，根视图会自动切换到主界面
            credentials.reload()
            NotificationCenter.default.post(name: .bossAIKeysChanged, object: nil)
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? "登录失败，请稍后重试"
        }
        busy = false
    }
}

/// 修改密码（会员自助）。
/// 三个 SecureField：当前密码 + 新密码 + 确认；canSubmit 做联合校验（非空、
/// ≥6 位、两次一致、非 busy）才允许保存。修改成功后短暂展示"已修改"再自动关闭。
/// 提示"其他设备登录会失效"是服务端会话策略的透明化说明。
struct HostedChangePasswordView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var oldPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    /// 请求进行中锁：防止重复提交。
    @State private var busy = false
    @State private var errorText: String?
    @State private var done = false

    /// 提交许可的联合校验：非 busy、当前密码非空、新密码 ≥6 位且两次一致。
    private var canSubmit: Bool {
        !busy && !oldPassword.isEmpty && newPassword.count >= 6 && newPassword == confirmPassword
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("当前密码", text: $oldPassword)
                    SecureField("新密码（至少 6 位）", text: $newPassword)
                    SecureField("确认新密码", text: $confirmPassword)
                } footer: {
                    Text("修改后其他设备上的登录会失效，本机不受影响。")
                }

                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                if done {
                    Section {
                        Label("密码已修改", systemImage: "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.green)
                    }
                }
            }
            .navigationTitle("修改密码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await submit() } }
                        .disabled(!canSubmit)
                }
            }
        }
    }

    /// 提交改密请求：先做一致性校验（双保险，canSubmit 已拦过一次），
    /// 成功后展示"已修改"约 0.9 秒再自动关闭，给用户明确的成功反馈。
    private func submit() async {
        guard newPassword == confirmPassword else {
            errorText = "两次输入的新密码不一致"
            return
        }
        busy = true
        errorText = nil
        do {
            try await HostedAccount.shared.changePassword(old: oldPassword, new: newPassword)
            done = true
            try? await Task.sleep(nanoseconds: 900_000_000)
            dismiss()
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? "修改失败，请稍后重试"
        }
        busy = false
    }
}
