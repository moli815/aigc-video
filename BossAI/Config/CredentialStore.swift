import Foundation
import SwiftUI

/// 凭证状态：两个 Key 是否已配置。配置页只在未配置时出现，之后永久隐藏。
@MainActor
final class CredentialStore: ObservableObject {
    @Published private(set) var chatKey: String?
    @Published private(set) var imageKey: String?

    var isConfigured: Bool {
        !(chatKey ?? "").isEmpty && !(imageKey ?? "").isEmpty
    }

    init() {
        seedBakedKeys()
        reload()
    }

    /// 首次启动：把内置 Key 写入钥匙串（之后仍可在隐藏设置中修改）
    /// v2：本版本起强制覆盖一次——修复旧版本残留的无效 Key 导致 401
    private func seedBakedKeys() {
        let flag = "bossai.baked_seed_v2"
        if UserDefaults.standard.bool(forKey: flag) { return }
        if !AppConfig.bakedChatKey.isEmpty {
            KeychainHelper.save(AppConfig.bakedChatKey, service: AppConfig.keychainService, account: AppConfig.chatKeyAccount)
        }
        if !AppConfig.bakedImageKey.isEmpty {
            KeychainHelper.save(AppConfig.bakedImageKey, service: AppConfig.keychainService, account: AppConfig.imageKeyAccount)
        }
        UserDefaults.standard.set(true, forKey: flag)
    }

    func reload() {
        chatKey = KeychainHelper.read(service: AppConfig.keychainService, account: AppConfig.chatKeyAccount)
        imageKey = KeychainHelper.read(service: AppConfig.keychainService, account: AppConfig.imageKeyAccount)
    }

    func save(chatKey: String, imageKey: String) {
        KeychainHelper.save(chatKey, service: AppConfig.keychainService, account: AppConfig.chatKeyAccount)
        KeychainHelper.save(imageKey, service: AppConfig.keychainService, account: AppConfig.imageKeyAccount)
        reload()
    }

    /// 一键恢复为内置 Key（隐藏设置里用）
    func resetToBaked() {
        if !AppConfig.bakedChatKey.isEmpty {
            KeychainHelper.save(AppConfig.bakedChatKey, service: AppConfig.keychainService, account: AppConfig.chatKeyAccount)
        }
        if !AppConfig.bakedImageKey.isEmpty {
            KeychainHelper.save(AppConfig.bakedImageKey, service: AppConfig.keychainService, account: AppConfig.imageKeyAccount)
        }
        reload()
    }

    /// 隐藏入口：连点标题进入配置页时可调用（清空当前 Key，用于换号）
    func clear() {
        KeychainHelper.delete(service: AppConfig.keychainService, account: AppConfig.chatKeyAccount)
        KeychainHelper.delete(service: AppConfig.keychainService, account: AppConfig.imageKeyAccount)
        reload()
    }
}
