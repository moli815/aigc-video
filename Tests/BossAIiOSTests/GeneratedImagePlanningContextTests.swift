import XCTest
import SwiftData
import UIKit
import ImageIO
@testable import BossAI

@MainActor
final class GeneratedImagePlanningContextTests: XCTestCase {
    private func image(_ color: UIColor, size: CGSize = CGSize(width: 100, height: 80)) -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill(); context.fill(CGRect(origin: .zero, size: size))
        }.pngData()!
    }
    private func model() throws -> (ChatViewModel, Conversation) {
        let container = try ModelContainer(for: Conversation.self, Message.self, StoredFile.self, MemoryItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let service = ChatService(profile: ChatProfile(id: "fixture", displayName: "Fixture", baseURL: "https://fixture.invalid/v1",
            model: "fixture", memoryModel: "fixture", searchStyle: .none), apiKeyProvider: { "fixture" })
        let vm = ChatViewModel(conversation: nil, expert: ExpertCatalog.general, modelContext: context,
            chatKey: { "fixture" }, imageKey: { nil }, chatService: service, searchPlanner: { _, _ in nil })
        return (vm, try vm.ensureConversation())
    }
    private func add(_ role: String, _ text: String, at second: Double, data: Data? = nil,
                     to conv: Conversation, vm: ChatViewModel) -> Message {
        let message = Message(role: role, text: text, imageData: data)
        message.createdAt = Date(timeIntervalSince1970: 1_700_000_000 + second)
        message.conversation = conv; message.conversationID = conv.id
        vm.modelContext.insert(message)
        return message
    }
    private func attachment(_ bytes: Data, vm: ChatViewModel) throws -> StoredFile {
        FileStore.prepare()
        let stored = StoredFile(name: "logo.png", ext: "png", storedName: UUID().uuidString + ".png",
            kind: .uploaded, category: .image, byteCount: bytes.count)
        vm.modelContext.insert(stored)
        try bytes.write(to: FileStore.url(for: stored), options: .atomic)
        vm.invalidateFileCache()
        return stored
    }
    private func urls(_ messages: [[String: Any]]) throws -> [String] {
        let user = try XCTUnwrap(messages.last { $0["role"] as? String == "user" })
        return (user["content"] as? [[String: Any]] ?? []).compactMap { ($0["image_url"] as? [String: Any])?["url"] as? String }
    }
    func testOnlyEditingIntentsIncludeGeneratedPreview() {
        for request in ["把你生成的海报logo换成我们的logo", "修改刚才生成的海报", "给刚才那张加一个人", "不用重新设计你生成的海报，请替换Logo", "Please replace the logo in the generated poster"] {
            XCTAssertTrue(GeneratedImagePlanningContext.shouldInclude(userText: request, hasAttachedImages: true), request)
        }
        XCTAssertTrue(GeneratedImagePlanningContext.shouldInclude(userText: "重新设计这张图", hasAttachedImages: false))
        for request in ["你生成的海报很好看", "解释一下logo的含义", "生成一张海报", "只改上传的图片，不使用生成图", "不要修改你生成的海报", "你生成的海报已经修改好了", "Don't edit the generated poster", "你刚才说会修改你生成的海报"] {
            XCTAssertFalse(GeneratedImagePlanningContext.shouldInclude(userText: request, hasAttachedImages: true), request)
        }
        XCTAssertFalse(GeneratedImagePlanningContext.shouldInclude(userText: "重新设计这张图", hasAttachedImages: true))
    }
    func testPreviewIsBoundedAndKeepsCanvasAspect() async throws {
        let raw = image(.blue, size: CGSize(width: 2000, height: 1400))
        let prepared = await GeneratedImagePlanningContext.dataURL(from: raw)
        let result = try XCTUnwrap(prepared)
        let data = try XCTUnwrap(Data(base64Encoded: String(result.dropFirst("data:image/jpeg;base64,".count))))
        let size = try XCTUnwrap(ImageGeometry.pixelSize(of: data))
        XCTAssertLessThanOrEqual(max(size.width, size.height), 1024)
        XCTAssertLessThanOrEqual(data.count, 350_000)
        XCTAssertEqual(Double(size.width) / Double(size.height), 10.0 / 7, accuracy: 0.01)
    }
    func testPreviewUsesExifOrientation() async throws {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(image(.red, size: CGSize(width: 1600, height: 1200)) as CFData, nil))
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cg, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let prepared = await GeneratedImagePlanningContext.dataURL(from: bytes as Data)
        let result = try XCTUnwrap(prepared)
        let data = try XCTUnwrap(Data(base64Encoded: String(result.dropFirst("data:image/jpeg;base64,".count))))
        let size = try XCTUnwrap(ImageGeometry.pixelSize(of: data))
        XCTAssertGreaterThan(size.height, size.width)
        XCTAssertEqual(Double(size.width) / Double(size.height), 0.75, accuracy: 0.01)
    }
    func testUnreadableInputAndCancelledWorkDoNotProducePreview() async {
        let invalid = await GeneratedImagePlanningContext.dataURL(from: Data("not an image".utf8))
        XCTAssertNil(invalid)
        let bytes = image(.blue)
        let task = Task { await GeneratedImagePlanningContext.dataURL(from: bytes) }
        task.cancel()
        let cancelled = await task.value
        XCTAssertNil(cancelled)
    }
    func testTransparentArtworkHasReadableWhitePreviewBacking() async throws {
        let prepared = await GeneratedImagePlanningContext.dataURL(from: image(.clear))
        let url = try XCTUnwrap(prepared)
        let data = try XCTUnwrap(Data(base64Encoded: String(url.dropFirst("data:image/jpeg;base64,".count))))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        XCTAssertTrue(pixel.prefix(3).allSatisfy { $0 > 240 })
    }
    func testAppendPreservesUploadedIndicesAndDoesNotDuplicatePreview() throws {
        let input: [[String: Any]] = [["role": "assistant", "content": "[已展示生成图]"], ["role": "user", "content": [
            ["type": "text", "text": "换Logo"], ["type": "image_url", "image_url": ["url": "upload-1"]],
            ["type": "image_url", "image_url": ["url": "upload-2"]]]]]
        let preview = "data:image/jpeg;base64,generated"
        let result = GeneratedImagePlanningContext.appending(preview, to: input)
        XCTAssertEqual(try urls(result), [preview, "upload-1", "upload-2"])
        XCTAssertEqual(try urls(GeneratedImagePlanningContext.appending(preview, to: result)), [preview, "upload-1", "upload-2"])
        let content = result.last?["content"] as? [[String: Any]] ?? []
        XCTAssertTrue(content.contains { ($0["text"] as? String ?? "").contains("不计入source_index") })
    }
    func testSixUploadsAreNeverDroppedForPreview() throws {
        let parts: [[String: Any]] = (0..<6).map { ["type": "image_url", "image_url": ["url": "upload-\($0)"]] }
        let messages: [[String: Any]] = [["role": "user", "content": parts]]
        XCTAssertFalse(GeneratedImagePlanningContext.canAppend(to: messages))
        XCTAssertEqual(try urls(GeneratedImagePlanningContext.appending("data:image/jpeg;base64,generated", to: messages)).count, 6)
    }
    func testActualContextCarriesOnlyLatestGeneratedAndNoUnrelatedCarriedUpload() async throws {
        let (vm, conv) = try model()
        let file = try attachment(image(.green), vm: vm)
        defer { try? FileManager.default.removeItem(at: FileStore.url(for: file)) }
        let old = add("user", "之前上传", at: 0, to: conv, vm: vm); old.attachmentIds = file.id.uuidString
        _ = add("assistant", "", at: 1, data: image(.red), to: conv, vm: vm)
        _ = add("assistant", "", at: 2, data: image(.blue), to: conv, vm: vm)
        _ = add("user", "修改你生成的海报", at: 3, to: conv, vm: vm)
        try vm.modelContext.save()
        let messages = await vm.buildAPIMessages(conv: conv)
        let actual = try urls(messages)
        XCTAssertEqual(actual.count, 1, "不能把旧上传图一起带进本轮生成图编辑")
        let prepared = await GeneratedImagePlanningContext.dataURL(from: image(.blue))
        let expected = try XCTUnwrap(prepared)
        XCTAssertEqual(actual.first, expected)
        XCTAssertEqual(messages.filter { $0["role"] as? String == "assistant" }.count, 2)
    }
    func testActualContextContainsGeneratedBaseAndCurrentLogoWithoutReordering() async throws {
        let (vm, conv) = try model()
        _ = add("assistant", "", at: 0, data: image(.blue), to: conv, vm: vm)
        let file = try attachment(image(.green), vm: vm)
        defer { try? FileManager.default.removeItem(at: FileStore.url(for: file)) }
        let user = add("user", "把你生成的海报logo换成我们的logo", at: 1, to: conv, vm: vm)
        user.attachmentIds = file.id.uuidString; try vm.modelContext.save()
        let messages = await vm.buildAPIMessages(conv: conv)
        let actual = try urls(messages)
        XCTAssertEqual(actual.count, 2)
        let preview = await GeneratedImagePlanningContext.dataURL(from: image(.blue))
        let uploaded = await ChatViewModel.imageDataURL(for: file)
        XCTAssertEqual(actual.first, preview)
        XCTAssertEqual(actual.last, uploaded)
    }
    func testOrdinaryChatAndForeignConversationDoNotCarryGeneratedPreview() async throws {
        let (vm, conv) = try model()
        _ = add("assistant", "", at: 0, data: image(.red), to: conv, vm: vm)
        let user = add("user", "你生成的海报很好看", at: 1, to: conv, vm: vm)
        try vm.modelContext.save()
        let ordinary = await vm.buildAPIMessages(conv: conv)
        XCTAssertTrue(try urls(ordinary).isEmpty)
        user.text = "修改你生成的海报"; conv.ownerKey = "another-owner"
        let messages = await vm.buildAPIMessages(conv: conv)
        XCTAssertTrue(messages.isEmpty)
    }
    func testMissingPreviewIsExplicitAndNeverReplacedWithAnotherImage() async throws {
        let (vm, conv) = try model()
        _ = add("assistant", "", at: 0, data: Data("invalid image".utf8), to: conv, vm: vm)
        _ = add("user", "修改你生成的海报", at: 1, to: conv, vm: vm)
        try vm.modelContext.save()
        let messages = await vm.buildAPIMessages(conv: conv)
        XCTAssertTrue(try urls(messages).isEmpty)
        let parts = messages.last?["content"] as? [[String: Any]] ?? []
        XCTAssertTrue(parts.contains { ($0["text"] as? String ?? "").contains("生成图预览未读取") })
    }
    func testCurrentUploadedPhotoEditDoesNotSendOldGeneratedPreview() async throws {
        let (vm, conv) = try model()
        _ = add("assistant", "", at: 0, data: image(.blue), to: conv, vm: vm)
        let file = try attachment(image(.red), vm: vm)
        defer { try? FileManager.default.removeItem(at: FileStore.url(for: file)) }
        let user = add("user", "重新设计这张海报", at: 1, to: conv, vm: vm)
        user.attachmentIds = file.id.uuidString; try vm.modelContext.save()
        let messages = await vm.buildAPIMessages(conv: conv)
        let uploaded = await ChatViewModel.imageDataURL(for: file)
        XCTAssertEqual(try urls(messages), [try XCTUnwrap(uploaded)])
    }
    func testDeletedConversationDoesNotProduceAnyContext() async throws {
        let (vm, conv) = try model()
        _ = add("assistant", "", at: 0, data: image(.blue), to: conv, vm: vm)
        _ = add("user", "修改你生成的海报", at: 1, to: conv, vm: vm)
        vm.modelContext.delete(conv); try vm.modelContext.save()
        let messages = await vm.buildAPIMessages(conv: conv)
        XCTAssertTrue(messages.isEmpty)
    }
    func testExportPreparedPlanningContractForControlledProbe() async throws {
        let size = CGSize(width: 1000, height: 1400), format = UIGraphicsImageRendererFormat(); format.scale = 1
        let poster = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            UIColor.blue.setFill(); context.fill(CGRect(x: 80, y: 80, width: 180, height: 120))
            ("LOGO" as NSString).draw(at: CGPoint(x: 96, y: 118), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 34), .foregroundColor: UIColor.white])
            ("DEMO POSTER" as NSString).draw(at: CGPoint(x: 80, y: 380), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 60), .foregroundColor: UIColor.black])
        }.pngData()!
        let prepared = await GeneratedImagePlanningContext.dataURL(from: poster)
        let preview = try XCTUnwrap(prepared)
        let asset = image(.green, size: CGSize(width: 180, height: 90))
        let messages = GeneratedImagePlanningContext.appending(preview, to: [["role": "user", "content": [
            ["type": "text", "text": "把你生成的海报左上角旧Logo换成我上传的原素材，其他内容不变。请直接调用工具。"],
            ["type": "image_url", "image_url": ["url": "data:image/png;base64," + asset.base64EncodedString()]]]]])
        let fixture: [String: Any] = ["instructions": ImageDesignGuidance.instructions(for: "替换Logo"), "messages": messages,
            "tools": [["type": "function", "function": ToolManifest.imageEditFunction]], "expectedRegion": ["x": 0.08, "y": 80.0 / 1400, "width": 0.18, "height": 120.0 / 1400]]
        let bytes = try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys])
        let attachment = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.json")
        attachment.name = "generated-preview-contract"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
