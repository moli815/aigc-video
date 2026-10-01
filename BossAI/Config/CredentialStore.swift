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
        reload()
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

    /// 隐藏入口：长按 Logo 5 秒重新打开配置页时调用（只读当前值回填，不删除）
    func clear() {
        KeychainHelper.delete(service: AppConfig.keychainService, account: AppConfig.chatKeyAccount)
        KeychainHelper.delete(service: AppConfig.keychainService, account: AppConfig.imageKeyAccount)
        reload()
    }
}
