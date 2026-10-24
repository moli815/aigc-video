import XCTest
import UIKit
@testable import BossAI

// ============================================================================
// ImageQualityCheckerTests —— 生成结果质检的回归（2026-10-24 新增）
//
// 目标：把「模型返回了 URL 就算成功」改成「能解码、尺寸够、比例对」才算成功。
// 这里只测确定性路径（空数据、垃圾数据、过小图、比例偏差），不测审美。
// ============================================================================

final class ImageQualityCheckerTests: XCTestCase {

    func testEmptyPayload() {
        let report = ImageQualityChecker.check(Data())
        XCTAssertEqual(report.issues, [.emptyPayload])
        XCTAssertNil(report.pixelSize)
        XCTAssertTrue(ImageQualityChecker.shouldRegenerate(report), "空数据必须重生成，而不是重保存")
    }

    func testUndecodableBytes() {
        let junk = Data(repeating: 0x7A, count: 4096)
        let report = ImageQualityChecker.check(junk)
        XCTAssertEqual(report.issues, [.undecodable])
        XCTAssertTrue(ImageQualityChecker.shouldRegenerate(report))
    }

    func testSmallImageIsRejected() throws {
        let data = try XCTUnwrap(solidImage(size: 64).pngData())
        let report = ImageQualityChecker.check(data, expectedAspect: "1:1")
        XCTAssertTrue(report.issues.contains(.tooSmall), "64pt 的图放大到全屏必糊")
    }

    func testGoodImagePasses() throws {
        let data = try XCTUnwrap(solidImage(size: 512).pngData())
        let report = ImageQualityChecker.check(data, expectedAspect: "1:1")
        XCTAssertTrue(report.isAcceptable, "512×512 方图应通过：\(report.summary)")
        // 渲染器的 scale 随运行环境变化（1x/2x/3x），只断言"不小于请求尺寸"
        XCTAssertGreaterThanOrEqual(report.pixelSize?.width ?? 0, 512)
    }

    func testAspectDeviationCaught() throws {
        // 400×800 = 0.5，要求 3:4 = 0.75，偏差 33% → 必须报出来
        let data = try XCTUnwrap(solidImage(size: CGSize(width: 400, height: 800)).pngData())
        let report = ImageQualityChecker.check(data, expectedAspect: "3:4")
        XCTAssertTrue(report.issues.contains(.unexpectedRatio), "要 3:4 给了 1:2 必须拦")
    }

    func testAspectValueParsing() throws {
        // aspectValue 返回 Double?，带 accuracy 的断言必须先解包（CI 上一版就死在这里）
        let square = try XCTUnwrap(ImageQualityChecker.aspectValue("3:4"))
        XCTAssertEqual(square, 0.75, accuracy: 0.0001)
        let wide = try XCTUnwrap(ImageQualityChecker.aspectValue("16：9"))
        XCTAssertEqual(wide, 16.0 / 9.0, accuracy: 0.0001)
        XCTAssertNil(ImageQualityChecker.aspectValue("随便"))
    }

    func testTruncatedPayloadDoesNotForceRegenerate() {
        // 体积异常小只说明"可能没下全"，应该先重下，不要直接重新生成花钱
        let report = ImageQualityReport(issues: [.suspiciouslySmallPayload], pixelSize: CGSize(width: 512, height: 512))
        XCTAssertFalse(ImageQualityChecker.shouldRegenerate(report))
    }

    // MARK: - 工具

    private func solidImage(size: CGFloat) -> UIImage { solidImage(size: CGSize(width: size, height: size)) }

    private func solidImage(size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }
}
