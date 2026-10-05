import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// 导出全部数据（加密）
struct BackupExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var password = ""
    @State private var confirm = ""
    @State private var working = false
    @State private var errorText: String?
    @State private var resultURL: URL?

    private var passwordOK: Bool {
        password.count >= 6 && password == confirm
    }

    var body: some View {
        NavigationStack {
            Form {
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
                        Text("也可以到「文件」App → 我的 iPad → BossAI → Exports 里找到它。换设备时把这个文件传过去，用同一个密码导入即可。")
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

/// 从备份导入
struct BackupImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
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
