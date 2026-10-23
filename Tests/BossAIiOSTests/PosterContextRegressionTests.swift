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

    override func tearDown() {
        StreamFixtureProtocol.payload = Data()
        super.tearDown()
    }

    // MARK: - 测试夹具

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: Conversation.self, Message.self, StoredFile.self, MemoryItem.self,
                                  configurations: config)
    }

    /// 造一张真实落盘的图片文件（100x100 纯红 JPEG）。
    /// 必须真正写盘：buildAPIMessages 走 imageDataURL(for:) 会从沙盒读字节。
    @MainActor
    private func makeImageFile(in context: ModelContext, name: String = "poster.jpg") throws -> StoredFile {
        FileStore.prepare()
        let size = CGSize(width: 100, height: 100)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        guard let data = image.jpegData(compressionQuality: 0.8) else {
            throw XCTSkip("当前环境无法生成测试图片")
        }
        let ext = (name as NSString).pathExtension.lowercased()
        let storedName = "\(UUID().uuidString).\(ext.isEmpty ? "jpg" : ext)"
        let file = StoredFile(name: name,
                              ext: ext.isEmpty ? "jpg" : ext,
                              storedName: storedName,
                              kind: .uploaded,
                              category: .image,
                              byteCount: data.count)
        context.insert(file)
        try context.save()
        try data.write(to: FileStore.url(for: file), options: .atomic)
        return file
    }

    private func makeChatService(host: String, protocolClass: AnyClass) -> ChatService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [protocolClass]
        return ChatService(profile: ChatProfile(id: "fixture",
                                               displayName: "Fixture",
                                               baseURL: "https://\(host)/v1",
                                               model: "fixture",
                                               memoryModel: "fixture",
                                               searchStyle: .none),
                           apiKeyProvider: { "fixture" },
                           session: URLSession(configuration: config))
    }

    /// 等待流式结束：轮询 isStreaming，最多 maxRounds × 10ms。
    @MainActor
    private func waitStreamingFinished(_ vm: ChatViewModel, maxRounds: Int = 200) async {
        for _ in 0..<maxRounds {
            if !vm.isStreaming { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - 用例

    /// 纯文本后续请求涉及生图关键词时，最近的用户上传图片应作为 image_url 出现在请求消息里。
    @MainActor
    func testTextOnlyPosterRequestCarriesRecentUserImage() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let chat = makeChatService(host: "fixture.invalid", protocolClass: StreamFixtureProtocol.self)
        let vm = ChatViewModel(conversation: nil,
                               expert: ExpertCatalog.find("general"),
                               modelContext: context,
                               chatKey: { "fixture" },
                               imageKey: { nil },
                               chatService: chat)

        let conv = try vm.ensureConversation()

        // 第一轮：上传图片并请求识别，用极简 SSE 立即结束，避免真实网络等待。
        StreamFixtureProtocol.payload = Data(Self.quickStop.utf8)
        let imageFile = try makeImageFile(in: context)
        vm.pendingAttachments = [imageFile]
        vm.inputText = "识别一下这张图"
        vm.send()
        await waitStreamingFinished(vm)
        XCTAssertFalse(vm.isStreaming, "第一轮流式应正常结束")

        // 第二轮：纯文本，要求基于刚才的图做新海报。
        StreamFixtureProtocol.payload = Data(Self.quickStop.utf8)
        vm.inputText = "根据这张图的内容帮我做一张新海报"
        vm.send()
        await waitStreamingFinished(vm)
        XCTAssertFalse(vm.isStreaming, "第二轮流式应正常结束")

        // 验证：本轮最后一条 user 消息必须携带 image_url。
        let messages = await vm.buildAPIMessages(conv: conv)
        guard let lastUser = messages.last(where: { ($0["role"] as? String) == "user" }) else {
            XCTFail("请求里没有 user 消息")
            return
        }
        guard let parts = lastUser["content"] as? [[String: Any]] else {
            XCTFail("纯文本生图请求应升级为多模态 content，实际为：\(lastUser["content"] ?? "nil")")
            return
        }
        let hasImage = parts.contains { part in
            guard (part["type"] as? String) == "image_url",
                  let imageURL = (part["image_url"] as? [String: Any])?["url"] as? String else { return false }
            return imageURL.hasPrefix("data:image/")
        }
        XCTAssertTrue(hasImage, "基于图片做新海报时，请求里必须携带最近的用户图片")
    }

    /// attachedImageData 应回查到最近有图片附件的用户消息，而不是只看最后一条。
    @MainActor
    func testAttachedImageDataSearchesRecentUserMessages() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let vm = ChatViewModel(conversation: nil,
                               expert: ExpertCatalog.find("general"),
                               modelContext: context,
                               chatKey: { "fixture" },
                               imageKey: { nil })
        let conv = try vm.ensureConversation()

        let imageFile = try makeImageFile(in: context, name: "logo.jpg")
        let userWithImage = Message(role: "user", text: "识别一下这个 logo")
        userWithImage.attachmentIds = imageFile.id.uuidString
        userWithImage.conversation = conv
        userWithImage.conversationID = conv.id
        context.insert(userWithImage)

        let textOnly = Message(role: "user", text: "根据这个 logo 做一张海报")
        textOnly.conversation = conv
        textOnly.conversationID = conv.id
        context.insert(textOnly)
        try context.save()

        XCTAssertNotNil(vm.attachedImageData(in: conv),
                        "当前消息是文字时，仍应回查找到前一条消息的图片附件")
    }

    /// 首 token 超时保护：服务端长时间不返回时，应在注入的超时时间内结束并给出错误。
    @MainActor
    func testFirstTokenTimeoutFires() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let chat = makeChatService(host: "fixture-hang.invalid", protocolClass: HangingStreamProtocol.self)
        let vm = ChatViewModel(conversation: nil,
                               expert: ExpertCatalog.find("general"),
                               modelContext: context,
                               chatKey: { "fixture" },
                               imageKey: { nil },
                               chatService: chat)
        // 关键：把超时压到 1 秒，避免单测等待线上默认的 45 秒。
        vm.firstTokenTimeoutOverride = 1

        let _ = try vm.ensureConversation()
        vm.inputText = "根据这张图帮我做一张新海报"
        vm.send()

        // 1 秒超时 + 最多 3 秒缓冲
        await waitStreamingFinished(vm, maxRounds: 300)

        XCTAssertFalse(vm.isStreaming, "首 token 超时后必须结束流式")
        XCTAssertNotNil(vm.errorMessage, "首 token 超时后必须设置错误文案")
        XCTAssertTrue(vm.errorMessage?.contains("超时") == true,
                      "错误文案应提示超时，实际：\(vm.errorMessage ?? "nil")")
        XCTAssertNotNil(vm.failedUserMessageID, "首 token 超时后应允许重试")
    }

    // MARK: - SSE 桩数据

    /// 一条立即结束的 SSE：先给 stop，再给 [DONE]。
    /// 用普通字符串 + 转义换行，避免 Swift 单行 raw string 不能跨行的坑（上一版即栽在这里）。
    private static let quickStop = "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
}

// MARK: - 流式协议桩

/// 正常 SSE：一次性下发全部字节后结束。
private final class StreamFixtureProtocol: URLProtocol {
    nonisolated(unsafe) static var payload = Data()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "fixture.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "text/event-stream"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !Self.payload.isEmpty {
            client?.urlProtocol(self, didLoad: Self.payload)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// 挂起协议：只回响应头，永不下发数据、永不结束，用于首 token 超时测试。
private final class HangingStreamProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "fixture-hang.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "text/event-stream"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // 故意不调用 urlProtocolDidFinishLoading，让流挂起直到超时取消。
    }

    override func stopLoading() {}
}
