import XCTest
import UIKit
@testable import BossAI

/// 品牌素材落位的确定性规则（2026-10-28）
///
/// 事故：用户要求「在海报左上角加我们的 logo」，logo 被按模型估的框撑满、贴边，
/// 看上去像贴纸。根因是合成阶段把 box 当成了最终尺寸。
/// 这里锁住四条规则：品牌比例、栅格边距、比例锁定、安全区。
final class BrandPlacementPlannerTests: XCTestCase {
    private let canvas = CGSize(width: 1200, height: 1600)

    /// 1200×1600 画布，短边 1200 → 宽度 16% = 192、边距 5.5% = 66
    func testTopLeftBoxSnapsToBrandGrid() {
        let box = CGRect(x: 0.02, y: 0.02, width: 0.3, height: 0.2)
        let result = BrandPlacementPlanner.adjust(box: box, logoAspect: 2, canvas: canvas, hint: "在左上角加我们的logo")
        XCTAssertEqual(result.minX, 66, accuracy: 1, "左边距必须是短边的 5.5%")
        XCTAssertEqual(result.minY, 66, accuracy: 1, "上边距必须是短边的 5.5%")
        XCTAssertEqual(result.width, 192, accuracy: 1, "logo 宽度必须是短边的 16%")
        XCTAssertEqual(result.width / result.height, 2, accuracy: 0.01, "必须按真实宽高比缩放")
    }

    func testBottomRightBoxSnapsToMargins() {
        let box = CGRect(x: 0.7, y: 0.8, width: 0.2, height: 0.1)
        let result = BrandPlacementPlanner.adjust(box: box, logoAspect: 2, canvas: canvas, hint: "右下角放logo")
        XCTAssertEqual(result.maxX, canvas.width - 66, accuracy: 1)
        XCTAssertEqual(result.maxY, canvas.height - 66, accuracy: 1)
    }

    /// 关键回归：模型把框画得很小（0.06 宽度）时，不能因此得到一个米粒大的 logo
    func testTinyBoxStillProducesLegibleLogo() {
        let tiny = CGRect(x: 0.05, y: 0.05, width: 0.06, height: 0.04)
        let result = BrandPlacementPlanner.adjust(box: tiny, logoAspect: 1, canvas: canvas, hint: "加上logo")
        XCTAssertEqual(result.width, 192, accuracy: 1, "尺寸由品牌比例决定，与模型估的框大小无关")
    }

    /// 反向回归：框画得巨大时也不能把 logo 撑满半张图
    func testHugeBoxDoesNotInflateLogo() {
        let huge = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        let result = BrandPlacementPlanner.adjust(box: huge, logoAspect: 3, canvas: canvas, hint: "加logo")
        XCTAssertLessThanOrEqual(result.width, canvas.width * 0.30 + 1)
        XCTAssertEqual(result.width / result.height, 3, accuracy: 0.02)
    }

    func testUserScaleHintsAreHonoured() {
        let box = CGRect(x: 0.05, y: 0.05, width: 0.3, height: 0.2)
        let normal = BrandPlacementPlanner.adjust(box: box, logoAspect: 2, canvas: canvas, hint: "加logo")
        let larger = BrandPlacementPlanner.adjust(box: box, logoAspect: 2, canvas: canvas, hint: "logo 大一点")
        let smaller = BrandPlacementPlanner.adjust(box: box, logoAspect: 2, canvas: canvas, hint: "logo 小一点")
        XCTAssertGreaterThan(larger.width, normal.width)
        XCTAssertLessThan(smaller.width, normal.width)
    }

    /// 竖向画布上的横向 logo 也必须留在安全区内
    func testPlacementNeverLeavesCanvas() {
        let narrow = CGSize(width: 600, height: 2400)
        let box = CGRect(x: 0.9, y: 0.95, width: 0.1, height: 0.05)
        let result = BrandPlacementPlanner.adjust(box: box, logoAspect: 4, canvas: narrow, hint: "右下角")
        XCTAssertGreaterThanOrEqual(result.minX, 0)
        XCTAssertGreaterThanOrEqual(result.minY, 0)
        XCTAssertLessThanOrEqual(result.maxX, narrow.width + 1)
        XCTAssertLessThanOrEqual(result.maxY, narrow.height + 1)
    }

    /// 「重新排版给 logo 让位」贴图做不到，必须识别出来交给重绘
    func testRelayoutIntentIsRecognised() {
        XCTAssertTrue(BrandPlacementPlanner.requestsRelayout("重新排版这张海报，把左上角留给logo"))
        XCTAssertTrue(BrandPlacementPlanner.requestsRelayout("标题挪开一点，给 logo 让位"))
        XCTAssertFalse(BrandPlacementPlanner.requestsRelayout("在左上角加上我们的logo"))
    }
}
