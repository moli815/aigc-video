import XCTest
import SwiftData
import UIKit
@testable import BossAI

// ============================================================================
// 10-23 海报/名片"先识别再做新图"回归测试。
// 历史缺陷：用户先上传图片并识别，再发文字"根据这张图做一张新海报"时，
//   1) buildAPIMessages 只把历史图片转成占位文本，本轮不传输图片本体；
//   2) attachedImageData 只查最后一条 user 消息，当前是文字时返回 nil；
//   3) 首 token 无超时保护，偶发长时间停在"正在分析任务…"。
// 本文件锁定上述修复。
// ============================================================================

final class PosterContextRegressionTests: XCTestCase {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: Conversation.self, Message.self, StoredFile.self, MemoryItem.self, configurations: config)
    }

    private func makeImageFile(in context: ModelContext, name: String = "poster.jpg") throws -> StoredFile {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100))
        let image = renderer.image { ctx in UIColor.red.setFill(); ctx.fill(CGRect(origin: .zero, size: CGSize(width: 100, height: 100))) }
        guard let data = image.jpegData(compressionQuality: 0.8) else { throw XCTSkip("无法生成测试图片") }
        let file = StoredFile(name: name, ext: "jpg", byteCount: data.count, kind: .imported)
        file.mimeType = "image/jpeg"
        context.insert(file)
        try context.save()
        // 写磁盘让 FileStore.url(for:) 可读
        let url = FileStore.url(for: file)
        try data.write(to: url, options: .atomic)
        return file
    }

    /// 纯文本后续请求涉及生图关键词时，最近的用户上传图片应作为 image_url 出现在请求消息里。
    @MainActor
    func testTextOnlyPosterRequestCarriesRecentUserImage() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StreamFixtureProtocol.self]
        let chat = ChatService(profile: ChatProfile(id: "fixture", displayName: "Fixture",
                                                    baseURL: "https://fixture.invalid/v1", model: "fixture",
                                                    memoryModel: "fixture", searchStyle: .none),
                               apiKeyProvider: { "fixture" },
                               session: URLSession(configuration: config))
        let vm = ChatViewModel(conversation: nil, expert: ExpertCatalog.find("general"), modelContext: context,
                               chatKey: { "fixture" }, imageKey: { nil }, chatService: chat)

        let _ = try vm.ensureConversation()

        // 第一轮：用户上传图片并请求识别；用快速空回复结束流式，避免真实网络等待。
        StreamFixtureProtocol.payload = Data(Self.quickStop.utf8)
        let imageFile = try makeImageFile(in: context)
        vm.pendingAttachments = [imageFile]
        vm.inputText = "识别一下这张图"
        vm.send()
        for _ in 0..<100 { if !vm.isStreaming { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(vm.isStreaming)

        // 第二轮：纯文本请求基于图片做新海报
        StreamFixtureProtocol.payload = Data(Self.quickStop.utf8)
        vm.inputText = "根据这张图的内容帮我做一张新海报"
        vm.send()
        for _ in 0..<100 { if !vm.isStreaming { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(vm.isStreaming)

        // 验证：构造出的 apiMessages 里最后一条 user 消息包含 image_url
        let messages = await vm.lastBuiltAPIMessagesForTests()
        guard let lastUser = messages.last(where: { ($0["role"] as? String) == "user" }),
              let content = lastUser["content"] as? [[String: Any]] else {
            XCTFail("最后一条用户消息不是多模态 content")
            return
        }
        let hasImage = content.contains { part in
            (part["type"] as? String) == "image_url" &&
            ((part["image_url"] as? [String: Any])?["url"] as? String)?.hasPrefix("data:image/") == true
        }
        XCTAssertTrue(hasImage, "基于图片做新海报时，请求里必须携带最近的用户图片")
    }

    private static let quickStop = #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

data: [DONE]

"#

    /// attachedImageData 应回查到最近有图片附件的用户消息，而不是只看最后一条。
    @MainActor
    func testAttachedImageDataSearchesRecentUserMessages() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let vm = ChatViewModel(conversation: nil, expert: ExpertCatalog.find("general"), modelContext: context,
                               chatKey: { "fixture" }, imageKey: { nil })
        let conv = try vm.ensureConversation()

        // 插入一条带图的用户消息
        let imageFile = try makeImageFile(in: context, name: "logo.png")
        let userWithImage = Message(role: "user", text: "识别一下")
        userWithImage.attachmentIds = imageFile.id.uuidString
        userWithImage.conversation = conv
        userWithImage.conversationID = conv.id
        context.insert(userWithImage)

        // 再插入一条纯文本用户消息
        let textOnly = Message(role: "user", text: "根据这个 logo 做海报")
        textOnly.conversation = conv
        textOnly.conversationID = conv.id
        context.insert(textOnly)
        try context.save()

        XCTAssertNotNil(vm.attachedImageData(in: conv), "当前消息是文字时，仍应回查找到图片附件")
    }

    /// 首 token 超时保护：服务端长时间不返回时，应在配置的超时时间内结束并给出错误。
    @MainActor
    func testFirstTokenTimeoutFires() async throws {
        // 配置 hosted profile，把首 token 超时压到 1 秒，便于测试。
        let infoKey = "bossai.hosted_profile_v1"
        let previous = UserDefaults.standard.dictionary(forKey: infoKey)
        UserDefaults.standard.set(["chatFirstTokenTimeout": 1], forKey: infoKey)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: infoKey) }
            else { UserDefaults.standard.removeObject(forKey: infoKey) }
        }

        let container = try makeContainer()
        let context = ModelContext(container)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HangingStreamProtocol.self]
        let chat = ChatService(profile: ChatProfile(id: "fixture", displayName: "Fixture",
                                                    baseURL: "https://fixture-hang.invalid/v1", model: "fixture",
                                                    memoryModel: "fixture", searchStyle: .none),
                               apiKeyProvider: { "fixture" },
                               session: URLSession(configuration: config))
        let vm = ChatViewModel(conversation: nil, expert: ExpertCatalog.find("general"), modelContext: context,
                               chatKey: { "fixture" }, imageKey: { nil }, chatService: chat)

        let _ = try vm.ensureConversation()
        vm.inputText = "根据这张图帮我做一张新海报"
        vm.send()

        // 等待超时触发（1 秒超时 + 最多 2 秒缓冲）
        for _ in 0..<300 {
            if !vm.isStreaming { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertFalse(vm.isStreaming, "首 token 超时后必须结束流式")
        XCTAssertNotNil(vm.errorMessage, "首 token 超时后必须设置错误文案")
        XCTAssertTrue(vm.errorMessage?.contains("超时") == true, "错误文案应提示超时")
        XCTAssertNotNil(vm.failedUserMessageID, "首 token 超时后应允许重试")
    }
}

// MARK: - 测试专用入口

extension ChatViewModel {
    /// 测试钩子：返回最近一次 buildAPIMessages 产出的消息数组。
    /// 注意：仅在测试中使用；真实运行时不保留此快照。
    func lastBuiltAPIMessagesForTests() async -> [[String: Any]] {
        // 通过构造一个测试会话并调用 buildAPIMessages 来取结果。
        guard let conv = conversation else { return [] }
        return await buildAPIMessages(conv: conv)
    }
}

// MARK: - 流式协议桩

/// 正常 SSE：按字节逐一下发，模拟真实流式行为。
private final class StreamFixtureProtocol: URLProtocol {
    static var payload = Data()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for byte in Self.payload { client?.urlProtocol(self, didLoad: Data([byte])) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// 挂起协议：只返回响应头，永远不下发数据/不结束，用于首 token 超时测试。
private final class HangingStreamProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture-hang.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // 永远不叫 urlProtocolDidFinishLoading，让流挂起直到超时取消
    }
    override func stopLoading() {}
}
