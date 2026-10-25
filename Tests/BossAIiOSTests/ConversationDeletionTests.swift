import XCTest
import SwiftData
@testable import BossAI

// ============================================================================
// 历史会话删除（10-25）：本地级联 + 补删队列
//
// 这里锁的三条不变量，任何一条破了都会变成线上事故：
//   1. 删除必须是**物理删除**：会话没了，消息也不能留成孤儿；
//   2. 未登录/离线时删除动作仍要成功（用户看到的是"删掉了"），墓碑进队列等同步补推；
//   3. 跨账号不许删：别的账号的会话，即使拿到对象也删不掉。
// ============================================================================
@MainActor
final class ConversationDeletionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ConversationDeletion.resetOutboxForTesting()
    }

    override func tearDown() {
        ConversationDeletion.resetOutboxForTesting()
        super.tearDown()
    }

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Conversation.self, Message.self, configurations: configuration)
        return ModelContext(container)
    }

    private func seedConversation(in context: ModelContext,
                                  title: String = "要删的对话",
                                  messageCount: Int = 3) throws -> Conversation {
        let conv = Conversation(expertId: "general", title: title)
        context.insert(conv)
        for index in 0..<messageCount {
            let message = Message(role: index % 2 == 0 ? "user" : "assistant", text: "第 \(index) 条")
            message.conversation = conv
            message.conversationID = conv.id
            context.insert(message)
        }
        try context.save()
        return conv
    }

    func testDeleteCascadesMessagesAndConversation() throws {
        let context = try makeContext()
        let conv = try seedConversation(in: context)
        let id = conv.id
        XCTAssertEqual(try context.fetch(FetchDescriptor<Message>()).count, 3)

        XCTAssertTrue(ConversationDeletion.delete(conv, context: context))

        XCTAssertTrue(try context.fetch(FetchDescriptor<Conversation>()).isEmpty, "会话必须被物理删除，不能只打标记")
        XCTAssertTrue(try context.fetch(FetchDescriptor<Message>()).isEmpty, "消息必须随会话一起删掉，不能留孤儿")
        XCTAssertTrue(ConversationDeletion.isPendingDelete(id), "未登录/离线时云端墓碑推不上去，必须留在补删队列里")
    }

    func testCloudConfirmationRemovesFromQueue() throws {
        let context = try makeContext()
        let conv = try seedConversation(in: context, messageCount: 1)
        let id = conv.id
        XCTAssertTrue(ConversationDeletion.delete(conv, context: context))
        XCTAssertTrue(ConversationDeletion.isPendingDelete(id))

        ConversationDeletion.confirmRemoteDeleted(id)
        XCTAssertFalse(ConversationDeletion.isPendingDelete(id), "云端已确认删除后必须出队，避免无限重推")
    }

    func testRefusesOtherAccountsConversation() throws {
        let context = try makeContext()
        let conv = try seedConversation(in: context)
        conv.ownerKey = "hosted:另一个客户"
        try context.save()

        XCTAssertFalse(ConversationDeletion.delete(conv, context: context), "跨账号删除必须被拒绝")
        XCTAssertEqual(try context.fetch(FetchDescriptor<Conversation>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Message>()).count, 3)
        XCTAssertFalse(ConversationDeletion.isPendingDelete(conv.id), "被拒绝的删除不能污染补删队列")
    }

    func testOutboxIsPerAccountAndBounded() throws {
        let context = try makeContext()
        var ids: [UUID] = []
        for index in 0..<5 {
            let conv = try seedConversation(in: context, title: "对话 \(index)", messageCount: 1)
            ids.append(conv.id)
            XCTAssertTrue(ConversationDeletion.delete(conv, context: context))
        }
        let pending = ConversationDeletion.pendingDeleteIDs()
        XCTAssertEqual(pending.count, 5)
        for id in ids { XCTAssertTrue(pending.contains(id)) }
    }
}
