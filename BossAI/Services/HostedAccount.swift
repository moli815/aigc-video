import Foundation
import SwiftUI

// ============================================================================
// 文件职责：云端账号（会员制）会话中枢。
// 在 App 中的角色：整个 App 的身份与额度唯一数据源——登录、登出、token 持久化、
//   会员状态、档位（tier）、日/周/月三层额度、统一额度池、档位功能开关、
//   自助缴费、定时任务与云同步的网络接口都集中在这里。
// 关键设计决策：
//   1. 模型 API Key 全部由服务端持有，客户端只保存会员 token（防泄漏）；
//   2. @Published 实例属性供 SwiftUI 响应式更新，另提供一组 nonisolated 静态
//      「快照」属性走 UserDefaults，供非隔离上下文（请求构造、后台任务）同步读取；
//   3. token 存 Keychain，UserDefaults 只存布尔镜像标志与资料快照（非敏感）；
//   4. 所有网络失败一律转成用户可读的中文错误，401 统一强制登出。
// ============================================================================

/// 用量档位（服务端下发，不暴露具体金额）。
/// 刻意放在类型顶层：若嵌套在 @MainActor 类内部，嵌套类型会继承主线程隔离，
/// 导致 UI / 非隔离上下文无法直接读取。
enum HostedUsageBand: String {
    case normal, notice, limited
    /// 仅在「用量偏高 / 已超限」时给用户一句温和提示；正常时返回 nil，界面不打扰
    var noticeText: String? {
        switch self {
        case .normal: return nil
        case .notice: return "近期使用量较高，可能会稍作限速"
        case .limited: return "本次月度用量已达上限，请稍后再试或联系客服"
        }
    }
}

/// P0-38 对话档位选项（服务端 /me 下发；不含真实模型名，仅展示层使用）。
/// 设计要点：客户端永远不写死档位与文案——管理台改一句话，全端跟着变。
struct ChatModeOption: Identifiable, Equatable {
    let key: String          // standard / high / ultra
    let label: String        // 标准 / 高 / 最高
    let priceTier: String    // ¥ / ¥¥ / ¥¥¥（价格画像，不暴露具体模型价格）
    let speed: String        // 快 / 标准
    let strength: String     // 自动 / 最高
    let desc: String
    var id: String { key }

    /// 内置兜底：服务端未下发或字段缺失时使用（与云端默认值保持一致，保证功能永不空缺）
    static let fallback: [ChatModeOption] = [
        .init(key: "standard", label: "标准", priceTier: "¥", speed: "快", strength: "自动",
              desc: "日常问答与常规分析，响应更快"),
        .init(key: "high", label: "高", priceTier: "¥¥", speed: "标准", strength: "最高",
              desc: "复杂决策与多步推演，保留完整推理"),
        .init(key: "ultra", label: "最高", priceTier: "¥¥¥", speed: "标准", strength: "最高",
              desc: "看图识图、海报与长文档等最复杂任务"),
    ]

    /// 解析服务端下发的 chatModes 数组。
    /// 防呆：整体格式不对 → 回退内置三档；单条目缺 key → 丢弃该条；解析后为空 → 回退内置。
    static func parse(_ raw: Any?) -> [ChatModeOption] {
        guard let list = raw as? [[String: Any]], !list.isEmpty else { return fallback }
        let parsed = list.compactMap { item -> ChatModeOption? in
            guard let key = item["key"] as? String, !key.isEmpty else { return nil }
            return ChatModeOption(
                key: key,
                label: item["label"] as? String ?? key,
                priceTier: item["priceTier"] as? String ?? "¥",
                speed: item["speed"] as? String ?? "",
                strength: item["strength"] as? String ?? "",
                desc: item["desc"] as? String ?? ""
            )
        }
        return parsed.isEmpty ? fallback : parsed
    }
}

/// 云端账号会话：负责登录、token 持久化、会员状态与用量档位拉取。///
/// 设计要点：**模型 API Key 全部由服务端持有**，App 端只保存一个会员 token，
/// 这个 token 同时充当「请求凭据」，由 CredentialStore 暴露给 ChatService / ImageService。
@MainActor
final class HostedAccount: ObservableObject {

    /// 全局单例：账号状态全 App 唯一，避免多处各自拉取 /me 造成状态漂移
    static let shared = HostedAccount()

    /// 服务端时间统一是 ISO8601 **带毫秒**（如 2026-11-15T02:53:29.994Z）。
    /// 默认 ISO8601DateFormatter 不接受小数秒，`date(from:)` 会直接返回 nil ——
    /// 后果是会员到期日永远为空、侧栏把"没同步到"显示成"已过期"。这里带毫秒/不带毫秒都收。
    /// nonisolated：下面 `nonisolated static var cachedXxx` 也要用它，不能被 @MainActor 圈住
    nonisolated static func parseISO(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withMS = ISO8601DateFormatter()
        withMS.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withMS.date(from: trimmed) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: trimmed)
    }

    /// 档位 key → 展示名。登录响应只回 tier（没有 tierName），靠它先把徽章显示对。
    nonisolated static func displayName(forTier key: String) -> String {
        switch key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ultra": return "Ultra 旗舰版"
        case "pro":   return "Pro 专业版"
        case "plus":  return "Plus 基础版"
        default:      return key.isEmpty ? "会员" : key
        }
    }

    /// 登录前的持久化状态
    /// 会员 token（存在 Keychain；nil = 未登录）。private(set) 防止外部随意改写绕过 storeToken
    @Published private(set) var token: String?
    @Published private(set) var displayName: String = ""
    @Published private(set) var memberUntil: Date?
    @Published private(set) var chatBand: HostedUsageBand = .normal
    @Published private(set) var imageBand: HostedUsageBand = .normal
    /// 统一额度池（对话 + 作图 合并计费，服务端下发，对齐 ChatGPT 式单一用量概念）
    @Published private(set) var poolUsedCny: Double = 0
    @Published private(set) var poolCapCny: Double = 0
    @Published private(set) var poolBand: HostedUsageBand = .normal
    /// 分项消耗（P1-3 用量明细）：极速对话 / 深度对话 / 作图
    @Published private(set) var usedFlashCny: Double = 0
    @Published private(set) var usedProCny: Double = 0
    @Published private(set) var usedImageCny: Double = 0
    // P0-17 会员剩余天数（服务端返回，直接展示）
    @Published private(set) var daysLeft: Int?
    /// P0-19 档位功能开关（服务端单一数据源下发，App 不写死）
    @Published private(set) var features: [String: Any]?
    /// P0-59 云端能力声明（管理台可改）：补充说明 + 按 id 覆盖（enabled/limits）——能力声明云端化
    private(set) var capabilityExtra: String?
    private(set) var capabilityOverridesRaw: String?
    /// P0-64 App 远程行为配置（超时/重试次数，云端可调）
    private(set) var appBehavior: [String: Any]?
    /// P0-19 白标品牌名（Ultra 专属；默认"中防AI"）
    @Published private(set) var appName: String = "中防AI"
    // P0-16 数据隔离键所用的登录名（登录时确定，不随显示名变化）
    @Published private(set) var accountName: String = ""
    // P0-15 档位与三层额度（日/周/月）
    @Published private(set) var tier: String = "plus"
    @Published private(set) var tierName: String = "Plus 基础版"
    // P0-38 对话档位元数据（服务端下发：标准/高/最高 + 价格符号 + 说明；不含真实模型名）
    @Published private(set) var chatModes: [ChatModeOption] = ChatModeOption.fallback
    /// 服务端默认档位 key（当前为 standard）
    @Published private(set) var defaultChatMode: String = "standard"
    // P0-46 云端 UI/行为参数（/me 下发；改参数不出包）
    @Published private(set) var uiConfig: [String: Any] = [:]
    // P0-46 版本与更新（minVersion 非空且低于时客户端提示升级）
    @Published private(set) var appUpdate: [String: Any] = [:]
    @Published private(set) var dayRemainingPct: Double = 100
    @Published private(set) var weekRemainingPct: Double = 100
    @Published private(set) var monthRemainingPct: Double = 100
    @Published private(set) var dayResetAt: Date?
    @Published private(set) var weekResetAt: Date?
    @Published private(set) var monthResetAt: Date?
    /// 最近一次 /me 成功时间：侧栏用它区分"还没同步到"与"真的到期"
    @Published private(set) var lastRefreshAt: Date?
    /// 最近一次 /me 失败原因（成功即清空）。以前失败被静默吞掉，界面就把默认值当成真实状态展示。
    @Published private(set) var lastRefreshError: String?
    /// 单设备登录：账号在别处登录时，这里存放给用户看的提示（弹窗后清空）
    @Published var sessionReplacedNotice: String?
    @Published private(set) var refreshing = false
    /// 10-23 P0：会话代次。登录/登出/切换账号时递增；异步请求返回后若代次已变，
    /// 说明账号已切换，必须丢弃旧响应，不能修改当前账号状态或把当前账号登出。
    @Published private(set) var sessionGeneration: Int = 0

    /// 最近一次请求失败的原因（展示用）
    @Published var lastErrorMessage: String?

    nonisolated static let tokenAccount = "bf_auth_token"
    nonisolated private static let activeKey = "bossai.hosted_active"
    nonisolated private static let loggedInKey = "bossai.hosted_logged_in"
    private let infoKey = "bossai.hosted_profile_v1"

    var isLoggedIn: Bool { !(token ?? "").isEmpty }

    // MARK: - 供任意线程同步读取的静态入口
    // Keychain 与 UserDefaults 本身线程安全，这里刻意不碰任何 @Published 状态，
    // 以便 ChatService / ProviderCatalog 等非隔离上下文直接调用。

    /// 当前会员 token（未登录返回 nil）
    nonisolated static var currentToken: String? {
        let value = KeychainHelper.read(service: AppConfig.keychainService, account: tokenAccount)
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// 是否处于「云端账号」模式。默认开启；隐藏设置里可切回手动 Key 模式（自用调试）
    nonisolated static var isHostedActive: Bool {
        if UserDefaults.standard.object(forKey: activeKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: activeKey)
    }

    nonisolated static func setHostedActive(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: activeKey)
    }

    /// 是否已登录。这是 token 的**镜像标志**，走 UserDefaults（内存缓存，读取极快），
    /// 用于在 UI 绘制与请求构造等高频路径上避免反复读 Keychain。
    nonisolated static var hasToken: Bool {
        UserDefaults.standard.bool(forKey: loggedInKey)
    }

    // MARK: 供 SwiftUI 视图直接读取的只读快照（均走 UserDefaults，无 actor 隔离）

    private static let infoKeyLiteral = "bossai.hosted_profile_v1"

    /// 会员显示名（未登录返回空串）
    nonisolated static var cachedDisplayName: String {
        (UserDefaults.standard.dictionary(forKey: infoKeyLiteral)?["displayName"] as? String) ?? ""
    }

    /// 会员到期时间
    nonisolated static var cachedMemberUntil: Date? {
        guard let raw = UserDefaults.standard.dictionary(forKey: infoKeyLiteral)?["memberUntil"] as? String else { return nil }
        return Self.parseISO(raw)
    }

    /// 会员剩余天数（负数表示已过期）
    nonisolated static var cachedMemberDaysLeft: Int? {
        guard let until = cachedMemberUntil else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: until).day
    }

    /// 对话用量档位快照（供 UI 在非隔离上下文直接读取）
    nonisolated static var cachedChatBand: HostedUsageBand {
        HostedUsageBand(rawValue: (UserDefaults.standard.dictionary(forKey: infoKeyLiteral)?["chatBand"] as? String) ?? "") ?? .normal
    }

    /// 作图用量档位快照
    nonisolated static var cachedImageBand: HostedUsageBand {
        HostedUsageBand(rawValue: (UserDefaults.standard.dictionary(forKey: infoKeyLiteral)?["imageBand"] as? String) ?? "") ?? .normal
    }

    // MARK: 统一额度池快照（供侧栏额度环等 UI 在非隔离上下文直接读取）

    nonisolated static var cachedPoolUsedCny: Double {
        UserDefaults.standard.dictionary(forKey: infoKeyLiteral)?["poolUsedCny"] as? Double ?? 0
    }
    nonisolated static var cachedPoolCapCny: Double {
        UserDefaults.standard.dictionary(forKey: infoKeyLiteral)?["poolCapCny"] as? Double ?? 0
    }
    nonisolated static var cachedPoolBand: HostedUsageBand {
        HostedUsageBand(rawValue: (UserDefaults.standard.dictionary(forKey: infoKeyLiteral)?["poolBand"] as? String) ?? "") ?? .normal
    }
    /// 用量分项快照（P1-3 用量明细页）
    nonisolated static var cachedUsedFlashCny: Double {
        UserDefaults.standard.dictionary(forKey: infoKeyLiteral)?["usedFlashCny"] as? Double ?? 0
    }
    nonisolated static var cachedUsedProCny: Double {
        UserDefaults.standard.dictionary(forKey: infoKeyLiteral)?["usedProCny"] as? Double ?? 0
    }
    nonisolated static var cachedUsedImageCny: Double {
        UserDefaults.standard.dictionary(forKey: infoKeyLiteral)?["usedImageCny"] as? Double ?? 0
    }
    /// 池剩余百分比（0-100）；无上限配置时返回 nil，UI 据此隐藏
    nonisolated static var cachedPoolRemainingPercent: Double? {
        let cap = cachedPoolCapCny
        guard cap > 0 else { return nil }
        return max(0, min(100, (cap - cachedPoolUsedCny) / cap * 100))
    }

    // MARK: P0-15 档位与三层额度（供设置页直接读取）

    /// P0-16 当前数据作用域键：云端账号按登录名隔离；自备 Key 模式用固定键
    /// P0-19 功能开关：全量导出（Pro+）。自备 Key 模式恒为可用；云端按档位。
    /// P0-19 功能开关：深度研究增强（Pro+）。开启后单轮检索 8 主题 / 24K 证据（普通 5 / 16K）。
    /// P0-19 功能开关：自定义专家（Ultra）
    nonisolated static var cachedCustomExpertEnabled: Bool {
        if !isHostedActive { return false }
        return (UserDefaults.standard.dictionary(forKey: infoKeyLiteral)?["customExpert"] as? Bool) ?? false
    }

    nonisolated static var cachedAppName: String {
        if !isHostedActive { return "中防AI" }
        return (UserDefaults.standard.dictionary(forKey: infoKeyLiteral)?["appName"] as? String) ?? "中防AI"
    }

    /// P0-59 云端能力补充说明（可空）：管理台可改、30 秒生效——能力声明云端化（Hermes 式插件目录的第一步）。
    /// 追加进系统提示的能力清单（ToolRegistry.capabilityManifest 的 cloudExtra）。
    nonisolated static var cachedCapabilityExtra: String? {
        guard isHostedActive else { return nil }
        let v = UserDefaults.standard.dictionary(forKey: infoKeyLiteral)?["capabilityExtra"] as? String
        return (v?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? v : nil
    }

    /// P0-59 云端能力开关（JSON 字符串，可空）：形如 {"generate_image":{"enabled":false,"limits":["..."]}}
    /// App 端按 id 覆盖本地 ToolRegistry 声明的限界/开关，新能力调整无需出包。
    nonisolated static var cachedCapabilityOverrides: [String: Any]? {
        guard isHostedActive else { return nil }
        guard let raw = UserDefaults.standard.dictionary(forKey: infoKeyLiteral)?["capabilityOverrides"] as? String,
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    // MARK: P0-64 App 远程行为配置（在线可修复）——服务端 /me 下发，管理台改数即生效、不用出包

    // P0-77 通用行为配置读取（预留通道）：服务端 appBehavior 里的任意 key 都能读——
    // 以后新增云端参数（超时/开关/文案）只需服务端配置 + 调用 behaviorX，无需改解析代码。
    nonisolated static func behaviorValue(_ key: String) -> Any? {
        guard isHostedActive else { return nil }
        return UserDefaults.standard.dictionary(forKey: infoKeyLiteral)?[key]
    }
    /// 10-24：客户端第二道闸。服务端已有 min/max，但历史脏配置、绕过校验的写入、
    /// 以及未来新增 key 都可能带来越界值。越界时回退默认值而不是裁成边界值——
    /// 静默裁剪会得到一个"看起来正常但语义完全不同"的参数，更难排查。
    nonisolated private static let behaviorRanges: [String: ClosedRange<Double>] = [
        "chatTimeout": 10...600,
        "imageTimeout": 10...900,
        "chatFirstTokenTimeout": 5...600,
        "streamRetry": 0...5,
        "imageRetry": 0...5,
        "maxToolIterations": 1...20,
    ]

    nonisolated static func behaviorDouble(_ key: String, default def: Double) -> Double {
        let raw: Double?
        if let v = behaviorValue(key) as? NSNumber, v.doubleValue > 0 { raw = v.doubleValue }
        else if let s = behaviorValue(key) as? String, let d = Double(s), d > 0 { raw = d }
        else { raw = nil }
        guard let value = raw else { return def }
        if let range = behaviorRanges[key], !range.contains(value) {
            NSLog("[RemoteConfig] %@ 越界(%@)，回退默认 %@", key, String(value), String(def))
            return def
        }
        return value
    }
    nonisolated static func behaviorInt(_ key: String, default def: Int) -> Int {
        let raw: Int?
        if let v = behaviorValue(key) as? NSNumber, v.intValue >= 0 { raw = v.intValue }
        else if let s = behaviorValue(key) as? String, let i = Int(s), i >= 0 { raw = i }
        else { raw = nil }
        guard let value = raw else { return def }
        if let range = behaviorRanges[key], !range.contains(Double(value)) {
            NSLog("[RemoteConfig] %@ 越界(%d)，回退默认 %d", key, value, def)
            return def
        }
        return value
    }
    nonisolated static func behaviorBool(_ key: String, default def: Bool) -> Bool {
        if let v = behaviorValue(key) as? Bool { return v }
        if let s = behaviorValue(key) as? String { return !["0", "false", "no"].contains(s.lowercased()) }
        return def
    }
    /// 对话请求超时（秒）；云端可调，默认 120
    nonisolated static var cachedChatTimeout: TimeInterval { behaviorDouble("chatTimeout", default: 120) }
    /// 生图请求超时（秒）；云端可调，默认 180
    nonisolated static var cachedImageTimeout: TimeInterval { behaviorDouble("imageTimeout", default: 180) }
    /// 首 token 超时（秒）：流式开始后多久没收到首个 token 视为失败；云端可调，默认 45
    nonisolated static var cachedChatFirstTokenTimeout: TimeInterval { behaviorDouble("chatFirstTokenTimeout", default: 45) }
    /// 流式中断自动重试次数（0=关闭）；云端可调，默认 1
    nonisolated static var cachedStreamRetry: Int { behaviorInt("streamRetry", default: 1) }
    /// 生图失败重试次数（0=关闭）；云端可调，默认 1
    nonisolated static var cachedImageRetry: Int { behaviorInt("imageRetry", default: 1) }

    nonisolated static func behaviorString(_ key: String, default def: String) -> String {
        guard let v = behaviorValue(key) as? String, !v.isEmpty else { return def }
        return v
    }
    // P0-70 生图动效文案（云端可配）：管理台改文案，30 秒生效、不出包
    nonisolated static var cachedImgStage1: String { behaviorString("imgStage1", default: "正在绘制中...") }
    nonisolated static var cachedImgStage2: String { behaviorString("imgStage2", default: "正在绘制中...") }
    nonisolated static var cachedImgStage3: String { behaviorString("imgStage3", default: "正在绘制中...") }
    nonisolated static var cachedImgEta: String { behaviorString("imgEta", default: "AI 生成约需 1 分钟") }
    /// P0-74 生图后视觉验证（不符自动重试一次）；云端可关
    nonisolated static var cachedImageVerify: Bool {
        guard isHostedActive else { return false }
        let v = UserDefaults.standard.dictionary(forKey: infoKeyLiteral)?["imageVerify"] as? Bool
        return v ?? true
    }

    nonisolated static var cachedDeepResearchEnabled: Bool {
        if !isHostedActive { return false }   // 自备 Key 模式不放大成本
        return (UserDefaults.standard.dictionary(forKey: infoKeyLiteral)?["deepResearch"] as? Bool) ?? false
    }

    nonisolated static var cachedExportDocEnabled: Bool {
        if !isHostedActive { return true }
        return (UserDefaults.standard.dictionary(forKey: infoKeyLiteral)?["exportDoc"] as? Bool) ?? false
    }

    /// P0-19 功能开关：定时任务（Pro 3 个 / Ultra 10 个，上限服务端裁）。云端按档位。
    /// 服务端 features.schedules 是数量（0/3/10）而非布尔——统一走 NSNumber.boolValue，
    /// 防止 as? Bool 对非零数字的桥接歧义。
    nonisolated static var cachedSchedulesEnabled: Bool {
        if !isHostedActive { return false }
        let raw = UserDefaults.standard.dictionary(forKey: infoKeyLiteral)?["schedules"]
        return (raw as? NSNumber)?.boolValue ?? false
    }

    nonisolated static var cachedDaysLeft: Int? {
        guard let n = UserDefaults.standard.dictionary(forKey: infoKeyLiteral)?["daysLeft"] as? Int, n >= 0 else { return nil }
        return n
    }

    nonisolated static var cachedAccountName: String {
        (UserDefaults.standard.dictionary(forKey: infoKeyLiteral)?["accountName"] as? String) ?? ""
    }
    nonisolated static var scopeKey: String {
        if isHostedActive {
            let n = cachedAccountName
            return n.isEmpty ? "hosted-anonymous" : "hosted:" + n
        }
        return "local-apikey"
    }

    nonisolated static var cachedTier: String {
        (UserDefaults.standard.dictionary(forKey: infoKeyLiteral)?["tier"] as? String) ?? "plus"
    }
    nonisolated static var cachedTierName: String {
        (UserDefaults.standard.dictionary(forKey: infoKeyLiteral)?["tierName"] as? String) ?? "Plus 基础版"
    }
    nonisolated static var cachedDayRemainingPct: Double {
        (UserDefaults.standard.dictionary(forKey: infoKeyLiteral)?["dayRemainingPct"] as? Double) ?? 100
    }
    nonisolated static var cachedWeekRemainingPct: Double {
        (UserDefaults.standard.dictionary(forKey: infoKeyLiteral)?["weekRemainingPct"] as? Double) ?? 100
    }
    nonisolated static var cachedMonthRemainingPct: Double {
        (UserDefaults.standard.dictionary(forKey: infoKeyLiteral)?["monthRemainingPct"] as? Double) ?? 100
    }
    nonisolated static var cachedDayResetAt: Date? {
        (UserDefaults.standard.dictionary(forKey: infoKeyLiteral)?["dayResetAt"] as? String)
            .flatMap { Self.parseISO($0) }
    }
    nonisolated static var cachedWeekResetAt: Date? {
        (UserDefaults.standard.dictionary(forKey: infoKeyLiteral)?["weekResetAt"] as? String)
            .flatMap { Self.parseISO($0) }
    }
    nonisolated static var cachedMonthResetAt: Date? {
        (UserDefaults.standard.dictionary(forKey: infoKeyLiteral)?["monthResetAt"] as? String)
            .flatMap { Self.parseISO($0) }
    }

    /// 托管模式下是否已具备可用凭据
    nonisolated static var isReady: Bool {
        isHostedActive ? hasToken : true
    }

    /// 会员剩余天数（负数表示已过期）
    var memberDaysLeft: Int? {
        guard let until = memberUntil else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: until).day
    }

    /// 初始化：测试/截图夹具模式下跳过启动重载（避免测试环境读真实 Keychain），
    /// 正常启动时立即从本地缓存恢复登录态。
    private init() {
        if ProcessInfo.processInfo.arguments.contains("--render-fixture")
            || ProcessInfo.processInfo.arguments.contains("--performance-fixture")
            || ProcessInfo.processInfo.arguments.contains("--acceptance-fixture")
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        reload()
    }

    // MARK: - 本地持久化

    /// 启动时恢复本地登录态：从 Keychain 读 token、从 UserDefaults 读资料快照。
    /// 同时把「已登录」镜像标志与 Keychain 对齐（老版本升级时标志可能缺失）。
    func reload() {
        token = KeychainHelper.read(service: AppConfig.keychainService, account: Self.tokenAccount)
        // 每次启动把镜像标志与 Keychain 对齐（老版本升级上来时标志可能缺失）
        UserDefaults.standard.set(!(token ?? "").isEmpty, forKey: Self.loggedInKey)
        if let dict = UserDefaults.standard.dictionary(forKey: infoKey) {
            // 10-24 P0 修复：恢复 accountName。此前漏读这一项，冷启动后实例属性为空串，
            // 下一次 persistInfo() 会把空串写回 profile → scopeKey 退化为 hosted-anonymous，
            // 按 ownerKey 过滤的会话/记忆/文件全部"看不见"。
            let cachedAccount = (dict["accountName"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cachedAccount.isEmpty { accountName = cachedAccount }
            displayName = dict["displayName"] as? String ?? ""
            if let s = dict["memberUntil"] as? String {
                memberUntil = Self.parseISO(s)
            }
            chatBand = HostedUsageBand(rawValue: dict["chatBand"] as? String ?? "") ?? .normal
            imageBand = HostedUsageBand(rawValue: dict["imageBand"] as? String ?? "") ?? .normal
            poolUsedCny = dict["poolUsedCny"] as? Double ?? 0
            poolCapCny = dict["poolCapCny"] as? Double ?? 0
            poolBand = HostedUsageBand(rawValue: dict["poolBand"] as? String ?? "") ?? .normal
            usedFlashCny = dict["usedFlashCny"] as? Double ?? 0
            usedProCny = dict["usedProCny"] as? Double ?? 0
            usedImageCny = dict["usedImageCny"] as? Double ?? 0
        }
    }

    /// 把资料快照写入 UserDefaults（与 nonisolated 静态快照属性共用同一个 key），
    /// 供下次冷启动免网络恢复展示。
    private func persistInfo() {
        var dict: [String: Any] = [
            "displayName": displayName,
            "daysLeft": daysLeft ?? -1,
            "exportDoc": features?["exportDoc"] as? Bool ?? false,
            "deepResearch": features?["deepResearch"] as? Bool ?? false,
            "appName": appName,
            "customExpert": features?["customExpert"] as? Bool ?? false,
            "capabilityExtra": capabilityExtra ?? "",
            "capabilityOverrides": capabilityOverridesRaw ?? "",
            "chatTimeout": (appBehavior?["chatTimeout"] as? NSNumber)?.doubleValue ?? 120,
            "imageTimeout": (appBehavior?["imageTimeout"] as? NSNumber)?.doubleValue ?? 180,
            "streamRetry": (appBehavior?["streamRetry"] as? NSNumber)?.doubleValue ?? 1,
            "imageRetry": (appBehavior?["imageRetry"] as? NSNumber)?.doubleValue ?? 1,
            "imgStage1": (appBehavior?["imgStage1"] as? String) ?? "",
            "imgStage2": (appBehavior?["imgStage2"] as? String) ?? "",
            "imgStage3": (appBehavior?["imgStage3"] as? String) ?? "",
            "imgEta": (appBehavior?["imgEta"] as? String) ?? "",
            "imageVerify": (appBehavior?["imageVerify"] as? Bool) ?? true,
            // P0-77 通用行为通道：appBehavior 全量平铺写入（服务端加任何 APP_* 参数自动生效）
            // 注意：放在固定字段之后——固定字段优先，通用通道只补缺
        
            "chatBand": chatBand.rawValue,
            "imageBand": imageBand.rawValue,
            "poolUsedCny": poolUsedCny,
            "poolCapCny": poolCapCny,
            "poolBand": poolBand.rawValue,
            "usedFlashCny": usedFlashCny,
            "usedProCny": usedProCny,
            "usedImageCny": usedImageCny,
            "tier": tier,
            "tierName": tierName,
            "dayRemainingPct": dayRemainingPct,
            "weekRemainingPct": weekRemainingPct,
            "monthRemainingPct": monthRemainingPct,
        ]
        // 10-24 P0：账号标识为空时绝不覆盖已有有效值。
        // 冷启动未恢复 / 异常路径 / 服务端未回传 都可能让实例属性为空，
        // 一旦写回就成了数据作用域漂移的根源。
        let trimmedAccount = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAccount.isEmpty {
            dict["accountName"] = trimmedAccount
        } else {
            let previous = (UserDefaults.standard.dictionary(forKey: infoKey)?["accountName"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !previous.isEmpty { dict["accountName"] = previous }
        }
        // P0-77 通用行为通道：appBehavior 全量平铺（任意新 key 自动写入，无需改代码）
        if let ab = appBehavior {
            for (k, v) in ab where dict[k] == nil { dict[k] = v }
        }
        let iso = ISO8601DateFormatter()
        if let d = dayResetAt { dict["dayResetAt"] = iso.string(from: d) }
        if let w = weekResetAt { dict["weekResetAt"] = iso.string(from: w) }
        if let m = monthResetAt { dict["monthResetAt"] = iso.string(from: m) }
        if let until = memberUntil {
            dict["memberUntil"] = ISO8601DateFormatter().string(from: until)
        }
        UserDefaults.standard.set(dict, forKey: infoKey)
    }

    /// 统一的 token 写入/清除入口：Keychain 为真源，UserDefaults 只做镜像标志，
    /// 并广播凭据变更通知，让 ChatService 等持有旧 Key 的对象立即刷新。
    /// - Returns: 是否成功写入/清除；写入失败时返回 false，调用方必须中止登录流程。
    @discardableResult
    private func storeToken(_ value: String?) -> Bool {
        if let value, !value.isEmpty {
            // 10-22/10-23 可靠性：Keychain 写入失败时必须显式失败，否则会出现"显示已登录、重启后掉登录"
            let saved = KeychainHelper.save(value, service: AppConfig.keychainService, account: Self.tokenAccount)
            if !saved {
                token = nil
                UserDefaults.standard.set(false, forKey: Self.loggedInKey)
                lastErrorMessage = "登录凭证保存失败（系统钥匙串不可写），请重启 App 后重试"
                return false
            }
        } else {
            KeychainHelper.delete(service: AppConfig.keychainService, account: Self.tokenAccount)
        }
        // 同步镜像标志（供高频路径免 Keychain 读取）
        UserDefaults.standard.set(!(value ?? "").isEmpty, forKey: Self.loggedInKey)
        token = value
        // 通知凭据层重新读取（ChatService 的 apiKeyProvider 依赖它）
        NotificationCenter.default.post(name: .bossAIKeysChanged, object: nil)
        return true
    }

    // MARK: - 网络

    /// 内部网络封装：拼 URL、带 Bearer token、解析 JSON。
    /// 失败行为：网络层异常抛 .network；HTTP 非 2xx 时解析服务端 error/message 抛 .server；
    /// 401（已授权请求）视为会话失效——若服务端标记 SESSION_REPLACED 则记录"被顶下线"提示，
    /// 然后无条件强制登出（防止拿到过期 token 继续发请求）。
    private func request(_ path: String, method: String = "GET",
                         body: [String: Any]? = nil, authorized: Bool = true) async throws -> [String: Any] {
        // 10-23 P0：捕获发起请求时的会话代次与 token。await 期间若用户切换账号，
        // 返回后必须校验代次，防止旧账号的 401 把新账号登出，或旧 /me 覆盖新账号状态。
        let startGeneration = sessionGeneration
        let capturedToken = token
        guard let url = URL(string: AppConfig.hostedAPIBase + path) else {
            throw HostedError.network("服务地址无效")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authorized, let capturedToken, !capturedToken.isEmpty {
            req.setValue("Bearer \(capturedToken)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        req.timeoutInterval = 30

        let data: Data
        let http: HTTPURLResponse
        do {
            // 10-23 P3：所有会员 API 统一走受限网络客户端，限制单次响应体 10MB，避免异常大响应拖垮内存
            (data, http) = try await BoundedHTTPClient.data(for: req,
                                                            session: BoundedHTTPClient.chatSession,
                                                            limit: 10 * 1024 * 1024)
        } catch {
            throw HostedError.network("无法连接服务，请检查网络后重试")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        if !(200..<300).contains(http.statusCode) {
            let code = json["error"] as? String ?? "HTTP \(http.statusCode)"
            let message = json["message"] as? String
            // 会员 token 失效：直接清空登录态，UI 会回到登录页
            // 但仅在发起请求的账号仍当前账号时才执行登出，避免旧请求登出新账号
            if authorized, startGeneration == sessionGeneration,
               http.statusCode == 401 || ["MEMBERSHIP_EXPIRED", "ACCOUNT_SUSPENDED"].contains(code) {
                // P0-15 单设备：区分"被其他设备顶下线"与普通过期，给出明确提示
                lastErrorMessage = message ?? "登录状态已失效，请重新登录"
                await forceLogout()
                if code == "SESSION_REPLACED" {
                    sessionReplacedNotice = message ?? "账号已在其他设备登录，当前设备已退出"
                }
            }
            throw HostedError.server(code: code, status: http.statusCode, message: message)
        }
        return json
    }

    // MARK: - P0-14 会员自助缴费（App 内扫码 → 提交续费申请 → 管理员确认）

    /// 取收款信息（金额、收款码地址、当前到期时间）。失败返回 nil：UI 隐藏该区块，不打断其他功能。
    func fetchPaymentInfo() async -> [String: Any]? {
        (try? await request("/payment-info")) ?? nil
    }

    /// 会员自助提交续费申请（客户已扫码付款后点击"我已完成支付"）
    func submitSelfRenew() async throws -> [String: Any] {
        try await request("/renew-self", method: "POST", body: ["channel": "self"])
    }

    // MARK: - 登录 / 登出

    /// 登录：校验非空输入 → POST /login → 持久化 token 与资料 → 立即 refresh 拉额度。
    /// 参数 username/password：登录凭据（token 换取成功后不再在客户端留存）。
    /// 失败行为：抛 HostedError（输入校验失败 / 服务端拒绝），登录态保持未登录。
    func login(username: String, password: String) async throws {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !password.isEmpty else {
            throw HostedError.input("请输入账号与密码")
        }
        let json = try await request("/login", method: "POST",
                                     body: ["username": trimmed, "password": password],
                                     authorized: false)
        guard let newToken = json["token"] as? String, !newToken.isEmpty else {
            throw HostedError.server(code: "NO_TOKEN", status: 200, message: "服务未返回登录凭证")
        }
        // 10-23 P0：Keychain 写入失败必须阻断登录流程，不能继续更新账号元数据
        guard storeToken(newToken) else {
            throw HostedError.input("登录凭证保存失败（系统钥匙串不可写），请重启 App 后重试")
        }
        // 登录成功：递增会话代次，使此前账号的未决旧响应失效
        sessionGeneration &+= 1
        accountName = trimmed
        displayName = json["displayName"] as? String ?? trimmed
        // 登录响应只有 tier、没有 tierName：先把徽章显示对，别等 /me 回来才纠正
        if let t = json["tier"] as? String, !t.isEmpty {
            tier = t
            tierName = Self.displayName(forTier: t)
        }
        if let s = json["memberUntil"] as? String {
            memberUntil = Self.parseISO(s)
        }
        persistInfo()
        await refresh()
    }

    /// 登出：清空 token、资料与所有额度/档位缓存，并删除本地快照，
    /// 防止下一个账号登录后看到上一个账号的残留数据（隐私与数据隔离防呆）。
    func logout() {
        // 10-23 P0：登出/切换账号时递增会话代次，让未决旧请求返回后不再修改当前状态
        sessionGeneration &+= 1
        storeToken(nil)
        displayName = ""
        memberUntil = nil
        chatBand = .normal
        imageBand = .normal
        // P0-15 清理档位与三层额度缓存，避免下一个账号看到上一个账号的额度
        tier = "plus"
        tierName = "Plus 基础版"
        dayRemainingPct = 100
        weekRemainingPct = 100
        monthRemainingPct = 100
        dayResetAt = nil
        weekResetAt = nil
        monthResetAt = nil
        poolUsedCny = 0
        poolCapCny = 0
        poolBand = .normal
        usedFlashCny = 0
        usedProCny = 0
        usedImageCny = 0
        sessionReplacedNotice = nil
        daysLeft = nil
        accountName = ""
        // 10-23 P0：清理账号级远程配置，防止下一账号继承旧账号的 features/overrides/chatModes 等
        features = nil
        capabilityExtra = nil
        capabilityOverridesRaw = nil
        appBehavior = nil
        uiConfig = [:]
        appUpdate = [:]
        chatModes = ChatModeOption.fallback
        defaultChatMode = "standard"
        appName = "中防AI"
        // 10-23 P3：清空图片附件 data URL 缓存，避免旧账号图片 base64 被新账号请求误用
        ChatViewModel.invalidateImageURLCache()
        UserDefaults.standard.removeObject(forKey: infoKey)
    }

    /// 服务端判定 token 失效时的强制登出（避免递归调用 refresh）
    /// 云端会话失效（401 / 封停 / 到期）统一入口：记录原因并强制登出
    func handleSessionFailure(_ reason: String) {
        lastErrorMessage = reason
        Task { await forceLogout() }
    }

    private func forceLogout() async {
        // 10-22 修复：此前只清 token/band，displayName、tier、额度缓存全部残留——
        // 强制登出后侧栏仍显示上一个账号的信息。现统一复用 logout() 的完整清理。
        logout()
    }

    // MARK: - 状态刷新

    /// 拉取会员状态与用量（/me），刷新所有 @Published 状态后落盘。
    /// 防抖：refreshing 标志防止并发重复请求。
    /// 失败行为：静默吞掉（保留上次数据继续展示），401 已在 request 内统一处理。
    func refresh() async {
        guard isLoggedIn, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let startGeneration = sessionGeneration
        do {
            let json = try await request("/me")
            // 10-23 P0：await 期间若账号已切换，丢弃旧 /me 响应，不覆盖新账号状态
            guard startGeneration == sessionGeneration else { return }
            displayName = json["displayName"] as? String ?? displayName
            if let s = json["memberUntil"] as? String {
                memberUntil = Self.parseISO(s)
            }
            if let usage = json["usage"] as? [String: Any] {
                chatBand = HostedUsageBand(rawValue: usage["chat"] as? String ?? "") ?? .normal
                imageBand = HostedUsageBand(rawValue: usage["image"] as? String ?? "") ?? .normal
            if let pool = usage["pool"] as? [String: Any] {
                poolUsedCny = (pool["usedCny"] as? NSNumber)?.doubleValue ?? poolUsedCny
                poolCapCny = (pool["capCny"] as? NSNumber)?.doubleValue ?? poolCapCny
                poolBand = HostedUsageBand(rawValue: pool["band"] as? String ?? "") ?? poolBand
                if let byKind = pool["byKind"] as? [String: Any] {
                    usedFlashCny = (byKind["flash"] as? NSNumber)?.doubleValue ?? usedFlashCny
                    usedProCny = (byKind["pro"] as? NSNumber)?.doubleValue ?? usedProCny
                    usedImageCny = (byKind["image"] as? NSNumber)?.doubleValue ?? usedImageCny
                }
            }
            }
            if let d = (json["memberDaysLeft"] as? NSNumber)?.intValue { daysLeft = d }
            // P0-38 对话档位元数据（标准/高/最高；任何异常都回退内置三档，不会让配置面板空缺）
            if json["chatModes"] != nil { chatModes = ChatModeOption.parse(json["chatModes"]) }
            if let dm = json["defaultChatMode"] as? String, !dm.isEmpty { defaultChatMode = dm }
            // P0-46 云端 UI/行为参数 + 版本控制
            if let ui = json["uiConfig"] as? [String: Any] {
                uiConfig = ui
                ImageCompressor.applyCloudConfig(
                    edge: (ui["imageMaxEdge"] as? NSNumber).map { CGFloat($0.doubleValue) },
                    quality: (ui["imageQuality"] as? NSNumber).map { CGFloat($0.doubleValue) }
                )
            }
            if let au = json["appUpdate"] as? [String: Any] { appUpdate = au }
            // P0-59 能力声明云端化：补充说明与覆盖（新能力/边界调整云端配置即生效，无 App 出包）
            capabilityExtra = (json["capabilityExtra"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            // P0-64 App 远程行为配置（在线可修复）：超时/重试次数由云端下发
            if let ab = json["appBehavior"] as? [String: Any] { appBehavior = ab }
            if let ovObj = json["capabilityOverrides"],
               let ovData = try? JSONSerialization.data(withJSONObject: ovObj),
               let ovStr = String(data: ovData, encoding: .utf8) {
                capabilityOverridesRaw = ovStr
            }
            if let feats = json["features"] as? [String: Any] {
                features = feats
            }
            // P0-19 白标：品牌名（Ultra），为空用默认
            appName = (json["appName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "中防AI"
            // P0-15 档位与三层额度（日/周/月剩余百分比 + 重置时间）
            if let tierKey = json["tier"] as? String { tier = tierKey }
            tierName = json["tierName"] as? String ?? tierName
            if let limits = json["limits"] as? [String: Any] {
                func pick(_ key: String) -> (Double, Date?)? {
                    guard let node = limits[key] as? [String: Any] else { return nil }
                    let pct = (node["remainingPct"] as? NSNumber)?.doubleValue ?? 0
                    let reset = (node["resetAt"] as? String).flatMap { Self.parseISO($0) }
                    return (pct, reset)
                }
                if let d = pick("day") { dayRemainingPct = d.0; dayResetAt = d.1 }
                if let w = pick("week") { weekRemainingPct = w.0; weekResetAt = w.1 }
                if let m = pick("month") { monthRemainingPct = m.0; monthResetAt = m.1 }
            }
            lastRefreshAt = Date()
            lastRefreshError = nil
            persistInfo()
        } catch {
            // 刷新失败不打断使用；401 已在 request 内处理（会清登录态并弹"已在别处登录"）。
            // 但原因必须留下来：否则侧栏会把"没同步到"的默认值当成真实会员状态展示。
            // HostedError 已是 LocalizedError，直接用面向用户的文案（不要 String(describing:) 的枚举 dump）
            lastRefreshError = error.localizedDescription
        }
    }

    // MARK: - P0-15 档位与自助缴费

    /// 公开档位表（App 权益页渲染；改服务端即改全站）
    func fetchTiers() async -> [[String: Any]] {
        guard let json = try? await request("/tiers", authorized: false) else { return [] }
        return (json["tiers"] as? [[String: Any]]) ?? []
    }

    /// 自助缴费信息：所选档位金额、收款码地址、当前到期与三层额度
    func fetchPaymentInfo(tier: String) async -> [String: Any]? {
        (try? await request("/payment-info?tier=" + tier)) ?? nil
    }

    // MARK: - P0-19 自定义专家（Ultra）

    /// 云端自定义专家列表（Ultra 档位）。失败返回空数组，UI 显示空态即可。
    // MARK: - P0-35 海报生成（图文分离闭环）

    /// 生成一张"零乱码"海报：①请求服务端出**无文字底图**并返回排版文案；
    /// ②下载底图；③客户端用真实字体叠字（PosterComposer）——中文永不出错，改文案不用重新生图。
    /// - Parameters:
    ///   - title: 主标题（必填，服务端会校验）
    ///   - subtitle: 副标题（可空）
    ///   - bullets: 要点列表（最多 6 条）
    ///   - style: 风格描述（可空，走服务端默认商务风）
    /// - Throws: 网络失败/服务端拒绝/解码失败；调用方 toast 提示，不影响对话主流程。
    func renderPoster(title: String, subtitle: String, bullets: [String], style: String? = nil) async throws -> UIImage {
        guard let token, !token.isEmpty else { throw HostedError.network("未登录") }
        guard let url = URL(string: AppConfig.hostedAPIBase + "/poster") else {
            throw HostedError.network("服务地址无效")
        }
        var body: [String: Any] = ["title": title, "subtitle": subtitle, "bullets": bullets]
        if let style, !style.isEmpty { body["style"] = style }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        // 10-23 P3：海报生图链路用 imageSession，响应体限制 12MB；同时把 Session 资源超时提到 300s 与配置对齐

        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await BoundedHTTPClient.data(for: req,
                                                            session: BoundedHTTPClient.imageSession,
                                                            limit: 12 * 1024 * 1024)
        } catch {
            throw HostedError.network("网络异常，请检查连接后重试")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if http.statusCode != 200 {
            let msg = json["message"] as? String
            throw HostedError.server(code: json["error"] as? String ?? "POSTER_FAILED", status: http.statusCode, message: msg)
        }
        // 底图 URL → 下载 → 客户端叠字
        guard let baseURLString = json["imageUrl"] as? String, let baseURL = URL(string: baseURLString) else {
            throw HostedError.network("海报底图缺失，请重试")
        }
        guard let (imgData, imgResp) = try? await BoundedHTTPClient.data(for: URLRequest(url: baseURL),
                                                                         session: BoundedHTTPClient.imageSession,
                                                                         limit: 32 * 1024 * 1024),
              imgResp.statusCode == 200,
              let base = UIImage(data: imgData) else {
            throw HostedError.network("底图下载失败，请重试")
        }
        guard let composed = PosterComposer.compose(base: base, title: title, subtitle: subtitle, bullets: bullets) else {
            throw HostedError.network("文字合成失败")
        }
        return composed
    }
    /// 只要**无字底图**（名片走 BusinessCardRenderer 自己排版时用）。
    /// 与 renderPoster 的区别：不在客户端合成文字，返回服务端原图。
    func renderPosterBase(title: String, subtitle: String, bullets: [String], style: String? = nil) async throws -> UIImage {
        guard let token, !token.isEmpty else { throw HostedError.network("未登录") }
        guard let url = URL(string: AppConfig.hostedAPIBase + "/poster") else {
            throw HostedError.network("服务地址无效")
        }
        var body: [String: Any] = ["title": title, "subtitle": subtitle, "bullets": bullets]
        if let style, !style.isEmpty { body["style"] = style }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await BoundedHTTPClient.data(for: req,
                                                            session: BoundedHTTPClient.imageSession,
                                                            limit: 12 * 1024 * 1024)
        } catch {
            throw HostedError.network("网络异常，请检查连接后重试")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if http.statusCode != 200 {
            throw HostedError.server(code: json["error"] as? String ?? "POSTER_FAILED",
                                     status: http.statusCode, message: json["message"] as? String)
        }
        guard let baseURLString = json["imageUrl"] as? String, let baseURL = URL(string: baseURLString) else {
            throw HostedError.network("海报底图缺失，请重试")
        }
        guard let (imgData, imgResp) = try? await BoundedHTTPClient.data(for: URLRequest(url: baseURL),
                                                                         session: BoundedHTTPClient.imageSession,
                                                                         limit: 32 * 1024 * 1024),
              imgResp.statusCode == 200,
              let base = UIImage(data: imgData) else {
            throw HostedError.network("底图下载失败，请重试")
        }
        return base
    }

    // MARK: - P0-46 服务端记忆抽取（Mem0 式合并决策，算法云端化）

    /// 把"最近对话 + 已有记忆"发给服务端，由服务端产出 ADD/UPDATE/DELETE 合并决策。
    /// 好处：抽取策略/提示词改在服务端（不出包）；各端行为一致；失败静默返回空（抽取是增强，不阻塞）。
    /// - Returns: ops 数组，元素形如 {op:"add|update|delete", content, index}
    func extractMemories(dialogue: String, existing: [String]) async -> [[String: Any]] {
        guard let token, !token.isEmpty, let url = URL(string: AppConfig.hostedAPIBase + "/memories/extract") else {
            return []
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["dialogue": dialogue, "existing": existing])
        // 10-23 P3：记忆抽取走受限网络客户端，响应体限制 2MB
        guard let (data, resp) = try? await BoundedHTTPClient.data(for: req,
                                                                   session: BoundedHTTPClient.chatSession,
                                                                   limit: 2 * 1024 * 1024),
              resp.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ops = json["ops"] as? [[String: Any]] else { return [] }
        return ops
    }

    func fetchCustomExperts() async -> [[String: Any]] {        guard let json = try? await request("/custom-experts") else { return [] }
        return (json["list"] as? [[String: Any]]) ?? []
    }

    /// 新建自定义专家（名称 / 副标题 / 知识库正文）。失败抛 HostedError。
    func createCustomExpert(name: String, subtitle: String, knowledge: String) async throws {
        _ = try await request("/custom-experts", method: "POST",
                              body: ["name": name, "subtitle": subtitle, "knowledge": knowledge])
    }

    /// 删除自定义专家。失败抛 HostedError。
    func deleteCustomExpert(id: String) async throws {
        _ = try await request("/custom-experts/" + id, method: "DELETE")
    }

    // MARK: - P0-19 定时任务（Pro 3 / Ultra 10）

    /// 定时任务列表（含配额）。失败返回空字典。
    func fetchSchedules() async -> [String: Any] {
        (try? await request("/schedules")) ?? [:]
    }

    /// 新建定时任务：type=任务类型（早报/周报等），hour=触发小时（0-23）。
    /// 顺带上报身份快照供简报个性化。失败抛 HostedError。
    func createSchedule(type: String, hour: Int) async throws -> [String: Any] {
        let identity = UserIdentity.load()
        return try await request("/schedules", method: "POST", body: [
            "type": type, "hour": hour,
            // 身份快照：简报个性化用
            "name": identity.name.isEmpty ? displayName : identity.name,
            "company": identity.company, "industry": identity.industry, "role": identity.role,
        ])
    }

    /// 删除定时任务。失败抛 HostedError。
    func deleteSchedule(id: String) async throws {
        _ = try await request("/schedules/" + id, method: "DELETE")
    }

    /// P0-19 简报生成：一次非流式对话（服务端正常记账，走会员额度）
    func chatOnce(prompt: String) async throws -> String {
        let json = try await request("/chat/completions", method: "POST", body: [
            "messages": [["role": "user", "content": prompt]],
            "stream": false,
        ])
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String, !content.isEmpty else {
            throw HostedError.server(code: "EMPTY_REPLY", status: 502, message: "简报生成返回为空")
        }
        return content
    }

    /// P0-18 云端同步：推送本地条目（服务端按 last-write-wins 合并）
    func syncPush(items: [String: Any]) async throws -> [String: Any] {
        try await request("/sync/push", method: "POST", body: items)
    }

    /// P0-18 云端同步：增量拉取（since 为毫秒时间戳）。
    /// 10-24：支持分页——服务端每页最多 limit 条，用 nextCursor 续页；
    /// 不传 limit 时服务端按 500 返回（兼容旧行为）。
    func syncPull(since: Int, limit: Int? = nil, cursor: String? = nil) async throws -> [String: Any] {
        var path = "/sync/pull?since=\(since)"
        if let limit { path += "&limit=\(limit)" }
        if let cursor, !cursor.isEmpty {
            // 游标是 base64url，可能含 - _，必须做 URL 编码
            let escaped = cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cursor
            path += "&cursor=\(escaped)"
        }
        return try await request(path)
    }

    /// 10-25 历史会话删除：云端写墓碑（服务端校验归属 + 幂等，重复删除不报错）。
    /// id 只接受 UUID（由 App 侧会话主键生成，天然路径安全，无需再做百分号编码）。
    /// 失败抛 HostedError：调用方据此把 id 留在「补删队列」里，下次同步重试。
    @discardableResult
    func deleteConversation(id: UUID) async throws -> [String: Any] {
        try await request("/sync/conversations/" + id.uuidString, method: "DELETE")
    }

    /// 会员自助提交续费申请（带档位标签）
    func submitSelfRenew(tier: String) async throws -> [String: Any] {
        try await request("/renew-self", method: "POST", body: ["tier": tier])
    }

    // MARK: - 修改密码

    /// 修改密码：old=原密码，new=新密码（客户端先做最短 6 位预检，服务端再做正式校验）。
    /// 失败抛 HostedError（原密码错误等）。
    func changePassword(old: String, new: String) async throws {
        guard old.count >= 1, new.count >= 6 else {
            throw HostedError.input("新密码至少 6 位")
        }
        _ = try await request("/change-password", method: "POST",
                              body: ["oldPassword": old, "newPassword": new])
    }
}

// MARK: - 错误

/// 云端服务错误的统一封装：错误码由服务端下发，客户端只负责映射成
/// 用户可读的中文文案（不透出上游厂商/技术细节）。
enum HostedError: LocalizedError {
    /// 输入校验失败（客户端侧）
    case input(String)
    /// 网络不可达 / 连接失败
    case network(String)
    /// 服务端返回的业务错误：code 为机器可读错误码，message 为服务端中文消息
    case server(code: String, status: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .input(let m): return m
        case .network(let m): return m
        case .server(let code, let status, let message):
            switch code {
            case "BAD_CREDENTIALS": return "账号或密码不正确"
            case "ACCOUNT_SUSPENDED": return "该账号已停用，请联系客服"
            case "MEMBERSHIP_EXPIRED": return "会员已到期，请联系续费"
            case "QUOTA_EXCEEDED": return "近期使用量较高，请稍后再试"
            case "OUT_OF_SERVICE_HOURS": return message ?? "当前非服务时段"
            case "UPSTREAM_NOT_CONFIGURED": return "服务暂未就绪，请联系管理员"
            case "UPSTREAM_ERROR": return "模型服务暂时不可用，请稍后重试"
            default:
                if let message, !message.isEmpty { return message }
                return "请求失败（\(status)）"
            }
        }
    }
}
