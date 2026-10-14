import Foundation
import SwiftUI

// CredentialStore.swift —— API 凭证状态机（@MainActor 单例级 ObservableObject）。
// 职责：从 Keychain 读写对话/作图 Key，区分"云端账号模式"与"自备 Key 模式"。
// 在整个 App 中的角色：根视图登录态分支的依据之一（isConfigured），
// 所有发起 AI 请求的服务层都从这里取 Key。
// 防呆/安全冗余：
// 1) Key 只经 Keychain 中转，永不明文落盘（UserDefaults / 文件）。
// 2) 云端模式下 token 同时充当两种 Key，模型 Key 始终留在服务端，客户端零暴露。
// 3) 测试夹具/XCTest 环境直接跳过种子写入，防止测试污染真实 Keychain。
// 4) save 失败时保留旧凭证并给出可读错误，而不是半写状态静默成功。

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

    /// 是否具备可用凭据：云端账号模式看是否已登录；手动 Key 模式看两个 Key 是否齐全
    var isConfigured: Bool {
        if HostedAccount.isHostedActive { return HostedAccount.hasToken }
        return !(chatKey ?? "").isEmpty && !(imageKey ?? "").isEmpty
    }

    init() {
        // 夹具/单元测试环境直接返回：不写种子、不读 Keychain，保证测试可重复且无副作用。
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

    /// 重载内存中的 Key。云端模式用 token 替代，手动模式读 Keychain。
    func reload() {
        // 云端账号模式：会员 token 同时充当对话与作图的请求凭据（模型 Key 在服务端，不下发）
        if HostedAccount.isHostedActive, let token = HostedAccount.currentToken {
            chatKey = token
            imageKey = token
            return
        }
        chatKey = KeychainHelper.read(service: AppConfig.keychainService, account: AppConfig.chatKeyAccount)
        imageKey = KeychainHelper.read(service: AppConfig.keychainService, account: AppConfig.imageKeyAccount)
    }

    /// 保存两个 Key 到 Keychain；失败不覆盖已写入项，并广播 keysChanged。
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
