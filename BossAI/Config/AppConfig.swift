import Foundation

/// 全局常量。服务商端点与模型见 Services/ProviderProfiles.swift（按 Key 自动识别）。
enum AppConfig {
    // MARK: Keychain
    static let keychainService = "com.bossai.credentials"
    static let chatKeyAccount = "chat_api_key"
    static let imageKeyAccount = "image_api_key"

    // MARK: 工具调用保护
    static let maxToolIterations = 6
    static let memoryInjectLimit = 50
}
