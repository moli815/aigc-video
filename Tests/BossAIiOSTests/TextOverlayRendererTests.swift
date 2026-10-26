import XCTest
@testable import BossAI

final class TextOverlayRendererTests: XCTestCase {
    func testStructuredTextKeepsSemanticRolesAndExactCopy() {
        let items = TextItem.parse([
            ["role": "title", "key": "company", "text": "中防保全"],
            ["role": "contact", "key": "phone", "text": "185-6866-4567"],
        ])

        XCTAssertEqual(items, [
            TextItem(role: .title, key: "company", text: "中防保全"),
            TextItem(role: .contact, key: "phone", text: "185-6866-4567"),
        ])
    }

    func testLegacyTextStringRemainsReadableAsBodyLines() {
        let items = TextItem.parse("第一行\n\n第二行")

        XCTAssertEqual(items.map(\.text), ["第一行", "第二行"])
        XCTAssertTrue(items.allSatisfy { $0.role == .body })
    }

    func testUnknownRoleFallsBackToBodyWithoutDroppingCopy() {
        let items = TextItem.parse([["role": "unknown", "text": "原文" ]])

        XCTAssertEqual(items, [TextItem(role: .body, key: "text-1", text: "原文")])
    }

    func testDefaultLayoutIsSingleColumn() {
        XCTAssertEqual(LayoutSpec.from(nil).columns.rawValue, 1)
    }

    func testSingleColumnOverflowChecksAllItemsTogether() {
        let items = (1...4).map { index in
            TextItem(role: .body, key: "line-\(index)", text: "第\(index)行")
        }
        let issues = TextOverlayRenderer.check(items: items,
                                               layout: LayoutSpec(),
                                               canvas: CanvasSpec(size: CGSize(width: 300, height: 120),
                                                                  expectedAspect: nil))

        XCTAssertTrue(issues.contains("文字超出画布"), "单栏要累计所有条目高度，不能分别检查后重叠绘制")
    }
}
