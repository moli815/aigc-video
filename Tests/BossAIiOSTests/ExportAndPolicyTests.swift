import XCTest
import UIKit
import SwiftData
@testable import BossAI

// ============================================================================
// 10-23 C 阶段回归：导出嵌图 + 表达策略唯一来源。
// 历史问题：
//   1) 导出聊天记录时 AI 图/上传图只写"[此消息包含图片]"占位，Word/PDF 里图片全丢；
//   2) system prompt 同时注入 ReplyStyle 与 AnswerStyle，两者都能规定长短，冲突时模型只能猜。
// 本文件锁定这两条契约。
// ============================================================================

final class ExportAndPolicyTests: XCTestCase {

    private func samplePNG() throws -> Data {
        let size = CGSize(width: 120, height: 80)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        return try XCTUnwrap(image.pngData())
    }

    // MARK: - 导出嵌图

    func testDocxEmbedsImageInsteadOfPlaceholder() throws {
        let png = try samplePNG()
        let markdown = "第一段文字\n\n\(DocumentBuilder.imageMarker(0))\n\n第二段文字"
        let images = [ExportImage(data: png, caption: "附图 1 · 测试")]

        let withImage = DocumentBuilder.docx(title: "测试", markdown: markdown, images: images)
        let withoutImage = DocumentBuilder.docx(title: "测试", markdown: markdown, images: [])

        XCTAssertNotNil(withImage.range(of: Data("word/media/image0.png".utf8)),
                        "docx 包内必须包含 word/media/image0.png（此前只写占位文字）")
        XCTAssertGreaterThan(withImage.count, withoutImage.count, "嵌图后的 docx 应比纯文本更大")
    }

    func testPdfWithImageIsLargerThanTextOnly() throws {
        let png = try samplePNG()
        let markdown = "第一段文字\n\n\(DocumentBuilder.imageMarker(0))"
        let images = [ExportImage(data: png, caption: "附图 1 · 测试")]
        let withImage = try DocumentBuilder.pdf(title: "测试", markdown: markdown, images: images)
        let withoutImage = try DocumentBuilder.pdf(title: "测试", markdown: markdown, images: [])
        XCTAssertGreaterThan(withImage.count, withoutImage.count, "PDF 附图页应带来额外字节")
    }

    /// PPT：每张图生成一页「附图」，包里必须有 media 条目（此前完全降级为文字）。
    func testPptxEmbedsImageSlide() throws {
        let png = try samplePNG()
        let images = [ExportImage(data: png, caption: "现场照片 · 测试")]
        let withImage = DocumentBuilder.pptx(title: "测试", markdown: "第一页要点\n\n第二页要点", images: images)
        let withoutImage = DocumentBuilder.pptx(title: "测试", markdown: "第一页要点\n\n第二页要点", images: [])
        XCTAssertNotNil(withImage.range(of: Data("ppt/media/img1.png".utf8)),
                        "PPT 包内必须包含 ppt/media/img1.png")
        XCTAssertGreaterThan(withImage.count, withoutImage.count)
    }

    /// Excel：图片进独立「附图」工作表，主表保持纯文本。
    func testXlsxEmbedsImageSheet() throws {
        let png = try samplePNG()
        let images = [ExportImage(data: png, caption: "现场照片 · 测试")]
        let withImage = DocumentBuilder.xlsx(title: "测试", markdown: "| 项目 | 值 |\n| --- | --- |\n| A | 1 |", images: images)
        XCTAssertNotNil(withImage.range(of: Data("xl/worksheets/sheet2.xml".utf8)),
                        "缺少附图工作表")
        XCTAssertNotNil(withImage.range(of: Data("xl/drawings/drawing1.xml".utf8)),
                        "缺少图片锚点定义")
        XCTAssertNotNil(withImage.range(of: Data("xl/media/img1.png".utf8)),
                        "缺少图片二进制")
    }

    func testPptAndExcelDegradeToReferenceNote() {
        let markdown = "正文\n\n\(DocumentBuilder.imageMarker(0))"
        let images = [ExportImage(data: Data([0x89, 0x50, 0x4E, 0x47]), caption: "附图 1")]
        let replaced = DocumentBuilder.replacingImageMarkers(markdown, images: images)
        XCTAssertFalse(replaced.contains("[[IMG:"), "不能把占位标记原样写进 PPT/Excel")
        XCTAssertTrue(replaced.contains("见附图 1"))
    }

    // MARK: - 表达策略

    func testResponsePolicySeparatesToneAndDetail() {
        let prompt = ResponsePolicy.prompt(reply: .friendly, answer: .detailed)
        XCTAssertTrue(prompt.contains("【表达策略·语气】"))
        XCTAssertTrue(prompt.contains("【表达策略·详略】"))
        XCTAssertTrue(prompt.contains("以【表达策略·详略】为准"), "必须写明冲突仲裁规则")
        // 语气块不应再规定长度
        XCTAssertFalse(prompt.contains("极度简洁"))
        XCTAssertFalse(prompt.contains("宁可多不要缺"))
    }

    func testAutoReplyStyleOmitsToneBlock() {
        let prompt = ResponsePolicy.prompt(reply: .auto, answer: .concise)
        XCTAssertFalse(prompt.contains("【表达策略·语气】"), "auto 不应注入语气约束")
        XCTAssertTrue(prompt.contains("【表达策略·详略】"))
    }

    /// 详略偏好需要跨会话持久化：否则用户每次新会话都被重置成"简答"。
    @MainActor
    func testAnswerStylePersists() throws {
        let key = ChatViewModel.answerStyleKey
        let previous = UserDefaults.standard.string(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)

        let container = try ModelContainerFactory.inMemory()
        let vm = ChatViewModel(conversation: nil, expert: ExpertCatalog.find("general"),
                               modelContext: ModelContext(container), chatKey: { nil }, imageKey: { nil })
        vm.setAnswerStyle(.detailed)
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), AnswerStyle.detailed.rawValue)

        let vm2 = ChatViewModel(conversation: nil, expert: ExpertCatalog.find("general"),
                                modelContext: ModelContext(container), chatKey: { nil }, imageKey: { nil })
        XCTAssertEqual(vm2.answerStyle, .detailed, "新会话应沿用已保存的详略偏好")
    }
}

/// 测试用内存容器（避免各测试文件重复写 ModelConfiguration）。
private enum ModelContainerFactory {
    static func inMemory() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: Conversation.self, Message.self, StoredFile.self, MemoryItem.self,
                                  configurations: config)
    }
}
