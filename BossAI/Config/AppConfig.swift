import Foundation

// AppConfig.swift —— 全局配置常量中心。
// 职责：集中存放版本号、服务端点、内置 Key、Keychain 标识、工具调用与搜索限额等全局参数。
// 在整个 App 中的角色：无状态静态命名空间（enum 防实例化），各层按需读取。
// 关键设计决策：
// 1) 内置 Key 用 Base64 编码存放而非明文，降低包扫描/字符串转储直接暴露的风险；
//    真正的防线是 Keychain + 服务端持有（云端模式下 Key 不下发到客户端）。
// 2) 隐藏设置 PIN 属于轻度防误触手段，不承担安全边界职责。
// 3) 偏好类开关（preferProviderSearch、searchPageFetchCount）落 UserDefaults，
//    与 Keychain 中敏感凭证严格分离。
/// 全局常量。服务商端点与模型见 Services/ProviderProfiles.swift（按 Key 自动识别）。
enum AppConfig {
    // MARK: 构建版本标识
    // 10-24 P0：单一版本来源 = Bundle（值由 project.yml 的 MARKETING_VERSION /
    // CURRENT_PROJECT_VERSION 注入）。此前这里写死 "v1.2.0"，与 project.yml 的 "1.0"、
    // "2026100901" 三处不一致——服务端 minVersion 判定和崩溃归因都会错。

    /// 纯版本号（1.0 / 1.2.0），用于版本比较，绝不能混入构建号
    static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }

    /// 构建号（2026100901），用于崩溃归因与交付对账
    static var appBuild: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
    }

    /// 展示用：版本 + 构建号
    static var displayVersion: String {
        "\(appVersion)（\(appBuild)）"
    }

    // MARK: P0-46 版本比较（强制升级：云端下发 minVersion，本地低于则提示更新）
    /// 解析 "v1.2.0" / "1.2.0" / "1.2" 形式为数字三元组；无法解析返回 nil。
    static func versionComponents(_ v: String) -> (Int, Int, Int)? {
        let nums = v.lowercased()
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
        guard nums.count >= 1 else { return nil }
        return (nums[0], nums.count > 1 ? nums[1] : 0, nums.count > 2 ? nums[2] : 0)
    }
    /// current 是否低于 minimum（任一版本号格式不对返回 false，不打扰用户）。
    static func isVersion(_ current: String, lowerThan minimum: String) -> Bool {
        guard let c = versionComponents(current), let m = versionComponents(minimum) else { return false }
        return (c.0, c.1, c.2) < (m.0, m.1, m.2)
    }

    // MARK: 云端账号服务（会员制）
    /// 账号与 AI 中转服务的地址。App 只与它通信，模型 Key 全部由服务端持有。
    static let hostedAPIBase = "https://xmy-test-d5g8c0xcifcefcfd5-1449098021.ap-shanghai.app.tcloudbase.com/api"

    /// 10-24：备用入口（CloudBase 默认域名，同一环境）。主域名 DNS/网关故障时兜底。
    /// 备用地址必须内置在包里——不能由故障中的主域名下发，否则等于没有。
    static let hostedAPIBaseFallback = "https://xmy-test-d5g8c0xcifcefcfd5.service.tcloudbase.com/api"

    // MARK: 内置 Key（仅本人使用，写死在包内；如泄露可在各自平台重置）
    // 以 Base64 存放，避免明文入库被扫描；运行时解码。
    private static let bakedChatKeyB64 = ""
    private static let bakedImageKeyB64 = ""

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
    static let hiddenPIN = "132333"
    /// 触发方式：连点侧栏标题 N 次（单次间隔需小于 0.8 秒）
    static let hiddenTriggerTaps = 5

    // MARK: Keychain
    static let keychainService = "com.bossai.credentials"
    static let chatKeyAccount = "chat_api_key"
    static let imageKeyAccount = "image_api_key"

    // MARK: 工具调用保护
    /// 单次回答允许的工具调用轮次。
    /// 16 = 收集类任务（如「6 款旗舰机参数」）可以做到每个实体单独搜一次再汇总。
    static let maxToolIterations = 16
    /// 注入记忆条数上限：超出后按时间与命中数截断，防止 system prompt 无限膨胀。
    static let memoryInjectLimit = 50

    /// 支持时优先使用模型服务端搜索；无能力或服务端拒绝时由 App 搜索接管。
    static var preferProviderSearch: Bool {
        (UserDefaults.standard.object(forKey: "bossai.native_search_priority.v2") as? Bool) ?? true
    }
    static func setPreferProviderSearch(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "bossai.native_search_priority.v2")
    }

    /// 每次搜索自动抓取正文的网页数（0 = 只返回摘要）。
    /// 默认 3：参数/报价类信息往往分散在不同站点，只抓 2 篇容易缺字段。
    static var searchPageFetchCount: Int {
        let v = UserDefaults.standard.object(forKey: "bossai.search_page_fetch") as? Int
        return v ?? 3
    }
    static func setSearchPageFetchCount(_ n: Int) {
        UserDefaults.standard.set(n, forKey: "bossai.search_page_fetch")
    }
}
