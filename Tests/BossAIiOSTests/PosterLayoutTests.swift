import XCTest
import UIKit
@testable import BossAI

// ============================================================================
// PosterLayoutTests —— 名片/海报「程序排版」层的回归（2026-10-24 第二阶段）
//
// 这里锁的是**确定性规则**（换行估算、溢出判定、内容清洗），不测好不好看：
//   · 文字超长必须报 titleTooLong，而不是默默画到画布外；
//   · 要点超过 4 条必须报 tooManyBullets；
//   · 内容放不下必须报 textOverflow（宁可报错，也不悄悄缩字号）。
// ============================================================================

final class PosterLayoutTests: XCTestCase {

    func testSanitizeCollapsesAndTruncates() {
        XCTAssertEqual(PosterLayout.sanitized("  张三\n\n  总经理  ", max: 20), "张三 总经理")
        XCTAssertEqual(PosterLayout.sanitized(String(repeating: "字", count: 50), max: 10).count, 10)
    }

    func testEstimatedLinesNeverZeroForEmpty() {
        XCTAssertEqual(PosterLayout.estimatedLines("", fontSize: 20, maxWidth: 300), 0)
        XCTAssertEqual(PosterLayout.estimatedLines("短标题", fontSize: 20, maxWidth: 600), 1)
    }

    func testLongTitleFlagged() {
        let content = PosterContent(title: String(repeating: "很长的公司名称", count: 12),
                                    subtitle: "", bullets: [], footer: "")
        let issues = PosterLayout.checkLayout(content, canvas: CGSize(width: 1024, height: 1365))
        XCTAssertTrue(issues.contains(.titleTooLong), "超长标题必须被标记：\(issues)")
    }

    func testTooManyBulletsFlagged() {
        let content = PosterContent(title: "中防保全", subtitle: "智慧安防",
                                    bullets: ["消防维保", "安防工程", "监控安装", "门禁系统", "巡更系统"],
                                    footer: "电话 400-000-0000")
        let issues = PosterLayout.checkLayout(content, canvas: CGSize(width: 1024, height: 1365))
        XCTAssertTrue(issues.contains(.tooManyBullets))
    }

    func testNormalCardPasses() {
        let content = PosterContent(title: "中防保全 AI",
                                    subtitle: "智慧安防 · 消防维保",
                                    bullets: ["安防工程", "监控安装", "门禁系统"],
                                    footer: "400-000-0000 · 苏州")
        let issues = PosterLayout.checkLayout(content, canvas: CGSize(width: 1024, height: 1365))
        XCTAssertTrue(issues.isEmpty, "正常名片不该报问题：\(issues)")
    }

    func testZeroCanvasIsOverflow() {
        let content = PosterContent(title: "标题", subtitle: "", bullets: [], footer: "")
        XCTAssertEqual(PosterLayout.checkLayout(content, canvas: .zero), [.textOverflow])
    }

    func testRenderProducesImageWithSameSize() {
        let background = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 683)).image { ctx in
            UIColor(red: 0.1, green: 0.15, blue: 0.3, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 512, height: 683))
        }
        let content = PosterContent(title: "中防保全", subtitle: "智慧安防", bullets: ["安防工程"], footer: "400-000-0000")
        let output = PosterLayout.render(background: background, content: content)
        XCTAssertEqual(output.size.width, background.size.width, accuracy: 0.5)
        XCTAssertEqual(output.size.height, background.size.height, accuracy: 0.5)
    }

    func testContentFromArgsUsesStructuredFields() {
        let args: [String: Any] = ["structured": ["title": "中防保全", "subtitle": "智慧安防", "bullets": ["消防维保", "安防工程"]]]
        let content = PosterContent.from(args: args, prompt: "做一张名片")
        XCTAssertEqual(content?.title, "中防保全")
        XCTAssertEqual(content?.subtitle, "智慧安防")
        XCTAssertEqual(content?.bullets.count, 2)
    }

    func testContentFromPromptFallback() {
        let content = PosterContent.from(args: nil, prompt: "帮我做一张 AI 培训海报")
        XCTAssertNotNil(content)
        XCTAssertFalse(content!.title.contains("帮我"), "指令性前缀应被去掉")
        XCTAssertTrue(content!.title.contains("AI 培训海报"))
    }
}
