import Foundation

/// 全局配置：端点、模型常量。UI 不暴露任何模型相关入口。
enum AppConfig {
    // MARK: 对话模型（Chat Key）
    /// 默认 Kimi（Moonshot）：国内直连、OpenAI 兼容协议、内置 $web_search 工具。
    /// 备选 DeepSeek：https://api.deepseek.cn/v1 ，模型 deepseek-chat（注意：DeepSeek 官方 API 无内置联网搜索）。
    static var chatBaseURL = "https://api.moonshot.cn/v1"
    static var chatModel = "kimi-k2-0905-preview"

    /// 记忆抽取用的轻量模型（成本可忽略）
    static var memoryModel = "kimi-k2-0905-preview"

    // MARK: 图像模型（Image Key）
    /// 火山引擎方舟：Seedream 4.0，OpenAI 兼容 images/generations 协议，国内直连。
    static var imageBaseURL = "https://ark.cn-beijing.volces.com/api/v3"
    static var imageModel = "doubao-seedream-4-0-250828"

    // MARK: Keychain
    static let keychainService = "com.bossai.credentials"
    static let chatKeyAccount = "chat_api_key"
    static let imageKeyAccount = "image_api_key"

    // MARK: 工具调用保护
    static let maxToolIterations = 6
    static let memoryInjectLimit = 50
}
