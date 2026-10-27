import XCTest
import SwiftData
@testable import BossAI

@MainActor
final class CloudFoundationTests: XCTestCase {
    private func context() throws -> ModelContext {
        let schema = Schema([Conversation.self, Message.self, MemoryItem.self, StoredFile.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        return container.mainContext
    }
    private func row(kind: String, _ payload: [String: Any], deleted: Bool = false) throws -> [String: Any] {
        ["kind": kind, "deleted": deleted, "payload": String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!]
    }
    func testCloudAssetsAndDerivativesSurviveMetadataRoundtrip() throws {
        let thumb = CloudAssetRef(id: String(repeating: "b", count: 40), sha256: String(repeating: "c", count: 64), mime: "image/jpeg", byteCount: 3)
        var original = CloudAssetRef(id: String(repeating: "a", count: 40), sha256: String(repeating: "d", count: 64), mime: "image/png", byteCount: 20)
        original.variants = ["thumbnail": thumb]
        XCTAssertEqual(CloudAssetStore.references(CloudAssetStore.encode([original])), [original])
        XCTAssertFalse(CloudAssetStore.encode([original]).contains("https://"))
    }
    func testMessagesSyncSeparatelyAndNeverSerializeBinaryImages() throws {
        let context = try context(), conv = Conversation(expertId: "general", title: "sample")
        conv.ownerKey = "test-owner"; context.insert(conv)
        let message = Message(role: "assistant", text: "hello", imageData: Data([1,2,3]))
        message.conversation = conv; message.conversationID = conv.id; context.insert(message)
        try context.save()
        let records = try SyncV2Engine.records(context: context, owner: "test-owner")
        let conversation = try XCTUnwrap(records.first { $0.kind == "conversation" })
        let sentMessage = try XCTUnwrap(records.first { $0.kind == "message" })
        XCTAssertFalse(conversation.payload.contains("messages"))
        XCTAssertTrue(sentMessage.payload.contains(conv.id.uuidString))
        XCTAssertFalse(sentMessage.payload.contains("AQID"))
        XCTAssertFalse(sentMessage.payload.contains("imageData"))
        XCTAssertTrue(try SyncV2Engine.records(context: context, owner: "other-owner").isEmpty)
    }
    func testExistingMessageReceivesRevisionsAndCloudImageReferences() throws {
        let context = try context(), conv = Conversation(expertId: "general", title: "existing")
        conv.ownerKey = "test-owner"; context.insert(conv)
        let message = Message(role: "assistant", text: "old"); message.conversation = conv
        message.conversationID = conv.id; context.insert(message); try context.save()
        let asset = CloudAssetRef(id: String(repeating: "a", count: 40), sha256: String(repeating: "d", count: 64), mime: "image/png", byteCount: 20)
        let assets = try JSONSerialization.jsonObject(with: JSONEncoder().encode([asset]))
        try SyncV2Engine.apply(try row(kind: "message", ["id": message.id.uuidString,
            "conversationId": conv.id.uuidString, "text": "new", "assets": assets, "createdAt": 1000]), context: context, owner: "test-owner")
        XCTAssertEqual(message.text, "new")
        XCTAssertEqual(CloudAssetStore.references(message.imageAssetsJSON), [asset])
        XCTAssertEqual(conv.messages.count, 1)
    }
    func testASecondOwnersSameUUIDIsNeverOverwritten() throws {
        let context = try context(), conv = Conversation(expertId: "general", title: "owner A")
        conv.ownerKey = "A"; context.insert(conv); try context.save()
        try SyncV2Engine.apply(try row(kind: "conversation", ["id": conv.id.uuidString,
            "title": "owner B", "createdAt": 1000, "updatedAt": 1000]), context: context, owner: "B")
        XCTAssertEqual(conv.title, "owner A")
        XCTAssertEqual(try context.fetch(FetchDescriptor<Conversation>()).count, 2)
    }
    func testCloudFileRestoresWithSafeLocalNameAndStableAssetReference() throws {
        let context = try context(), id = UUID()
        let asset = CloudAssetRef(id: String(repeating: "a", count: 40), sha256: String(repeating: "d", count: 64), mime: "application/pdf", byteCount: 20)
        let rawAsset = try JSONSerialization.jsonObject(with: JSONEncoder().encode(asset))
        try SyncV2Engine.apply(try row(kind: "file", ["id": id.uuidString, "name": "report.pdf",
            "ext": "../pdf", "asset": rawAsset, "createdAt": 1000]), context: context, owner: "A")
        let file = try XCTUnwrap(context.fetch(FetchDescriptor<StoredFile>()).first)
        XCTAssertFalse(file.storedName.contains("/"))
        XCTAssertEqual(CloudAssetStore.references(file.cloudAssetJSON), [asset])
    }
    func testWideRatiosStayWithinBudgetAndKeepTheirAspect() throws {
        for ratio in ["9:1", "1:9", "16:1", "1:16"] {
            let size = try XCTUnwrap(SeedreamSizeResolver.resolve(aspectRatio: ratio, tier: "2K"))
            let dimensions = size.split(separator: "x").compactMap { Int($0) }
            let sides = ratio.split(separator: ":").compactMap { Double($0) }
            XCTAssertEqual(dimensions.count, 2)
            let actual = Double(dimensions[0]) / Double(dimensions[1])
            XCTAssertLessThan(abs(actual / (sides[0] / sides[1]) - 1), 0.03)
            XCTAssertLessThanOrEqual(dimensions[0] * dimensions[1], ImageGeometry.maxPixels)
        }
        XCTAssertNil(SeedreamSizeResolver.resolve(aspectRatio: "17:1"))
    }
    func testSignedURLAllowlistRejectsCredentialAndLookalikeHosts() {
        XCTAssertTrue(CloudAssetStore.allowed(URL(string: "https://bucket.cos.ap-shanghai.myqcloud.com/file")!))
        XCTAssertFalse(CloudAssetStore.allowed(URL(string: "https://evilmyqcloud.com/file")!))
        XCTAssertFalse(CloudAssetStore.allowed(URL(string: "https://user:password@bucket.myqcloud.com/file")!))
        XCTAssertFalse(CloudAssetStore.allowed(URL(string: "http://bucket.myqcloud.com/file")!))
    }
}
