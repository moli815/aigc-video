import SwiftUI

/// 首次启动的一次性凭证配置页：输入 Chat Key + Image Key。
/// 成功后写入 Keychain，页面从导航栈彻底移除，App 内不再出现任何登录入口。
struct SetupView: View {
    @EnvironmentObject var credentials: CredentialStore
    @State private var chatKey = ""
    @State private var imageKey = ""
    @State private var showError = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Boss AI Logo
            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.accentColor.gradient)
                        .frame(width: 84, height: 84)
                    Text("B")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                Text("Boss AI")
                    .font(.largeTitle.bold())
                Text("企业经营者的 AI 顾问矩阵")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("对话 API Key")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                    SecureField("Kimi / DeepSeek 的 API Key", text: $chatKey)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("作图 API Key")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                    SecureField("火山引擎（Seedream）的 API Key", text: $imageKey)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Text("Key 仅保存在本机钥匙串，不会上传。首次配置后此页面不再出现。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)

            Button {
                let c = chatKey.trimmingCharacters(in: .whitespaces)
                let i = imageKey.trimmingCharacters(in: .whitespaces)
                if c.isEmpty || i.isEmpty {
                    showError = true
                } else {
                    credentials.save(chatKey: c, imageKey: i)
                }
            } label: {
                Text("开始使用")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 32)
            .alert("请填写两个 API Key", isPresented: $showError) {
                Button("好", role: .cancel) {}
            }

            Spacer()
            Spacer()
        }
        .accessibilityElement(children: .contain)
    }
}
