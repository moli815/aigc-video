import XCTest
import UIKit
@testable import BossAI

// ============================================================================
// P0-35 海报叠字测试：零乱码闭环的布局不变量。
// 核心保证：①任何输入都产出在画布内的区块（不越界）②字号始终在可读区间
//   ③合成输出尺寸与底图一致（不裁剪、不放大）④空输入优雅退化。
// ============================================================================

final class PosterComposerTests: XCTestCase {

    private let canvas = CGSize(width: 864, height: 1152)

    /// 完整输入 → 标题/副标题/要点三部分都在
    func testFullLayoutBlocks() {
        let blocks = PosterComposer.computeTextLayout(
            canvasSize: canvas, title: "消防安全 人人有责",
            subtitle: "隐患险于明火 防范胜于救灾",
            bullets: ["定期检查灭火器", "保持通道畅通", "组织消防演练"])
        XCTAssertEqual(blocks.count, 5)
        XCTAssertTrue(blocks[0].bold, "标题必须粗体")
        XCTAssertTrue(blocks[0].centered, "标题居中")
        XCTAssertFalse(blocks[2].centered, "要点左对齐")
    }

    /// 要点超过 6 条 → 截断到 6（版面保护）
    func testBulletsCappedAtSix() {
        let bullets = (1...10).map { "第\($0)条要点" }
        let blocks = PosterComposer.computeTextLayout(canvasSize: canvas, title: "标题", subtitle: "", bullets: bullets)
        // 1 标题 + 6 要点
        XCTAssertEqual(blocks.count, 7)
    }

    /// 空标题 → 不产生标题块；全空 → 空布局（调用方会直接返回底图）
    func testEmptyInputsDegradeGracefully() {
        let noTitle = PosterComposer.computeTextLayout(canvasSize: canvas, title: "", subtitle: "副标题", bullets: [])
        XCTAssertEqual(noTitle.count, 1)
        let allEmpty = PosterComposer.computeTextLayout(canvasSize: canvas, title: "", subtitle: "", bullets: [])
        XCTAssertTrue(allEmpty.isEmpty)
    }

    /// 零尺寸画布 → 空布局（防除零/崩溃）
    func testZeroCanvasReturnsEmpty() {
        XCTAssertTrue(PosterComposer.computeTextLayout(canvasSize: .zero, title: "x", subtitle: "y", bullets: ["z"]).isEmpty)
    }

    /// 所有区块的像素矩形必须在画布内（不越界不裁剪）
    func testPixelRectsStayInsideCanvas() {
        let blocks = PosterComposer.computeTextLayout(
            canvasSize: canvas, title: "很长很长的标题测试两行换行的情况",
            subtitle: "副标题", bullets: (1...6).map { "要点\($0)" })
        for block in blocks {
            let rect = PosterComposer.pixelRect(for: block, canvasSize: canvas)
            XCTAssertGreaterThanOrEqual(rect.minX, 0)
            XCTAssertGreaterThanOrEqual(rect.minY, 0)
            XCTAssertLessThanOrEqual(rect.maxX, canvas.width + 0.5)
            XCTAssertLessThanOrEqual(rect.maxY, canvas.height + 0.5)
            XCTAssertGreaterThan(rect.width, 1)
            XCTAssertGreaterThan(rect.height, 1)
        }
    }

    /// 字号钳制：小画布不低于下限、超大画布不超过上限
    func testFontSizeClamped() {
        let block = PosterComposer.computeTextLayout(canvasSize: canvas, title: "T", subtitle: "", bullets: [])[0]
        XCTAssertEqual(PosterComposer.fontSize(for: block, canvasWidth: 100), PosterComposer.fontSizeRange.lowerBound)
        XCTAssertEqual(PosterComposer.fontSize(for: block, canvasWidth: 10000), PosterComposer.fontSizeRange.upperBound)
    }

    /// 合成输出尺寸与底图一致（不裁剪、不缩放）
    func testComposeKeepsCanvasSize() throws {
        let renderer = UIGraphicsImageRenderer(size: canvas)
        let base = renderer.image { ctx in
            UIColor.systemRed.setFill()
            ctx.fill(CGRect(origin: .zero, size: canvas))
        }
        let out = try XCTUnwrap(PosterComposer.compose(
            base: base, title: "测试标题", subtitle: "测试副标题", bullets: ["要点一", "要点二"]))
        XCTAssertEqual(out.size.width, canvas.width, accuracy: 0.5)
        XCTAssertEqual(out.size.height, canvas.height, accuracy: 0.5)
    }

    /// 无文字输入 → 原图返回（不产生无谓重编码）
    func testComposeWithNoTextReturnsBase() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 300))
        let base = renderer.image { ctx in
            UIColor.blue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
        }
        let out = try XCTUnwrap(PosterComposer.compose(base: base, title: "", subtitle: "", bullets: []))
        XCTAssertEqual(out.size.width, base.size.width)
        XCTAssertEqual(out.size.height, base.size.height)
    }
}
