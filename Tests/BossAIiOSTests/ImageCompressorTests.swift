import XCTest
import UIKit
@testable import BossAI

// ============================================================================
// P0-42 图片压缩测试：视觉成本控制的质量红线。
// 背景：视觉模型计费 ≈ 像素数 ÷ 750。压缩到长边 1024 后单次识别成本降约 90%；
//   这些测试锁定"压缩必然发生、且产物合规"两个不变量，防止未来改动悄悄放大成本。
// ============================================================================

final class ImageCompressorTests: XCTestCase {

    /// 造一张指定尺寸的测试图（纯色+几条线，避免纯色被 JPEG 压到极小失真）。
    /// 注意 scale 固定为 1：默认 scale 会随模拟器屏幕倍率（2x/3x）放大实际像素数，
    /// 让"800×600 输入"变成 1600×1200 —— 曾导致 testSmallImageNotUpscaled 误报失败。
    private func makeImageData(width: CGFloat, height: CGFloat) -> Data {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setStroke()
            for i in stride(from: 0, to: width, by: 37) {
                ctx.cgContext.move(to: CGPoint(x: i, y: 0))
                ctx.cgContext.addLine(to: CGPoint(x: i, y: height))
                ctx.cgContext.strokePath()
            }
        }
        return image.pngData()!
    }

    /// 超大图（2000×1500）→ 长边被压到 1024 内，且体积合规
    func testLargeImageIsDownscaled() throws {
        let raw = makeImageData(width: 2000, height: 1500)
        let out = try XCTUnwrap(ImageCompressor.compressedData(from: raw))
        let img = try XCTUnwrap(UIImage(data: out))
        XCTAssertLessThanOrEqual(max(img.size.width, img.size.height), ImageCompressor.maxEdge + 0.5,
                                 "长边必须压到 1024 以内（长边 2000 的原图不得直传）")
        XCTAssertLessThanOrEqual(out.count, ImageCompressor.maxBytes)
        XCTAssertGreaterThan(out.count, 0)
    }

    /// 长宽比保持：2000×1000 → 1024×512（宽高比 2:1 不失真）
    func testAspectRatioPreserved() throws {
        let raw = makeImageData(width: 2000, height: 1000)
        let out = try XCTUnwrap(ImageCompressor.compressedData(from: raw))
        let img = try XCTUnwrap(UIImage(data: out))
        XCTAssertEqual(img.size.width / img.size.height, 2.0, accuracy: 0.02)
    }

    /// 小图不放大：800×600 输入 → 尺寸保持（scale 不得 > 1）
    func testSmallImageNotUpscaled() throws {
        let raw = makeImageData(width: 800, height: 600)
        let out = try XCTUnwrap(ImageCompressor.compressedData(from: raw))
        let img = try XCTUnwrap(UIImage(data: out))
        XCTAssertLessThanOrEqual(img.size.width, 800.5)
        XCTAssertLessThanOrEqual(img.size.height, 600.5)
    }

    /// 非法数据 → nil（调用方降级为"仅 OCR 文本"，绝不中断发送）
    func testInvalidDataReturnsNil() {
        XCTAssertNil(ImageCompressor.compressedData(from: Data()))
        XCTAssertNil(ImageCompressor.compressedData(from: Data("not an image".utf8)))
    }

    /// 输出恒定是 JPEG（MIME 与内容一致；多模态接口对格式有要求）
    func testOutputIsJPEG() throws {
        let raw = makeImageData(width: 1600, height: 1200)
        let out = try XCTUnwrap(ImageCompressor.compressedData(from: raw))
        // JPEG 魔数：FF D8
        XCTAssertEqual(out[0], 0xFF)
        XCTAssertEqual(out[1], 0xD8)
    }
}
