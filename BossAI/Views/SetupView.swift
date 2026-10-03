import SwiftUI

/// 首次启动的一次性凭证配置页：输入 Chat Key + Image Key。
/// 成功后写入 Keychain，页面从导航栈彻底移除，App 内不再出现任何登录入口。
struct SetupView: View {
    @EnvironmentObject var credentials: CredentialStore
    @State private var chatKey = ""
    @State private var imageKey = ""
    @State private var chatModelOverride = ""
    @State private var imageModelOverride = ""
    @State private var isDetecting = false
    @State private var detectError: String?

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
                    SecureField("Kimi / DeepSeek / 智谱 / 通义 / 豆包 均可", text: $chatKey)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("作图 API Key")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                    SecureField("火山引擎 Seedream / 智谱 CogView 均可", text: $imageKey)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                DisclosureGroup("高级设置（模型报 404 时才需要填）") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("自定义对话模型 ID").font(.footnote).foregroundStyle(.secondary)
                        TextField("留空使用默认", text: $chatModelOverride)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Text("自定义作图模型 ID").font(.footnote).foregroundStyle(.secondary)
                        TextField("留空使用默认", text: $imageModelOverride)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Text("火山方舟用户：模型需先在控制台「模型广场」开通；也可填推理接入点（ep-开头）。模型 ID 从控制台复制。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                .font(.subheadline)
                Text("粘贴后自动识别服务商，无需选择。Key 仅保存在本机钥匙串，不会上传。首次配置后此页面不再出现。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)

            Button {
                start()
            } label: {
                if isDetecting {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).tint(.white)
                        Text("正在识别服务商…")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                } else {
                    Text("开始使用")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isDetecting)
            .padding(.horizontal, 32)

            if let detectError {
                Text(detectError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()
            Spacer()
        }
        .accessibilityElement(children: .contain)
    }

    private func start() {
        let c = chatKey.trimmingCharacters(in: .whitespaces)
        let i = imageKey.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty, !i.isEmpty else {
            detectError = "请填写两个 API Key"
            return
        }
        detectError = nil
        isDetecting = true
        // 保存模型覆盖（留空即恢复默认）
        ProviderCatalog.saveChatModelOverride(chatModelOverride.trimmingCharacters(in: .whitespaces))
        ProviderCatalog.saveImageModelOverride(imageModelOverride.trimmingCharacters(in: .whitespaces))
        Task {
            async let chatProfile = ProviderDetector.detectChat(key: c)
            async let imageProfile = ProviderDetector.detectImage(key: i)
            let (chat, image) = await (chatProfile, imageProfile)
            isDetecting = false
            guard let chat else {
                detectError = "对话 Key 无法识别：请确认 Key 正确且对应平台已充值开通"
                return
            }
            guard let image else {
                detectError = "作图 Key 无法识别：请确认 Key 正确且已开通生图模型"
                return
            }
            ProviderCatalog.saveChatProvider(chat.id)
            ProviderCatalog.saveImageProvider(image.id)
            credentials.save(chatKey: c, imageKey: i)
        }
    }
}
