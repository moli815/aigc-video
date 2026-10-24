import XCTest
import SwiftData
@testable import BossAI

// ============================================================================
// 10-24 底座加固回归：账号作用域 / 同步墓碑 / 版本一致性 / 远程配置范围。
//
// 这些不变量一旦破掉，症状是「数据看起来消失」「删了又回来」「版本判定错」——
// 都是线上无法靠配置回滚修复的类型，所以必须有测试锁住。
// ============================================================================

@MainActor
final class FoundationHardeningTests: XCTestCase {

    private let profileKey = "bossai.hosted_profile_v1"
    private let hostedActiveKey = "bossai.hosted_active"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: profileKey)
        UserDefaults.standard.set(true, forKey: hostedActiveKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: profileKey)
        UserDefaults.standard.removeObject(forKey: hostedActiveKey)
        super.tearDown()
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Conversation.self, Message.self, StoredFile.self, MemoryItem.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func setProfile(_ dict: [String: Any]) {
        UserDefaults.standard.set(dict, forKey: profileKey)
    }

    // MARK: - 版本一致性

    /// appVersion 必须是纯数字点分格式：一旦掺进构建号或中文括号，
    /// versionComponents 会把构建号当成第三段，minVersion 判定直接错。
    func testAppVersionIsPureSemver() {
        let v = AppConfig.appVersion
        XCTAssertFalse(v.isEmpty)
        let parts = v.split(separator: ".")
        XCTAssertFalse(parts.isEmpty)
        for p in parts {
            XCTAssertNotNil(Int(p), "版本号每一段都必须是数字，当前：\(v)")
        }
    }

    /// displayVersion 必须同时带版本与构建号（崩溃归因要对得上安装包）
    func testDisplayVersionContainsBuild() {
        XCTAssertTrue(AppConfig.displayVersion.contains(AppConfig.appVersion))
        XCTAssertTrue(AppConfig.displayVersion.contains(AppConfig.appBuild))
    }

    /// 展示串含构建号，不能拿去比较；比较必须用纯版本号
    func testComparisonUsesPureVersion() {
        XCTAssertFalse(AppConfig.appVersion.contains("（"), "appVersion 不能含装饰字符")
        // displayVersion 里一定带括号（或至少与 appVersion 不同），它是给人看的
        XCTAssertNotEqual(AppConfig.displayVersion, AppConfig.appVersion)
    }

    // MARK: - 远程配置范围（客户端第二道闸）

    func testBehaviorIntRejectsOutOfRange() {
        setProfile(["streamRetry": 999])
        // 越界 → 回退默认，而不是裁成 5 或直接采用 999
        XCTAssertEqual(HostedAccount.cachedStreamRetry, 1)
    }

    func testBehaviorIntAcceptsInRange() {
        setProfile(["streamRetry": 2])
        XCTAssertEqual(HostedAccount.cachedStreamRetry, 2)
    }

    func testBehaviorDoubleRejectsAbsurdTimeout() {
        setProfile(["chatTimeout": 99999])   // 27 小时的"超时"
        XCTAssertEqual(HostedAccount.cachedChatTimeout, 120, accuracy: 0.01)
    }

    func testBehaviorDoubleAcceptsValidTimeout() {
        setProfile(["chatTimeout": 180])
        XCTAssertEqual(HostedAccount.cachedChatTimeout, 180, accuracy: 0.01)
    }

    // MARK: - 账号作用域

    /// 账号标识写进 profile 后必须能读回同一值，scopeKey 才会稳定
    func testCachedAccountNameRoundTrip() {
        UserDefaults.standard.set(["accountName": "kf001"], forKey: profileKey)
        XCTAssertEqual(HostedAccount.cachedAccountName, "kf001")
        XCTAssertEqual(HostedAccount.scopeKey, "hosted:kf001")
    }

    /// 真正的匿名场景（从未登录过）才允许 hosted-anonymous
    func testEmptyAccountNameIsAnonymous() {
        UserDefaults.standard.set(["accountName": ""], forKey: profileKey)
        XCTAssertEqual(HostedAccount.cachedAccountName, "")
        XCTAssertEqual(HostedAccount.scopeKey, "hosted-anonymous")
    }

    /// 核心回归：persistInfo 的空值保护不能把已有账号名抹掉。
    /// 走真实 reload → persistInfo 链路，确保冷启动后 scopeKey 与登录时一致。
    func testReloadPreservesAccountName() {
        setProfile(["accountName": "kf002", "displayName": "客服二"])
        let account = HostedAccount.shared
        account.reload()
        XCTAssertEqual(account.accountName, "kf002", "reload 未恢复 accountName")
        XCTAssertEqual(HostedAccount.scopeKey, "hosted:kf002")
        // 单例无法重建，手动清 profile 避免污染其它用例（实例属性留着不影响 scopeKey）
        UserDefaults.standard.removeObject(forKey: profileKey)
    }

    // MARK: - 记忆墓碑

    func testMemoryDefaultsNotDeleted() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let item = MemoryItem(content: "客户偏好：周五不安排会议")
        context.insert(item)
        try context.save()
        XCTAssertFalse(item.isDeleted)
    }

    /// 序列化必须带墓碑标记，否则跨设备删除推不出去
    func testEncodeMemoryCarriesTombstone() {
        let item = MemoryItem(content: "已作废的偏好")
        item.isDeleted = true
        let json = SyncService.encodeMemory(item)
        XCTAssertTrue(json.contains("\"isDeleted\":true"), "墓碑字段缺失：\(json)")
    }

    /// 会话序列化同样要带 isDeleted（新设备靠它避免复活已删会话）
    func testEncodeConversationCarriesDeletedFlag() {
        let conv = Conversation(expertId: "general", title: "已删会话")
        conv.isDeleted = true
        let json = SyncService.encodeConversation(conv)
        XCTAssertTrue(json.contains("\"isDeleted\":true"), "删除标记缺失：\(json)")
    }

    /// 墓碑不入注入片段：被删除的记忆不能继续污染提示词
    func testDeletedMemoryExcludedFromInjection() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let key = HostedAccount.scopeKey

        let kept = MemoryItem(content: "保留事实")
        kept.ownerKey = key
        let removed = MemoryItem(content: "已删除事实")
        removed.ownerKey = key
        removed.isDeleted = true
        context.insert(kept)
        context.insert(removed)
        try context.save()

        // MemoryService 没有单例：按 ChatViewModel 的用法构造（注入片段不触发网络）
        let service = MemoryService(profile: ProviderCatalog.currentChat(), apiKeyProvider: { nil })
        let fragment = service.injectionFragment(context: context)
        XCTAssertTrue(fragment.contains("保留事实"))
        XCTAssertFalse(fragment.contains("已删除事实"), "已删除记忆仍被注入：\(fragment)")
    }

    // MARK: - Provider 兜底

    func testProviderFallbacksExist() {
        XCTAssertFalse(ProviderCatalog.fallbackChat.id.isEmpty)
        XCTAssertFalse(ProviderCatalog.fallbackImage.id.isEmpty)
        XCTAssertTrue(ProviderCatalog.fallbackChat.baseURL.hasPrefix("https://"))
        XCTAssertTrue(ProviderCatalog.fallbackImage.baseURL.hasPrefix("https://"))
    }
}
