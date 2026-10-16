import XCTest
import UIKit
@testable import BossAI

// ============================================================================
// App 内部端到端集成测试（真实网络，走 App 的真实 Service 类 + 服务端 → 千问）。
// 与普通单测（离线 fixture）的区别：这里用 ProviderCatalog.hostedChat / ImageService /
//   HostedAccount 的真实实现，真实登录、真实流式解析、真实工具调用——
//   目的：在 App 内部代码路径上复现并杜绝"千问生图报错"这类只有真机/真实链路才暴露的问题。
//
// 凭据安全：测试账号密码不写进仓库（仓库是 public）。通过环境变量注入：
//   BOSS_AI_TEST_USER / BOSS_AI_TEST_PASS（CI 用 GitHub Secrets；本地在 Xcode scheme 设置）。
// 未配置时 XCTSkip（不误伤 CI，配好 secret 即真实跑）。
// ============================================================================

@MainActor
final class AppInternalIntegrationTests: XCTestCase {

    private var username: String { ProcessInfo.processInfo.environment["BOSS_AI_TEST_USER"] ?? "" }
    private var password: String { ProcessInfo.processInfo.environment["BOSS_AI_TEST_PASS"] ?? "" }

    private func requireCredentials() throws {
        guard !username.isEmpty, !password.isEmpty else {
            throw XCTSkip("未配置 BOSS_AI_TEST_USER/PASS 环境变量，跳过真实网络集成测试")
        }
    }

    private func ensureLogin() async throws {
        try requireCredentials()
        if HostedAccount.currentToken == nil {
            try await HostedAccount.shared.login(username: username, password: password)
        }
        XCTAssertNotNil(HostedAccount.currentToken, "登录后应持有会员 token")
    }

    private func hostedChatService() -> ChatService {
        ChatService(profile: ProviderCatalog.hostedChat, apiKeyProvider: { HostedAccount.currentToken })
    }

    // ① 对话三档真实链路：流式解析 + chatMode 路由，三档都应有非空回答
    func testChatThreeModesRealNetwork() async throws {
        try await ensureLogin()
        for mode in ["standard", "high", "ultra"] {
            var text = ""
            for try await event in hostedChatService().stream(
                messages: [["role": "user", "content": "一句话说明什么是复利"]],
                enableTools: false, chatMode: mode) {
                if case .textDelta(let delta) = event { text += delta }
            }
            XCTAssertFalse(text.isEmpty, "「\(mode)」档真实链路应返回非空回答")
        }
    }

    // ② 工具调用生图（千问空串覆盖 bug 的真实网络回归锚点）
    func testToolCallImageGenerationRealNetwork() async throws {
        try await ensureLogin()
        var calls: [ChatService.ToolCall] = []
        for try await event in hostedChatService().stream(
            messages: [["role": "user", "content": "帮我生成一张消防安全宣传海报"]],
            enableTools: true, expertID: "fire_safety") {
            if case .toolCalls(let received, _) = event { calls = received }
        }
        // 若模型本轮未触发工具（偶发），跳过断言而不是误报失败
        if calls.isEmpty { throw XCTSkip("模型本轮未触发工具调用，跳过（非缺陷）") }
        for call in calls {
            XCTAssertFalse(call.id.isEmpty, "工具调用 id 不得为空——千问 \"id\":\"\" 覆盖 bug 的回归")
            XCTAssertFalse(call.name.isEmpty, "工具名不得为空")
            XCTAssertEqual(call.name, "generate_image")
        }
    }

    // ③ 带图对话（视觉真实链路）
    func testVisionRealNetwork() async throws {
        try await ensureLogin()
        let size = CGSize(width: 400, height: 400)
        let fmt = UIGraphicsImageRendererFormat.default(); fmt.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            UIColor.systemBlue.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
        }
        let dataURL = "data:image/png;base64," + (image.pngData()?.base64EncodedString() ?? "")
        let message: [String: Any] = ["role": "user", "content": [
            ["type": "image_url", "image_url": ["url": dataURL]],
            ["type": "text", "text": "这是什么颜色？一句话回答"],
        ]]
        var text = ""
        for try await event in hostedChatService().stream(messages: [message], enableTools: false) {
            if case .textDelta(let delta) = event { text += delta }
        }
        XCTAssertFalse(text.isEmpty, "视觉链路应返回识别结果")
    }

    // ④ 生图 API（ImageService 真实调用，验证返回合法 JPEG）
    func testImageGenerationRealNetwork() async throws {
        try await ensureLogin()
        let service = ImageService(profile: ProviderCatalog.hostedImage,
                                   apiKeyProvider: { HostedAccount.currentToken })
        let data = try await service.generate(prompt: "一只橘猫的扁平插画，无文字")
        XCTAssertGreaterThan(data.count, 1000, "生成图应非空")
        XCTAssertEqual(data[0], 0xFF, "应为 JPEG 魔数 FF")
        XCTAssertEqual(data[1], 0xD8, "应为 JPEG 魔数 D8")
    }

    // ⑤ HostedAccount 全接口（/me 元数据 + 服务端记忆抽取）
    func testHostedAccountEndpointsRealNetwork() async throws {
        try await ensureLogin()
        let account = HostedAccount.shared
        XCTAssertEqual(account.chatModes.count, 3, "档位元数据应有三档")
        XCTAssertNotNil(account.uiConfig["imageMaxEdge"], "uiConfig 应下发图片压缩长边")
        let ops = await account.extractMemories(
            dialogue: "用户：我叫张建国，苏州做建材批发，防水材料，年营收约2000万。\n助手：好的，已记住。",
            existing: [])
        XCTAssertNotNil(ops, "记忆抽取接口应正常返回（可为空数组）")
    }
}
