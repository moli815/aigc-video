import SwiftData
import XCTest
@testable import BossAI

@MainActor
final class InstallUpgradeStoreTests: XCTestCase {
    private let owner = "install-audit-fixture"
    private let title = "升级前的园区巡检记录"
    private let message = "沿用原先的品牌资料"
    private let memory = "公司简称使用青禾"
    private let filename = "upgrade-asset.txt"
    private let bytes = Data("asset saved by the previous app".utf8)

    private func openStore() throws -> ModelContainer {
        try ModelContainer(for: Conversation.self, Message.self, MemoryItem.self, StoredFile.self)
    }

    func testOldReleaseWritesOfflineData() throws {
        let container = try openStore()
        let context = container.mainContext
        XCTAssertTrue(try context.fetch(FetchDescriptor<Conversation>()).isEmpty)
        let conversation = Conversation(expertId: "general", title: title)
        conversation.ownerKey = owner
        context.insert(conversation)
        let entry = Message(role: "user", text: message)
        entry.conversation = conversation
        entry.conversationID = conversation.id
        context.insert(entry)
        let item = MemoryItem(content: memory)
        item.ownerKey = owner
        context.insert(item)
        let file = try FileStore.store(data: bytes, filename: filename, kind: .uploaded, context: context)
        file.ownerKey = owner
        try context.save()
    }

    func testCandidateReadsOldReleaseData() throws {
        let container = try openStore()
        let context = container.mainContext
        let conversations = try context.fetch(FetchDescriptor<Conversation>()).filter { $0.ownerKey == owner }
        XCTAssertEqual(conversations.count, 1)
        let conv = try XCTUnwrap(conversations.first)
        XCTAssertEqual(conv.title, title)
        XCTAssertEqual(conv.messages.count, 1)
        XCTAssertEqual(conv.messages.first?.text, message)
        XCTAssertEqual(conv.messages.first?.conversationID, conv.id)
        let items = try context.fetch(FetchDescriptor<MemoryItem>()).filter { $0.ownerKey == owner }
        XCTAssertEqual(items.map(\.content), [memory])
        let files = try context.fetch(FetchDescriptor<StoredFile>()).filter { $0.ownerKey == owner }
        XCTAssertEqual(files.map(\.name), [filename])
        let file = try XCTUnwrap(files.first)
        XCTAssertEqual(try Data(contentsOf: FileStore.url(for: file)), bytes)
    }
}
