import XCTest
import UIKit
import ImageIO
import CoreGraphics
@testable import BossAI

// ============================================================================
// 图片几何（10-25）：像素尺寸 / 尺寸夹取 / 比例校验 / 补边与回映射
// 这些是"P 图不裁切"的数学底座，任何一条错都会直接把用户的原图切掉边。
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

    /// EXIF 方向 6（顺时针 90°）：像素宽高必须交换，否则比例算反，横图会被当竖图裁
    func testPixelSizeRespectsExifOrientation() {
        let data = jpeg(image(width: 1600, height: 900), orientation: 6)
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
        // 极窄长：放大到最小边后总像素仍不够 → 明确拒绝，让上层走补边兜底
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
    }

    func testAspectDeviationTolerance() {
        let expected = 4.0 / 3.0
        let dev = ImageGeometry.aspectDeviation(outputWidth: 1200, outputHeight: 900, expectedAspect: expected)
        XCTAssertEqual(dev ?? 1, 0, accuracy: 0.0001)
        XCTAssertEqual(ImageGeometry.aspectTolerance, 0.03)
    }

    func testNearestSupportedRatio() {
        XCTAssertEqual(ImageGeometry.nearestSupportedRatio(16.0 / 9.0), "16:9")
        XCTAssertEqual(ImageGeometry.nearestSupportedRatio(1.0), "1:1")
        XCTAssertEqual(ImageGeometry.nearestSupportedRatio(0.75), "3:4")
        XCTAssertEqual(ImageGeometry.nearestSupportedRatio(1.333), "4:3")
    }

    // MARK: - 补边 + 回映射（固定比例兜底路径）

    func testPaddedReferenceKeepsWholeImageAndCropBackRestoresAspect() {
        // 3:2 横图，硬塞进 16:9 画布
        let source = image(width: 1200, height: 800)
        guard let padded = ImageGeometry.composePaddedReference(source, ratio: "16:9") else {
            return XCTFail("补边失败")
        }
        XCTAssertEqual(padded.contentRect.height, 1.0, accuracy: 0.001, "横向补边应在上下留白")
        XCTAssertLessThan(padded.contentRect.width, 1.0)
        // 生成结果（用补边图冒充模型输出）裁回内容区 → 比例应回到 3:2
        guard let generated = UIImage(data: padded.data),
              let restored = ImageGeometry.cropBack(generated, contentRect: padded.contentRect),
              let restoredSize = ImageGeometry.pixelSize(of: restored.jpegData(compressionQuality: 0.9) ?? Data()) else {
            return XCTFail("回映射失败")
        }
        let aspect = Double(restoredSize.width) / Double(restoredSize.height)
        XCTAssertEqual(aspect, 1200.0 / 800.0, accuracy: 0.03, "裁回后应恢复原图 3:2")
    }

    func testThumbnailSimilarityIsHighForSameImage() {
        let a = image(width: 320, height: 200, shade: 0.4)
        let sim = ImageGeometry.thumbnailSimilarity(a, a)
        XCTAssertNotNil(sim)
        XCTAssertGreaterThan(sim ?? -1, 0.99, "同一张图的自相关应为 1")
    }
}
