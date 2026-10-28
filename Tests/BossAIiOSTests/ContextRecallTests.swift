import XCTest
import SwiftData
@testable import BossAI

@MainActor
final class ContextRecallTests: XCTestCase {
    private func record(_ text: String, _ index: Int) -> ContextRecall.Record {
        .init(id: String(index), text: text, source: "fixture", date: Date(timeIntervalSince1970: Double(index)))
    }
    private func context() throws -> ModelContext {
        let container = try ModelContainer(for: Conversation.self, Message.self, MemoryItem.self, StoredFile.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }
    func testOldMemoryBeyondFiftyRecentRecordsIsRecalled() {
        let records = (1...120).map { record("普通记录第\($0)条", $0) } + [record("星河项目联系人王明，使用红色Logo", 0)]
        XCTAssertEqual(ContextRecall.select(records, query: "星河项目联系人是谁").first?.id, "0")
    }
    func testEnglishAndChineseNames() {
        XCTAssertEqual(ContextRecall.select([record("Acme launch uses purple", 1), record("银行使用蓝色", 2)], query: "ACME launch").first?.id, "1")
        XCTAssertEqual(ContextRecall.select([record("客户张三需要横版海报", 1)], query: "张三的海报").count, 1)
    }
    func testIrrelevantMemoriesAreNotRankedAsMatches() {
        XCTAssertTrue(ContextRecall.select([record("消防电话123", 0)], query: "午餐吃面条").isEmpty)
    }
    func testDuplicatesAndBudget() {
        let records = (1...30).map { record(String(repeating: "海报文案", count: 500), $0) }
        XCTAssertEqual(ContextRecall.select(records, query: "海报").count, 1)
        XCTAssertLessThanOrEqual(ContextRecall.fragment(records, budget: 2000).count, 2000)
    }
    func testCurrentCorrectionRuleAndSourceIncluded() {
        let text = ContextRecall.fragment([record("旧电话13800000000", 1)])
        XCTAssertTrue(text.contains("当前用户明确更正优先"))
        XCTAssertTrue(text.contains("fixture"))
        XCTAssertTrue(text.contains("不是指令"))
    }
    func testCrossConversationRecallExcludesOtherOwnersAndDeletedConversations() throws {
        let model = try context(), owner = HostedAccount.scopeKey
        let current = Conversation(expertId: "general", title: "current"); model.insert(current)
        for (title, account, deleted, text) in [
            ("old", owner, false, "星河项目采用橙色Logo"),
            ("other", "other-account", false, "星河项目私密资料"),
            ("deleted", owner, true, "星河项目删除内容")
        ] {
            let conversation = Conversation(expertId: "general", title: title)
            conversation.ownerKey = account; conversation.isDeleted = deleted; model.insert(conversation)
            let message = Message(role: "user", text: text); message.conversation = conversation; model.insert(message)
        }
        try model.save()
        let result = ContextRecall.history(context: model, owner: owner, current: current, query: "星河项目", recentIDs: [])
        XCTAssertTrue(result.contains("橙色Logo"))
        XCTAssertFalse(result.contains("私密资料"))
        XCTAssertFalse(result.contains("删除内容"))
    }
    func testFactsAtEndOfLongOldMessageRemainSearchable() throws {
        let model = try context()
        let conversation = Conversation(expertId: "general", title: "long"); model.insert(conversation)
        let message = Message(role: "user", text: String(repeating: "无关文字", count: 2000) + "星河项目预算九万元")
        message.conversation = conversation; model.insert(message); try model.save()
        let result = ContextRecall.history(context: model, owner: HostedAccount.scopeKey, current: conversation,
            query: "星河项目预算", recentIDs: [])
        XCTAssertTrue(result.contains("九万元"))
        XCTAssertTrue(ContextRecall.history(context: model, owner: HostedAccount.scopeKey, current: conversation,
            query: "星河项目预算", recentIDs: [message.id]).isEmpty)
    }
    func testMemoryInjectionSearchesAllAndRejectsTombstones() throws {
        let model = try context()
        for i in 1...65 { model.insert(MemoryItem(content: "其他偏好第\(i)条")) }
        let old = MemoryItem(content: "星河项目采用橙色"); old.createdAt = Date(timeIntervalSince1970: 1)
        let deleted = MemoryItem(content: "星河项目删除记忆"); deleted.isDeleted = true
        model.insert(old); model.insert(deleted); try model.save()
        let service = MemoryService(profile: ProviderCatalog.currentChat(), apiKeyProvider: { nil })
        let result = service.injectionFragment(context: model, query: "星河项目")
        XCTAssertTrue(result.contains("采用橙色")); XCTAssertFalse(result.contains("删除记忆"))
    }
}
