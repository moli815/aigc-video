// BackupSheets.swift —— 数据备份/恢复弹层（导出加密备份 + 从备份导入）。
// 职责：
//   - BackupExportSheet：把本地全部数据（会话、文件、记忆、身份、Key、偏好）打包成
//     AES-256 加密的 .bossai 文件，供用户通过 ShareLink 保存到「文件」App 或发送出去。
//   - BackupImportSheet：选择一个 .bossai 备份文件，用密码解密后合并式导入本机。
// 用户交互流程：
//   导出：设置密码（两次确认）→ 点击生成 → 后台异步打包加密 → 成功后出现 ShareLink 分享。
//   导入：fileImporter 选文件 → 输入备份密码 → 勾选覆盖选项 → 开始导入 → 展示导入摘要。
// 关键设计决策与防呆/安全冗余：
//   1. 密码必须 ≥6 位且两次输入一致（passwordOK 双重校验）才允许导出，并在 footer 实时
//      提示具体不满足的原因，避免用户反复试错。
//   2. 备份文件强制 AES-256 加密，密码不出现在备份里、也无法找回，UI 明确警示"忘记密码
//      将无法恢复"，这是数据安全的第一道也是唯一一道防线。
//   3. 导出/导入均为异步 Task + working 状态锁：执行期间禁用按钮并显示进度，防止重复触发。
//   4. 导入默认是"合并式"且不覆盖本机配置：身份/API Key/偏好需要用户显式勾选才覆盖，
//      防止误导入把本机正在使用的密钥或身份冲掉；导入成功后调用 credentials.reload()
//      让 App 立即用上恢复后的 Key，无需重启。
//   5. 错误（密码错、文件损坏等）只展示在表单内，不弹崩溃级弹窗，用户可修改后重试。
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// 导出全部数据（加密）。
/// 展示一个 Form：设置并确认备份密码 → 异步调用 BackupService.export 生成加密的
/// .bossai 备份文件 → 成功后提供 ShareLink 分享，并提示文件在「文件」App 中的位置。
struct BackupExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var password = ""
    @State private var confirm = ""
    @State private var working = false
    @State private var errorText: String?
    @State private var resultURL: URL?

    /// 密码有效性双重校验：长度 ≥6 且两次输入一致。
    /// 只有满足才允许点击"生成加密备份"，从源头防止弱密码/手误。
    private var passwordOK: Bool {
        password.count >= 6 && password == confirm
    }

    var body: some View {
        NavigationStack {
            Form {
                // 密码区：SecureField + .newPassword，系统会避免把内容泄露到键盘缓存/自动填充历史。
                Section {
                    SecureField("设置备份密码", text: $password)
                        .textContentType(.newPassword)
                    SecureField("再输入一次", text: $confirm)
                        .textContentType(.newPassword)
                } header: {
                    Text("加密密码")
                } footer: {
                    Text("备份文件用 AES-256 加密，密码由你设定。**请务必牢记：忘记密码将无法恢复。** 建议 8 位以上，混合字母与数字。")
                }

                // 按钮区：working 期间禁用防重复触发；footer 实时反馈具体不满足的原因。
                Section {
                    Button {
                        start()
                    } label: {
                        Label("生成加密备份", systemImage: "lock.doc.fill")
                    }
                    .disabled(working || !passwordOK)

                    if working {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在打包并加密…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let errorText {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } footer: {
                    if !password.isEmpty && password.count < 6 {
                        Text("密码至少 6 位")
                    } else if !confirm.isEmpty && password != confirm {
                        Text("两次输入的密码不一致")
                    }
                }

                // 完成区：只有 resultURL 非空（备份已成功生成）才出现。
                // 文件默认落在 App 沙盒的 Exports 目录，同时提供 ShareLink 方便直接分享。
                if let url = resultURL {
                    Section {
                        Label("备份已生成", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        ShareLink(item: url) {
                            Label("保存 / 发送备份文件", systemImage: "square.and.arrow.up")
                        }
                        Text(url.lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("也可以到「文件」App → 我的 iPad → 中防AI → Exports 里找到它。换设备时把这个文件传过去，用同一个密码导入即可。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("完成")
                    }
                }
            }
            .navigationTitle("导出全部数据")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    /// 触发导出：置 working 锁定 UI，异步调用 BackupService.export 完成打包+加密，
    /// 结果写入 resultURL（成功）或 errorText（失败），最后无论如何都解除 working。
    private func start() {
        working = true
        errorText = nil
        Task {
            do {
                let url = try await BackupService.export(password: password, context: modelContext)
                resultURL = url
            } catch {
                errorText = error.localizedDescription
            }
            working = false
        }
    }
}

/// 从备份导入。
/// 通过 fileImporter 选择 .bossai 备份文件，输入解密密码，可选覆盖身份/Key/偏好，
/// 异步调用 BackupService.importBackup 做合并式导入，成功后展示导入摘要。
/// 三个 overwrite* 开关默认全关，保证"不显式勾选就不会动本机现有配置"的防呆策略。
struct BackupImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    // 导入恢复出 API Key 后需要刷新 CredentialStore，让全局立即生效，无需重启 App。
    @EnvironmentObject var credentials: CredentialStore

    @State private var showPicker = false
    @State private var fileURL: URL?
    @State private var password = ""
    @State private var working = false
    @State private var errorText: String?
    @State private var summaryText: String?
    @State private var overwriteIdentity = false
    @State private var overwriteKeys = false
    @State private var overwriteSettings = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        showPicker = true
                    } label: {
                        Label(fileURL == nil ? "选择备份文件" : "重新选择", systemImage: "folder.badge.plus")
                    }
                    if let fileURL {
                        Text(fileURL.lastPathComponent)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("备份文件")
                } footer: {
                    Text("选择之前导出的 .bossai 文件（可从「文件」App 或聊天记录里获取）。")
                }

                Section {
                    SecureField("备份密码", text: $password)
                        .textContentType(.password)
                } header: {
                    Text("解密")
                }

                Section {
                    Toggle("覆盖身份设置", isOn: $overwriteIdentity)
                    Toggle("覆盖 API Key", isOn: $overwriteKeys)
                    Toggle("覆盖偏好设置", isOn: $overwriteSettings)
                } header: {
                    Text("覆盖选项")
                } footer: {
                    Text("关闭后保留本机当前配置，只导入对话、文件与记忆。")
                }

                Section {
                    Button {
                        start()
                    } label: {
                        Label("开始导入", systemImage: "square.and.arrow.down.on.square")
                    }
                    .disabled(working || fileURL == nil || password.isEmpty)

                    if working {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在解密并恢复…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let errorText {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    if let summaryText {
                        Text(summaryText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } footer: {
                    Text("导入是合并式的：已有会话保留本机内容，补入备份中新出现的消息；身份、密钥和偏好默认保留本机配置。")
                }
            }
            .navigationTitle("从备份导入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            // fileImporter：允许任意类型（.item）以兼容不同来源的 .bossai 文件；
            // 成功后清空旧的摘要/错误，避免残留上一次导入的提示误导用户。
            .fileImporter(isPresented: $showPicker,
                          allowedContentTypes: [.item],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    fileURL = urls.first
                    summaryText = nil
                    errorText = nil
                case .failure(let error):
                    errorText = "选择文件失败：\(error.localizedDescription)"
                }
            }
        }
    }

    /// 触发导入：缺文件直接返回（防呆）；异步解密并按覆盖选项合并导入，
    /// 成功后刷新 CredentialStore、展示摘要并清空密码；失败仅展示错误信息。
    private func start() {
        guard let fileURL else { return }
        working = true
        errorText = nil
        summaryText = nil
        Task {
            do {
                let options = BackupService.ImportOptions(
                    overwriteIdentity: overwriteIdentity,
                    overwriteKeys: overwriteKeys,
                    overwriteSettings: overwriteSettings
                )
                let summary = try await BackupService.importBackup(from: fileURL,
                                                                   password: password,
                                                                   context: modelContext,
                                                                   options: options)
                // 让 App 立即用上恢复后的 Key
                credentials.reload()
                summaryText = summary.text
                password = ""
            } catch {
                errorText = error.localizedDescription
            }
            working = false
        }
    }
}
