import Foundation
import Security

// KeychainHelper.swift —— iOS Keychain 极薄封装。
// 职责：为两个 API Key 提供 save / read / delete 三个原语。
// 在整个 App 中的角色：凭证持久化的唯一通道，CredentialStore 之下、Security 框架之上。
// 关键设计决策与防呆冗余：
// 1) save 先尝试 SecItemUpdate 再 SecItemAdd（"upsert"语义），避免重复项报
//    errSecDuplicateItem —— 直接 Add 在 Key 已存在时会失败。
// 2) 可访问性用 kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly：
//    设备解锁后即可读写（支持后台/锁屏请求），但禁止经 iCloud/iTunes 迁移到新设备，
//    换机即失效，缩小 Key 泄露面。
// 3) read 只取单条（kSecMatchLimitOne），返回值可选，调用方自行处理缺失。
// 4) delete 结果不检查：删除不存在的项本就是幂等操作，无需上报。

/// 极简 Keychain 读写，用于持久化两个 API Key。
enum KeychainHelper {
    /// 保存（upsert）：已存在则更新，不存在则新增。返回是否成功。
    @discardableResult
    static func save(_ value: String, service: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        /// 先更新既有项；仅当"项不存在"时才走新增路径，其他错误直接失败。
        /// 这样避免 SecItemAdd 撞上 errSecDuplicateItem 造成覆盖失败。
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var item = query
        item[kSecValueData as String] = data
        // ThisDeviceOnly：随设备锁定，不随 iCloud 备份迁移，换机后需重新配置 Key。
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    /// 读取指定项；不存在或解码失败返回 nil。
    static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 删除指定项；项不存在也视为成功（幂等）。
    static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
