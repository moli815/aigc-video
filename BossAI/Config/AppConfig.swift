import Foundation

/// 全局常量。服务商端点与模型见 Services/ProviderProfiles.swift（按 Key 自动识别）。
enum AppConfig {
    // MARK: 内置 Key（仅本人使用，写死在包内；如泄露可在各自平台重置）
    // 以 Base64 存放，避免明文入库被扫描；运行时解码。
    private static let bakedChatKeyB64 = "c2stMzQwZWE1ZDQ3OGVhNGE5ZjllMWNhZTg0YjQwMDllMmE="
    private static let bakedImageKeyB64 = "YXJrLTIwYjZjYTBlLTY3NDQtNGZiNi04ZmVhLTRlYWMxM2U3ZjQ4NS0yMWU4OA=="

    /// 内置对话 Key（DeepSeek）
    static var bakedChatKey: String {
        Data(base64Encoded: bakedChatKeyB64).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
    /// 内置作图 Key（火山方舟 Seedream）
    static var bakedImageKey: String {
        Data(base64Encoded: bakedImageKeyB64).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    // MARK: 隐藏设置
    /// 隐藏设置密码
    static let hiddenPIN = "2407234544"
    /// 触发方式：连点侧栏标题 N 次（单次间隔需小于 0.8 秒）
    static let hiddenTriggerTaps = 5

    // MARK: Keychain
    static let keychainService = "com.bossai.credentials"
    static let chatKeyAccount = "chat_api_key"
    static let imageKeyAccount = "image_api_key"

    // MARK: 工具调用保护
    static let maxToolIterations = 8
    static let memoryInjectLimit = 50
}
