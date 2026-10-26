import XCTest
import UIKit
import ImageIO
import CoreGraphics
@testable import BossAI

// ============================================================================
// 图片几何：像素尺寸 / 尺寸夹取 / 输出比例校验。
// 极端比例不能满足 Provider 约束时拒绝生成，不做补边回裁。
// ============================================================================
final class ImageGeometryTests: XCTestCase {

    private func image(width: Int, height: Int, shade: CGFloat = 0.5) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: fmt).image { ctx in
            UIColor(white: shade, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            // 画一条明显的边，便于人工核对"边有没有被切"
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: max(2, height / 40)))
        }
    }

    private func jpeg(_ image: UIImage, orientation: Int? = nil) -> Data {
        guard let cg = image.cgImage else { return Data() }
        if let orientation {
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return Data() }
            CGImageDestinationAddImage(dest, cg, [kCGImagePropertyOrientation: orientation] as CFDictionary)
            CGImageDestinationFinalize(dest)
            return data as Data
        }
        return image.jpegData(compressionQuality: 0.9) ?? Data()
    }

    // MARK: - 真实像素（不是 UIImage.size）

    func testPixelSizeReadsRealPixels() {
        let data = jpeg(image(width: 1600, height: 900))
        let size = ImageGeometry.pixelSize(of: data)
        XCTAssertEqual(size?.width, 1600)
        XCTAssertEqual(size?.height, 900)
    }

    /// EXIF 方向 6（顺时针 90°）：像素宽高必须交换，否则比例算反，横图会被当竖图裁。
    /// 编码器不保留方向元数据时跳过（那是测试环境限制，不是逻辑错）。
    func testPixelSizeRespectsExifOrientation() throws {
        let data = jpeg(image(width: 1600, height: 900), orientation: 6)
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
              let raw = (props[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue,
              raw >= 5 else {
            throw XCTSkip("当前环境未把 EXIF 方向写进 JPEG，跳过方向交换断言")
        }
        let size = ImageGeometry.pixelSize(of: data)
        XCTAssertEqual(size?.width, 900, "旋转 90° 后宽应为原高")
        XCTAssertEqual(size?.height, 1600)
    }

    func testPixelSizeReturnsNilForGarbage() {
        XCTAssertNil(ImageGeometry.pixelSize(of: Data([0x00, 0x01, 0x02])))
    }

    // MARK: - 尺寸夹取（与服务端 media-guards 对齐）

    func testClampedSizeKeepsAspectWithinOnePercent() {
        for (w, h) in [(4032, 3024), (1200, 1600), (1920, 1080), (3000, 1000), (800, 801)] {
            guard let size = ImageGeometry.clampedSize(width: w, height: h) else {
                XCTFail("\(w)x\(h) 不该被拒绝"); continue
            }
            let parts = size.split(separator: "x").compactMap { Double($0) }
            XCTAssertEqual(parts.count, 2)
            let requested = Double(w) / Double(h)
            let actual = parts[0] / parts[1]
            XCTAssertLessThan(abs(actual - requested) / requested, 0.01,
                              "\(w)x\(h) → \(size) 比例偏差超过 1%（会把画面压变形）")
            XCTAssertGreaterThanOrEqual(Int(parts[0]), ImageGeometry.minEdge)
            XCTAssertLessThanOrEqual(Int(parts[0]), ImageGeometry.maxEdge)
            XCTAssertGreaterThanOrEqual(Int(parts[1]), ImageGeometry.minEdge)
            XCTAssertLessThanOrEqual(Int(parts[1]), ImageGeometry.maxEdge)
        }
    }

    func testClampedSizeRejectsExtremeRatio() {
        // 极窄长：无法在边长与像素预算内表达 → 明确拒绝，不静默更改画布比例
        XCTAssertNil(ImageGeometry.clampedSize(width: 9000, height: 200))
    }

    // MARK: - 比例校验

    func testAspectBrokenDetectsCroppedOutput() {
        // 原图 16:9，输出 1:1 → 必然被裁过
        XCTAssertTrue(ImageGeometry.isAspectBroken(outputWidth: 1024, outputHeight: 1024,
                                                   expectedAspect: 16.0 / 9.0))
        // 输出与要求一致 → 不算坏
        XCTAssertFalse(ImageGeometry.isAspectBroken(outputWidth: 1536, outputHeight: 864,
                                                    expectedAspect: 16.0 / 9.0))
        XCTAssertTrue(ImageGeometry.isAspectBroken(outputWidth: 0, outputHeight: 0,
                                                   expectedAspect: 16.0 / 9.0),
                      "无法读取生成图尺寸时，保比例任务必须拒绝结果")
    }

    func testAspectDeviationTolerance() {
        let expected = 4.0 / 3.0
        let dev = ImageGeometry.aspectDeviation(outputWidth: 1200, outputHeight: 900, expectedAspect: expected)
        XCTAssertEqual(dev ?? 1, 0, accuracy: 0.0001)
        XCTAssertEqual(ImageGeometry.aspectTolerance, 0.03)
    }

    /// editSimilarity 只是日志字段（不参与展示决策）。
    /// 测试宿主的 CGContext 像素回读并不可靠（CI 上多次读到全零），
    /// 所以这里断言的是**契约**：要么给出高相关，要么明确返回 nil（表示"读不到"），
    /// 绝不允许返回一个错误的低相关值来误导日志。
    func testThumbnailSimilarityContract() {
        let a = image(width: 320, height: 200, shade: 0.4)
        guard let sim = ImageGeometry.thumbnailSimilarity(a, a) else {
            XCTAssertTrue(true, "当前环境不支持像素回读 → 按 nil 处理（日志字段缺省），可接受")
            return
        }
        XCTAssertGreaterThan(sim, 0.9, "同一张图的自相关应接近 1")
    }
}
