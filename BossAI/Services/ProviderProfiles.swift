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
    /// 识别探测顺序即优先级（Key 格式相同的前几家靠 /models 探测结果区分）
    static let chatCandidates: [ChatProfile] = [
        ChatProfile(id: "kimi", displayName: "Kimi（Moonshot）",
                    baseURL: "https://api.moonshot.cn/v1",
                    model: "kimi-k2-0905-preview", memoryModel: "kimi-k2-0905-preview",
                    searchStyle: .kimiBuiltin),
        ChatProfile(id: "deepseek", displayName: "DeepSeek",
                    baseURL: "https://api.deepseek.cn/v1",
                    model: "deepseek-chat", memoryModel: "deepseek-chat",
                    searchStyle: .none),
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
                    model: "doubao-seed-1-6-250615", memoryModel: "doubao-seed-1-6-flash-250615",
                    searchStyle: .volcTool),
    ]

    static let imageCandidates: [ImageProfile] = [
        ImageProfile(id: "volc", displayName: "火山引擎 Seedream 4.0",
                     baseURL: "https://ark.cn-beijing.volces.com/api/v3",
                     model: "doubao-seedream-4-0-250828", style: .volc),
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

    /// 自定义模型 ID（高级）：火山等厂商模型版本会更新，报 InvalidEndpointOrModel 时
    /// 让用户从控制台复制正确模型 ID 粘贴覆盖，无需重新编译
    static func saveChatModelOverride(_ s: String) { UserDefaults.standard.set(s, forKey: chatModelOverrideKey) }
    static func saveImageModelOverride(_ s: String) { UserDefaults.standard.set(s, forKey: imageModelOverrideKey) }
    static func chatModelOverride() -> String { UserDefaults.standard.string(forKey: chatModelOverrideKey) ?? "" }
    static func imageModelOverride() -> String { UserDefaults.standard.string(forKey: imageModelOverrideKey) ?? "" }

    /// 读取已识别的档案；未识别过（旧版本数据）回落到 Kimi / 火山默认
    static func currentChat() -> ChatProfile {
        let id = UserDefaults.standard.string(forKey: chatProviderKey)
        var profile = chatCandidates.first { $0.id == id } ?? chatCandidates[0]
        let override = chatModelOverride()
        if !override.isEmpty {
            profile = ChatProfile(id: profile.id, displayName: profile.displayName,
                                  baseURL: profile.baseURL, model: override,
                                  memoryModel: profile.memoryModel, searchStyle: profile.searchStyle)
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
            if await probeImageEndpoint(baseURL: profile.baseURL, key: key) {
                return profile
            }
        }
        return nil
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
        // 401/403 = 密钥不属于该厂商；400/404/422 等 = 认证通过但请求参数不全 → 命中
        return http.statusCode != 401 && http.statusCode != 403
    }
}
