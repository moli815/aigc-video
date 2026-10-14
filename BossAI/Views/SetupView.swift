//
//  SetupView.swift
//  BossAI
//
//  首次启动配置页（Views 层）：
//  - 职责：一次性收集对话 API Key + 作图 API Key（可选高级项：额度、模型覆盖、联网搜索配置），
//    粘贴后自动识别服务商，保存到 Keychain 后本页从导航栈移除，App 内不再出现登录入口。
//  - 交互流程：粘贴 Key → 可选展开"高级设置"调额度/模型/搜索引擎 → 点"开始使用"→
//    并发探测两个 Key 对应厂商 → 全部通过才写入凭证；modal 模式下另有"连接自检"与"恢复内置 Key"。
//  - 关键设计决策与防呆/安全冗余：
//    1) 两个 Key 缺一不可（guard 校验），避免半配置状态下 App 运行异常。
//    2) 保存前先用 ProviderDetector 并发探测两个 Key（async let），探测失败即中止保存——
//       宁可拦截在入口，不让坏配置流入运行时。
//    3) Key 输入框用 SecureField + password contentType + 关闭自动纠错/大写，防 Key 被误改或泄露到键盘缓存。
//    4) Key 仅存本机 Keychain，不上传；页面文案明示这一点（信任设计）。
//    5) 额度语义：留空 = 恢复默认（对话 100 / 生图 40），0 = 不限——解析失败回退默认值，防呆。
//    6) isModal 模式保存成功后短暂展示"已保存"再自动收起，让用户确认操作已生效。
//

import SwiftUI

/// 首次启动的一次性凭证配置页：输入 Chat Key + Image Key。
/// 成功后写入 Keychain，页面从导航栈彻底移除，App 内不再出现任何登录入口。
struct SetupView: View {
    /// 凭证存储（Keychain 封装），读写与保存均通过它
    @EnvironmentObject var credentials: CredentialStore
    @Environment(\.dismiss) private var dismiss
    /// 从隐藏入口以 sheet 打开时显示关闭按钮，保存成功后自动收起
    var isModal = false
    // 以下为表单状态：Key、模型覆盖、额度、搜索配置，onAppear 时从现有配置预填
    @State private var chatKey = ""
    @State private var imageKey = ""
    @State private var chatModelOverride = ""
    @State private var imageModelOverride = ""
    @State private var chatBudget = ""
    @State private var imageBudget = ""
    /// 正在探测服务商（主按钮 loading 态）
    @State private var isDetecting = false
    /// 探测/保存失败信息
    @State private var detectError: String?
    /// modal 模式下保存成功标记
    @State private var saved = false
    /// 连接自检进行中
    @State private var checking = false
    /// 连接自检结果文案
    @State private var checkResult: String?
    // 联网搜索配置：onAppear 从全局服务预填，start() 时统一写回
    @State private var searchEngineKind: WebSearchEngine = WebSearchService.engine
    @State private var tavilyKey = WebSearchService.tavilyKey
    @State private var bochaKey = WebSearchService.bochaKey
    @State private var providerSearchOn = AppConfig.preferProviderSearch
    @State private var pageFetch = AppConfig.searchPageFetchCount

    /// 用当前已保存的配置预填全部表单项（Key 留空显示，不回显密钥明文以外的前次输入）
    private func prefill() {
        chatKey = credentials.chatKey ?? ""
        imageKey = credentials.imageKey ?? ""
        chatModelOverride = ProviderCatalog.chatModelOverride()
        imageModelOverride = ProviderCatalog.imageModelOverride()
        let cl = BudgetTracker.chatLimit()
        chatBudget = cl > 0 ? String(format: "%.0f", cl) : ""
        let il = BudgetTracker.imageLimit()
        imageBudget = il > 0 ? String(format: "%.0f", il) : ""
        searchEngineKind = WebSearchService.engine
        tavilyKey = WebSearchService.tavilyKey
        bochaKey = WebSearchService.bochaKey
        providerSearchOn = AppConfig.preferProviderSearch
        pageFetch = AppConfig.searchPageFetchCount
    }

    /// 页面主体：Logo → 双 Key 表单 → 高级设置折叠区 → 主按钮 → 结果反馈
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

            // 中防AI Logo
            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(ThemeStore.current.accentDeepGradient)
                        .frame(width: 84, height: 84)
                    Text("中")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                Text("中防AI")
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
                // 高级设置默认折叠：普通用户只填两个 Key 即可，降低上手门槛
                DisclosureGroup("高级设置（额度 / 模型报 404 时才需要填）") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("对话额度（元/月，0 = 不限，留空 = 恢复默认 100）").font(.footnote).foregroundStyle(.secondary)
                        TextField("100", text: $chatBudget)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.decimalPad)
                        Text("本月对话已用约 ¥\(String(format: "%.2f", BudgetTracker.chatSpent()))").font(.caption2).foregroundStyle(.secondary)
                        Text("生图额度（元/月，0 = 不限，留空 = 恢复默认 40）").font(.footnote).foregroundStyle(.secondary)
                        TextField("40", text: $imageBudget)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.decimalPad)
                        Text("本月生图已用约 ¥\(String(format: "%.2f", BudgetTracker.imageSpent()))；额度与已用每月 1 日自动清零")
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

                        Text("联网搜索（模型支持时优先内置搜索，否则使用 App 搜索）")
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

                        Toggle("优先使用模型内置搜索（支持时）", isOn: $providerSearchOn)
                            .font(.footnote)
                        Text("自定义模型未验证内置搜索能力时，使用 App 搜索；内置搜索未给出链接时会补查。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Stepper("每次自动阅读 \(pageFetch) 篇网页正文", value: $pageFetch, in: 0...4)
                            .font(.footnote)
                    }
                    .padding(.vertical, 4)
                }
                .font(.subheadline)
                // modal 模式专属：连接自检与"恢复内置 Key"，便于随时验证配置有效性
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

    /// 主按钮：开始使用（首次）/ 保存（modal），点击后进入 start() 探测与保存流程
            Button {
                start()
            } label: {
                // 探测中 / 就绪两种按钮态：探测期间禁用防重复点击
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
            .tint(ThemeStore.current.accentDeep)
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
            // 进页面先按已有配置预填；modal 模式额外自动跑一次自检
            prefill()
            if isModal { runSelfCheck() }
        }
    }

    /// 连接自检：两个 Key 分别能落到哪家厂商
    /// 同时验证联网搜索可用性，一次给出"Key + 搜索"的完整健康报告
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

    /// 探测并保存：先校验双 Key 非空 → 写额度/模型/搜索配置 → 并发探测两个 Key →
    /// 全部识别成功才写 Keychain；modal 模式下成功后展示"已保存"再自动关闭
    private func start() {
        let c = chatKey.trimmingCharacters(in: .whitespaces)
        let i = imageKey.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty, !i.isEmpty else {
            detectError = "请填写两个 API Key"
            return
        }
        detectError = nil
        isDetecting = true
        // 保存额度与模型覆盖（留空 = 恢复默认额度；填 0 = 不限）
        if let v = Double(chatBudget.trimmingCharacters(in: .whitespaces)) { BudgetTracker.setChatLimit(v) }
        else { BudgetTracker.setChatLimit(BudgetTracker.defaultChatLimit) }
        if let v = Double(imageBudget.trimmingCharacters(in: .whitespaces)) { BudgetTracker.setImageLimit(v) }
        else { BudgetTracker.setImageLimit(BudgetTracker.defaultImageLimit) }
        ProviderCatalog.saveChatModelOverride(chatModelOverride.trimmingCharacters(in: .whitespaces))
        ProviderCatalog.saveImageModelOverride(imageModelOverride.trimmingCharacters(in: .whitespaces))
        // 联网搜索设置
        WebSearchService.engine = searchEngineKind
        WebSearchService.tavilyKey = tavilyKey.trimmingCharacters(in: .whitespaces)
        WebSearchService.bochaKey = bochaKey.trimmingCharacters(in: .whitespaces)
        AppConfig.setPreferProviderSearch(providerSearchOn)
        AppConfig.setSearchPageFetchCount(pageFetch)
        Task {
            // 并发探测两个 Key：一次往返同时拿到对话/作图的厂商画像，节省等待时间
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
            // 两个 Key 都探测通过才写凭证：先存厂商再存 Key，保证配置一致性
            ProviderCatalog.saveChatProvider(chat.id)
            ProviderCatalog.saveImageProvider(image.id)
            credentials.save(chatKey: c, imageKey: i)
            if let error = credentials.saveError { detectError = error; return }
            if isModal {
                saved = true
                // 停留 0.7s 展示"已保存"再收起：给用户操作生效的明确反馈
                try? await Task.sleep(nanoseconds: 700_000_000)
                dismiss()
            }
        }
    }
}
