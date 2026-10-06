import Foundation
import SwiftUI

/// 换 Key / 重置后广播，让主界面重新识别服务商
extension Notification.Name {
    static let bossAIKeysChanged = Notification.Name("bossai.keys.changed")
}

/// 凭证状态与保存错误。设置仍可从隐藏入口修改。
@MainActor
final class CredentialStore: ObservableObject {
    @Published private(set) var chatKey: String?
    @Published private(set) var imageKey: String?
    @Published var saveError: String?

    var isConfigured: Bool {
        !(chatKey ?? "").isEmpty && !(imageKey ?? "").isEmpty
    }

    init() {
        if ProcessInfo.processInfo.arguments.contains("--render-fixture") || ProcessInfo.processInfo.arguments.contains("--performance-fixture") || ProcessInfo.processInfo.arguments.contains("--acceptance-fixture") || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        seedBakedKeys()
        reload()
    }

    /// 首次启动：把内置 Key 写入钥匙串（之后仍可在隐藏设置中修改）
    /// 保留既有用户凭证；仅为空账户写入测试种子，写入成功后置标志。
    private func seedBakedKeys() {
        let flag = "bossai.baked_seed_v3"
        if UserDefaults.standard.bool(forKey: flag) { return }
        var succeeded = true
        if KeychainHelper.read(service: AppConfig.keychainService, account: AppConfig.chatKeyAccount) == nil, !AppConfig.bakedChatKey.isEmpty {
            succeeded = KeychainHelper.save(AppConfig.bakedChatKey, service: AppConfig.keychainService, account: AppConfig.chatKeyAccount) && succeeded
        }
        if KeychainHelper.read(service: AppConfig.keychainService, account: AppConfig.imageKeyAccount) == nil, !AppConfig.bakedImageKey.isEmpty {
            succeeded = KeychainHelper.save(AppConfig.bakedImageKey, service: AppConfig.keychainService, account: AppConfig.imageKeyAccount) && succeeded
        }
        if succeeded { UserDefaults.standard.set(true, forKey: flag) }
    }

    func reload() {
        chatKey = KeychainHelper.read(service: AppConfig.keychainService, account: AppConfig.chatKeyAccount)
        imageKey = KeychainHelper.read(service: AppConfig.keychainService, account: AppConfig.imageKeyAccount)
    }

    func save(chatKey: String, imageKey: String) {
        let chatOK = KeychainHelper.save(chatKey, service: AppConfig.keychainService, account: AppConfig.chatKeyAccount)
        let imageOK = KeychainHelper.save(imageKey, service: AppConfig.keychainService, account: AppConfig.imageKeyAccount)
        saveError = chatOK && imageOK ? nil : "钥匙串写入失败，请重试；已保留原有凭证。"
        reload()
        if chatOK && imageOK { NotificationCenter.default.post(name: .bossAIKeysChanged, object: nil) }
    }

    /// 一键恢复为内置 Key（隐藏设置里用），并触发重新识别服务商
    func resetToBaked() {
        if !AppConfig.bakedChatKey.isEmpty {
            KeychainHelper.save(AppConfig.bakedChatKey, service: AppConfig.keychainService, account: AppConfig.chatKeyAccount)
        }
        if !AppConfig.bakedImageKey.isEmpty {
            KeychainHelper.save(AppConfig.bakedImageKey, service: AppConfig.keychainService, account: AppConfig.imageKeyAccount)
        }
        ProviderCatalog.clearProviders()
        reload()
        NotificationCenter.default.post(name: .bossAIKeysChanged, object: nil)
    }

    /// 隐藏入口：连点标题进入配置页时可调用（清空当前 Key，用于换号）
    func clear() {
        KeychainHelper.delete(service: AppConfig.keychainService, account: AppConfig.chatKeyAccount)
        KeychainHelper.delete(service: AppConfig.keychainService, account: AppConfig.imageKeyAccount)
        reload()
    }
}
