import XCTest
import UIKit
@testable import BossAI

// BusinessCardRendererTests —— 名片排版规则（纯函数可测部分）
// 只验证"放不下必须报错、六字段都在版面上"，不验证美观。
final class BusinessCardRendererTests: XCTestCase {

    private func card(name: String = "张三",
                      title: String = "总经理",
                      phone: String = "13800000000",
                      email: String = "zhangsan@example.com",
                      address: String = "苏州市工业园区星湖街 328 号",
                      company: String = "中防保全") -> BusinessCard {
        BusinessCard(name: name, title: title, phone: phone, email: email,
                     address: address, company: company, logo: nil)
    }

    func testNormalCardPasses() {
        let issues = BusinessCardRenderer.checkLayout(card: card(), canvas: CGSize(width: 1600, height: 1000))
        XCTAssertTrue(issues.isEmpty, "正常名片不该报问题：\(issues)")
    }

    func testEmptyNameRejected() {
        let issues = BusinessCardRenderer.checkLayout(card: card(name: ""), canvas: CGSize(width: 1600, height: 1000))
        XCTAssertTrue(issues.contains("姓名为空"))
        XCTAssertThrowsError(try BusinessCardRenderer.render(card: card(name: ""), on: base())) { err in
            XCTAssertEqual(err as? BusinessCardError, .emptyRequiredFields)
        }
    }

    func testOverlongAddressFlagged() {
        let long = String(repeating: "很长的地址", count: 40)
        let issues = BusinessCardRenderer.checkLayout(card: card(address: long), canvas: CGSize(width: 1600, height: 1000))
        XCTAssertTrue(issues.contains("地址"), "超长地址必须被拦下，而不是画出画布外")
    }

    func testOverlongEmailFlagged() {
        let long = String(repeating: "a", count: 90) + "@example.com"
        let issues = BusinessCardRenderer.checkLayout(card: card(email: long), canvas: CGSize(width: 1600, height: 1000))
        XCTAssertTrue(issues.contains("邮箱"))
    }

    func testRenderKeepsCanvasSize() throws {
        let out = try BusinessCardRenderer.render(card: card(), on: base())
        XCTAssertEqual(out.size.width, 1600, accuracy: 0.5)
        XCTAssertEqual(out.size.height, 1000, accuracy: 0.5)
    }

    func testLineEstimation() {
        XCTAssertEqual(BusinessCardRenderer.lines("", size: 18, maxWidth: 300), 0)
        XCTAssertEqual(BusinessCardRenderer.lines("短", size: 18, maxWidth: 300), 1)
    }

    private func base() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 1000)).image { ctx in
            UIColor(red: 0.1, green: 0.2, blue: 0.35, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1600, height: 1000))
        }
    }
}
