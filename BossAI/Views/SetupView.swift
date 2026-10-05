import SwiftUI

/// 首次启动的一次性凭证配置页：输入 Chat Key + Image Key。
/// 成功后写入 Keychain，页面从导航栈彻底移除，App 内不再出现任何登录入口。
struct SetupView: View {
    @EnvironmentObject var credentials: CredentialStore
    @Environment(\.dismiss) private var dismiss
    /// 从隐藏入口以 sheet 打开时显示关闭按钮，保存成功后自动收起
    var isModal = false
    @State private var chatKey = ""
    @State private var imageKey = ""
    @State private var chatModelOverride = ""
    @State private var imageModelOverride = ""
    @State private var budgetLimit = ""
    @State private var isDetecting = false
    @State private var detectError: String?
    @State private var saved = false
    @State private var checking = false
    @State private var checkResult: String?
    @State private var searchEngineKind: WebSearchEngine = WebSearchService.engine
    @State private var tavilyKey = WebSearchService.tavilyKey
    @State private var bochaKey = WebSearchService.bochaKey
    @State private var providerSearchOn = AppConfig.preferProviderSearch
    @State private var pageFetch = AppConfig.searchPageFetchCount

    private func prefill() {
        chatKey = credentials.chatKey ?? ""
        imageKey = credentials.imageKey ?? ""
        chatModelOverride = ProviderCatalog.chatModelOverride()
        imageModelOverride = ProviderCatalog.imageModelOverride()
        let l = BudgetTracker.limit()
        budgetLimit = l > 0 ? String(format: "%.0f", l) : ""
        searchEngineKind = WebSearchService.engine
        tavilyKey = WebSearchService.tavilyKey
        bochaKey = WebSearchService.bochaKey
        providerSearchOn = AppConfig.preferProviderSearch
        pageFetch = AppConfig.searchPageFetchCount
    }

    var body: some View {
        VStack(spacing: 32) {
            if isModal {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.trailing, 20)
                }
            }
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
                DisclosureGroup("高级设置（预算 / 模型报 404 时才需要填）") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("每月预算上限（元，0 = 不限）").font(.footnote).foregroundStyle(.secondary)
                        TextField("0", text: $budgetLimit)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.decimalPad)
                        Text("本月已用约 ¥\(String(format: "%.2f", BudgetTracker.spent()))，每月 1 日自动清零")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
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

                        Divider().padding(.vertical, 6)

                        Text("联网搜索（App 自带，与模型厂商无关）")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                        Picker("搜索引擎", selection: $searchEngineKind) {
                            ForEach(WebSearchEngine.allCases) { item in
                                Text(item.displayName).tag(item)
                            }
                        }
                        .pickerStyle(.menu)
                        Text("自动模式：先用下面的 API（若填写），失败自动回落到 Bing、百度。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Text("Tavily API Key（可选，免费额度）").font(.footnote).foregroundStyle(.secondary)
                        TextField("tvly-...", text: $tavilyKey)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)

                        Text("博查 API Key（可选，中文搜索质量好）").font(.footnote).foregroundStyle(.secondary)
                        TextField("sk-...", text: $bochaKey)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)

                        Toggle("同时启用模型商自带搜索（增强）", isOn: $providerSearchOn)
                            .font(.footnote)
                        Stepper("每次自动阅读 \(pageFetch) 篇网页正文", value: $pageFetch, in: 0...4)
                            .font(.footnote)
                    }
                    .padding(.vertical, 4)
                }
                .font(.subheadline)
                if isModal {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("连接自检")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            if checking { ProgressView().controlSize(.small) }
                        }
                        if let checkResult {
                            Text(checkResult)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(spacing: 16) {
                            Button {
                                runSelfCheck()
                            } label: {
                                Label("测试连接", systemImage: "bolt.horizontal.circle")
                                    .font(.footnote)
                            }
                            .disabled(checking)
                            Button {
                                credentials.resetToBaked()
                                prefill()
                                runSelfCheck()
                            } label: {
                                Label("恢复内置 Key", systemImage: "arrow.counterclockwise")
                                    .font(.footnote)
                            }
                        }
                    }
                }
                Text("粘贴后自动识别服务商，无需选择。Key 仅保存在本机钥匙串，不会上传。")
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
                    Text(isModal ? "保存" : "开始使用")
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
            } else if saved {
                Text("已保存")
                    .font(.footnote)
                    .foregroundStyle(.green)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()
            Spacer()
        }
        .accessibilityElement(children: .contain)
        .onAppear {
            prefill()
            if isModal { runSelfCheck() }
        }
    }

    /// 连接自检：两个 Key 分别能落到哪家厂商
    private func runSelfCheck() {
        checking = true
        checkResult = "正在检测…"
        Task {
            let c = chatKey.trimmingCharacters(in: .whitespaces)
            let i = imageKey.trimmingCharacters(in: .whitespaces)
            let result = await ProviderDetector.selfCheck(chatKey: c, imageKey: i)
            let hits = await WebSearchService.search(query: "今日新闻", count: 1)
            let searchLine = hits.isEmpty
                ? "❌ 联网搜索未返回结果（可换引擎或在下方填 Tavily / 博查 Key）"
                : "✅ 联网搜索可用（当前引擎：\(WebSearchService.engine.displayName)）"
            checkResult = result + "\n" + searchLine
            checking = false
        }
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
        // 保存预算与模型覆盖（留空即恢复默认/不限）
        let budgetText = budgetLimit.trimmingCharacters(in: .whitespaces)
        BudgetTracker.setLimit(Double(budgetText) ?? 0)
        ProviderCatalog.saveChatModelOverride(chatModelOverride.trimmingCharacters(in: .whitespaces))
        ProviderCatalog.saveImageModelOverride(imageModelOverride.trimmingCharacters(in: .whitespaces))
        // 联网搜索设置
        WebSearchService.engine = searchEngineKind
        WebSearchService.tavilyKey = tavilyKey.trimmingCharacters(in: .whitespaces)
        WebSearchService.bochaKey = bochaKey.trimmingCharacters(in: .whitespaces)
        AppConfig.setPreferProviderSearch(providerSearchOn)
        AppConfig.setSearchPageFetchCount(pageFetch)
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
            if let error = credentials.saveError { detectError = error; return }
            if isModal {
                saved = true
                try? await Task.sleep(nanoseconds: 700_000_000)
                dismiss()
            }
        }
    }
}
