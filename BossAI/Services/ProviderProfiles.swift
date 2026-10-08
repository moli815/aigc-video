import Foundation

// MARK: - 服务商档案：粘贴 Key 后自动识别，无需手动选择

enum SearchStyle {
    case kimiBuiltin     // Kimi 内置 $web_search（服务端执行，客户端回显）
    case zhipuTool       // 智谱 web_search 工具（服务端执行）
    case dashscopeParam  // 阿里通义 enable_search 请求参数
    case volcTool        // 火山方舟 web_search 工具
    case none            // 无内置搜索（如 DeepSeek）
}

struct ChatProfile {
    let id: String
    let displayName: String
    let baseURL: String
    let model: String
    let memoryModel: String
    let searchStyle: SearchStyle
}

struct ImageProfile {
    enum Style { case volc, zhipu }
    let id: String
    let displayName: String
    let baseURL: String
    let model: String
    let style: Style
}

enum ProviderCatalog {
    /// 识别探测顺序即优先级（Key 格式相同的前几家靠 /models 探测结果区分）。
    /// DeepSeek 放首位：它也是「未识别到厂商」时的兜底，避免把 Key 打到别家导致 401
    static let chatCandidates: [ChatProfile] = [
        ChatProfile(id: "deepseek", displayName: "DeepSeek",
                    baseURL: "https://api.deepseek.com/v1",
                    model: "deepseek-flash", memoryModel: "deepseek-flash",
                    searchStyle: .none),
        ChatProfile(id: "kimi", displayName: "Kimi（Moonshot）",
                    baseURL: "https://api.moonshot.cn/v1",
                    model: "kimi-k2-0905-preview", memoryModel: "kimi-k2-0905-preview",
                    searchStyle: .kimiBuiltin),
        ChatProfile(id: "zhipu", displayName: "智谱 GLM",
                    baseURL: "https://open.bigmodel.cn/api/paas/v4",
                    model: "glm-4.6", memoryModel: "glm-4.6-air",
                    searchStyle: .zhipuTool),
        ChatProfile(id: "qwen", displayName: "通义千问（阿里）",
                    baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
                    model: "qwen-max", memoryModel: "qwen-plus",
                    searchStyle: .dashscopeParam),
        ChatProfile(id: "volc", displayName: "豆包（火山方舟）",
                    baseURL: "https://ark.cn-beijing.volces.com/api/v3",
                    model: "doubao-seed-2-1-pro-260915", memoryModel: "doubao-seed-2-1-pro-260915",
                    searchStyle: .volcTool),
    ]

    static let imageCandidates: [ImageProfile] = [
        ImageProfile(id: "volc", displayName: "火山引擎 Seedream",
                     baseURL: "https://ark.cn-beijing.volces.com/api/v3",
                     model: "doubao-seedream-4-0-20260415", style: .volc),
        ImageProfile(id: "zhipu", displayName: "智谱 CogView",
                     baseURL: "https://open.bigmodel.cn/api/paas/v4",
                     model: "cogview-4-250304", style: .zhipu),
    ]

    private static let chatProviderKey = "bossai.chat_provider"
    private static let imageProviderKey = "bossai.image_provider"
    private static let chatModelOverrideKey = "bossai.chat_model_override"
    private static let imageModelOverrideKey = "bossai.image_model_override"

    static func saveChatProvider(_ id: String) { UserDefaults.standard.set(id, forKey: chatProviderKey) }
    static func saveImageProvider(_ id: String) { UserDefaults.standard.set(id, forKey: imageProviderKey) }

    /// 清空已识别的服务商（换 Key 后触发重新识别）
    static func clearProviders() {
        UserDefaults.standard.removeObject(forKey: chatProviderKey)
        UserDefaults.standard.removeObject(forKey: imageProviderKey)
    }

    /// 自定义模型 ID（高级）：火山等厂商模型版本会更新，报 InvalidEndpointOrModel 时
    /// 让用户从控制台复制正确模型 ID 粘贴覆盖，无需重新编译
    static func saveChatModelOverride(_ s: String) { UserDefaults.standard.set(s, forKey: chatModelOverrideKey) }
    static func saveImageModelOverride(_ s: String) { UserDefaults.standard.set(s, forKey: imageModelOverrideKey) }
    static func chatModelOverride() -> String { UserDefaults.standard.string(forKey: chatModelOverrideKey) ?? "" }
    static func imageModelOverride() -> String { UserDefaults.standard.string(forKey: imageModelOverrideKey) ?? "" }

    /// 服务商是否已识别过（首次启动自动识别用）
    static var providersDetected: Bool {
        UserDefaults.standard.string(forKey: chatProviderKey) != nil &&
        UserDefaults.standard.string(forKey: imageProviderKey) != nil
    }

    /// 备份用：当前已识别的服务商 ID
    static func storedChatProviderId() -> String? {
        UserDefaults.standard.string(forKey: chatProviderKey)
    }
    static func storedImageProviderId() -> String? {
        UserDefaults.standard.string(forKey: imageProviderKey)
    }

    /// 读取已识别的档案；未识别过（旧版本数据）回落到 Kimi / 火山默认
    static func currentChat() -> ChatProfile {
        let id = UserDefaults.standard.string(forKey: chatProviderKey)
        var profile = chatCandidates.first { $0.id == id } ?? chatCandidates[0]
        let override = chatModelOverride()
        if !override.isEmpty {
            profile = ChatProfile(id: profile.id, displayName: profile.displayName,
                                  baseURL: profile.baseURL, model: profile.id == "deepseek" && ["deepseek-chat", "deepseek-reasoner"].contains(override) ? "deepseek-flash" : override,
                                  memoryModel: profile.memoryModel,
                                  searchStyle: override == profile.model ? profile.searchStyle : .none)
        }
        return profile
    }

    static func currentImage() -> ImageProfile {
        let id = UserDefaults.standard.string(forKey: imageProviderKey)
        var profile = imageCandidates.first { $0.id == id } ?? imageCandidates[0]
        let override = imageModelOverride()
        if !override.isEmpty {
            profile = ImageProfile(id: profile.id, displayName: profile.displayName,
                                   baseURL: profile.baseURL, model: override, style: profile.style)
        }
        return profile
    }
}

// MARK: - 月度额度（ChatGPT 式分池限额：对话 / 生图 各自独立）

enum BudgetTracker {
    // MARK: 额度设置（元/月）
    private static let chatLimitKey = "bossai.monthly_limit_chat_cny"
    private static let imageLimitKey = "bossai.monthly_limit_image_cny"
    private static let legacyLimitKey = "bossai.monthly_limit_cny"
    // MARK: 已用金额（跨月自动清零）
    private static let chatMonthKey = "bossai.budget_month_chat"
    private static let chatSpentKey = "bossai.spent_chat_cny"
    private static let imageMonthKey = "bossai.budget_month_image"
    private static let imageSpentKey = "bossai.spent_image_cny"

    /// 默认额度：对话 ¥100/月、生图 ¥40/月（0 = 不限）
    static let defaultChatLimit: Double = 100
    static let defaultImageLimit: Double = 40

    /// 对话额度
    static func chatLimit() -> Double {
        if let v = UserDefaults.standard.object(forKey: chatLimitKey) as? Double { return max(0, v) }
        // 兼容旧版单一预算：设置过旧键就沿用为对话额度
        if let legacy = UserDefaults.standard.object(forKey: legacyLimitKey) as? Double {
            let value = max(0, legacy)
            setChatLimit(value)
            return value
        }
        return defaultChatLimit
    }
    static func setChatLimit(_ v: Double) { UserDefaults.standard.set(max(0, v), forKey: chatLimitKey) }

    /// 生图额度
    static func imageLimit() -> Double {
        if let v = UserDefaults.standard.object(forKey: imageLimitKey) as? Double { return max(0, v) }
        return defaultImageLimit
    }
    static func setImageLimit(_ v: Double) { UserDefaults.standard.set(max(0, v), forKey: imageLimitKey) }

    private static func currentMonthKey() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM"; return f.string(from: Date())
    }

    /// 已用金额（元），跨月自动清零
    private static func spent(monthKey: String, spentKey: String) -> Double {
        let stored = UserDefaults.standard.string(forKey: monthKey) ?? ""
        if stored != currentMonthKey() {
            UserDefaults.standard.set(currentMonthKey(), forKey: monthKey)
            UserDefaults.standard.set(0.0, forKey: spentKey)
            return 0
        }
        return UserDefaults.standard.double(forKey: spentKey)
    }
    private static func addCost(_ cost: Double, monthKey: String, spentKey: String) {
        UserDefaults.standard.set(spent(monthKey: monthKey, spentKey: spentKey) + max(0, cost), forKey: spentKey)
    }

    static func chatSpent() -> Double { spent(monthKey: chatMonthKey, spentKey: chatSpentKey) }
    static func imageSpent() -> Double { spent(monthKey: imageMonthKey, spentKey: imageSpentKey) }

    static var chatExceeded: Bool {
        let l = chatLimit()
        return l > 0 && chatSpent() >= l
    }
    static var imageExceeded: Bool {
        let l = imageLimit()
        return l > 0 && imageSpent() >= l
    }

    /// 剩余额度百分比（0-100）；额度为 0（不限）时返回 nil，UI 据此隐藏
    static func chatRemainingPercent() -> Double? {
        let l = chatLimit()
        guard l > 0 else { return nil }
        return max(0, min(100, (l - chatSpent()) / l * 100))
    }
    static func imageRemainingPercent() -> Double? {
        let l = imageLimit()
        guard l > 0 else { return nil }
        return max(0, min(100, (l - imageSpent()) / l * 100))
    }

    // 兼容旧调用：全局判断与读写均映射到对话池
    static func isExceeded() -> Bool { chatExceeded }
    static func limit() -> Double { chatLimit() }
    static func setLimit(_ v: Double) { setChatLimit(v) }
    static func spent() -> Double { chatSpent() }

    /// 粗略估算 token 数（中文约 1.5 字符 1 token，够用于额度控制）
    static func estimateTokens(_ text: String) -> Int {
        max(1, Int(ceil(Double(text.count) / 1.5)))
    }

    /// 各家单价（元 / 百万 token，估算值，仅用于额度控制）
    private static func prices(providerId: String) -> (in: Double, out: Double) {
        switch providerId {
        case "volc": return (0.8, 8.0)
        case "deepseek": return (2.0, 8.0)
        case "zhipu": return (1.0, 4.0)
        case "qwen": return (0.8, 2.0)
        case "kimi": return (4.0, 16.0)
        default: return (2.0, 8.0)
        }
    }

    /// 对话类消耗计入对话池
    static func add(promptTokens: Int, completionTokens: Int, providerId: String) {
        let p = prices(providerId: providerId)
        let cost = (Double(promptTokens) / 1_000_000.0) * p.in + (Double(completionTokens) / 1_000_000.0) * p.out
        addCost(cost, monthKey: chatMonthKey, spentKey: chatSpentKey)
    }

    /// 生图按张估算（Seedream 等按张计费，统一估算单价 0.1 元/张）计入生图池
    static func addImageGeneration(_ count: Int = 1) {
        let perImage = 0.1
        addCost(Double(max(0, count)) * perImage, monthKey: imageMonthKey, spentKey: imageSpentKey)
    }

    /// 文档生成计费：按内容 token 估算（统一按 2 元/百万 token），走对话模型故计入对话池
    static func addDocument(_ content: String) {
        let tokens = estimateTokens(content)
        let cost = (Double(tokens) / 1_000_000.0) * 2.0
        addCost(max(0.01, cost), monthKey: chatMonthKey, spentKey: chatSpentKey)
    }

    /// 备份恢复用：直接写回对话池已用金额（并锁定到当前月份）
    static func restoreSpent(_ value: Double) {
        UserDefaults.standard.set(currentMonthKey(), forKey: chatMonthKey)
        UserDefaults.standard.set(max(0, value), forKey: chatSpentKey)
    }
}

// MARK: - 自动识别

enum ProviderDetector {
    /// 对话 Key：依次探测各厂商 /models，401=不属于这家，200=命中。
    /// 智谱 Key 形如 "id.secret"（含点号），火山方舟 Key 为 UUID 形态，先做格式预判提速。
    static func detectChat(key: String) async -> ChatProfile? {
        var candidates = ProviderCatalog.chatCandidates
        if key.contains(".") {
            candidates.sort { ($0.id == "zhipu" ? 0 : 1) < ($1.id == "zhipu" ? 0 : 1) }
        } else if isUUIDLike(key) {
            candidates.sort { ($0.id == "volc" ? 0 : 1) < ($1.id == "volc" ? 0 : 1) }
        }
        for profile in candidates {
            guard !Task.isCancelled else { return nil }
            if await probeModelsEndpoint(baseURL: profile.baseURL, key: key) {
                return profile
            }
        }
        return nil
    }

    /// 作图 Key：对各家 images/generations 发空请求，401/403=不属于这家，其余（400 等）=命中。
    static func detectImage(key: String) async -> ImageProfile? {
        var candidates = ProviderCatalog.imageCandidates
        if key.contains(".") {
            candidates.sort { ($0.id == "zhipu" ? 0 : 1) < ($1.id == "zhipu" ? 0 : 1) }
        } else if isUUIDLike(key) {
            candidates.sort { ($0.id == "volc" ? 0 : 1) < ($1.id == "volc" ? 0 : 1) }
        }
        for profile in candidates {
            guard !Task.isCancelled else { return nil }
            if await probeImageEndpoint(baseURL: profile.baseURL, key: key) {
                return profile
            }
        }
        return nil
    }

    /// 连接自检：两个 Key 各能落到哪家厂商，返回可直接展示的文案
    static func selfCheck(chatKey: String?, imageKey: String?) async -> String {
        var lines: [String] = []
        if let ck = chatKey, !ck.isEmpty {
            if let c = await detectChat(key: ck) {
                lines.append("✅ 对话：\(c.displayName)　模型 \(c.model)")
            } else {
                lines.append("❌ 对话 Key 没通过任何厂商校验（检查 Key 是否正确/是否欠费）")
            }
        } else {
            lines.append("❌ 对话 Key 为空")
        }
        if let ik = imageKey, !ik.isEmpty {
            if let i = await detectImage(key: ik) {
                lines.append("✅ 作图：\(i.displayName)　模型 \(i.model)")
            } else {
                lines.append("❌ 作图 Key 没通过任何厂商校验")
            }
        } else {
            lines.append("❌ 作图 Key 为空")
        }
        return lines.joined(separator: "\n")
    }

    private static func isUUIDLike(_ s: String) -> Bool {
        let parts = s.split(separator: "-")
        return parts.count == 5 && parts.allSatisfy { $0.allSatisfy { c in c.isHexDigit } }
    }

    private static func probeModelsEndpoint(baseURL: String, key: String) async -> Bool {
        guard let url = URL(string: "\(baseURL)/models") else { return false }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 8
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    private static func probeImageEndpoint(baseURL: String, key: String) async -> Bool {
        guard let url = URL(string: "\(baseURL)/images/generations") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = 8
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        // Empty-request validation is only a connectivity hint; not a successful image-generation test.
        return [200, 201, 400, 422].contains(http.statusCode) // 404/429/5xx are inconclusive, never authentication success
    }
}
