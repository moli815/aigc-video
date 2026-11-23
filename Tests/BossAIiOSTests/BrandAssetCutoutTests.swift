import XCTest
import UIKit
@testable import BossAI

@MainActor
final class BrandAssetCutoutTests: XCTestCase {
    private func logo(background: UIColor = .white, hasWhiteInterior: Bool = false) -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 160, height: 120), format: format).image { c in
            background.setFill(); c.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
            UIColor.blue.setFill(); c.fill(CGRect(x: 35, y: 35, width: 90, height: 50))
            if hasWhiteInterior { UIColor.white.setFill(); c.fill(CGRect(x: 65, y: 50, width: 25, height: 20)) }
        }.pngData()!
    }
    private func pixels(_ data: Data) throws -> (Int, Int, [UInt8]) {
        let cg = try XCTUnwrap(UIImage(data: data)?.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        bytes.withUnsafeMutableBytes { raw in
            let c = CGContext(data: raw.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8,
                bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            c.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        return (cg.width, cg.height, bytes)
    }
    func testWhiteBackgroundBecomesAlphaWithoutRepaintingLogo() async throws {
        let result = try await BrandAssetCutout.prepare(logo(), mode: .auto, kind: .logo)
        let (w, h, p) = try pixels(result)
        XCTAssertLessThan(w, 160); XCTAssertLessThan(h, 120)
        XCTAssertEqual(p[3], 0)
        let center = ((h / 2) * w + w / 2) * 4
        XCTAssertLessThan(p[center], 10); XCTAssertGreaterThan(p[center + 2], 240); XCTAssertEqual(p[center + 3], 255)
        let attachment = XCTAttachment(image: UIImage(data: result)!); attachment.name = "logo-cutout-white-background"; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testSolidColoredBackgroundIsRemovedToo() async throws {
        let result = try await BrandAssetCutout.prepare(logo(background: .yellow), mode: .remove, kind: .logo)
        let (_, _, p) = try pixels(result)
        XCTAssertEqual(p[3], 0)
    }
    func testEnclosedWhiteArtworkIsNotGloballyErased() async throws {
        let result = try await BrandAssetCutout.prepare(logo(hasWhiteInterior: true), mode: .auto, kind: .logo)
        let (w, h, p) = try pixels(result)
        let center = ((h / 2) * w + w / 2) * 4
        XCTAssertGreaterThan(p[center], 240); XCTAssertGreaterThan(p[center + 1], 240)
        XCTAssertGreaterThan(p[center + 2], 240); XCTAssertEqual(p[center + 3], 255)
        XCTAssertEqual(p[3], 0)
    }
    func testAlreadyTransparentSourceIsByteExact() async throws {
        let original = logo(background: .clear)
        let result = try await BrandAssetCutout.prepare(original, mode: .auto, kind: .logo)
        XCTAssertEqual(result, original)
    }
    func testExplicitKeepAndQrQuietZonePreserveOriginalBytes() async throws {
        let original = logo()
        let kept = try await BrandAssetCutout.prepare(original, mode: .keep, kind: .logo)
        let qr = try await BrandAssetCutout.prepare(original, mode: .auto, kind: .qr)
        XCTAssertEqual(kept, original); XCTAssertEqual(qr, original)
        do { _ = try await BrandAssetCutout.prepare(original, mode: .remove, kind: .qr); XCTFail("must protect QR background") }
        catch { XCTAssertTrue(error is BrandAssetCutout.Failure) }
    }
    func testUnclearLogoFailsBeforeCallingPaidBackground() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let uniform = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80), format: format).image { c in
            UIColor.white.setFill(); c.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        }.pngData()!
        let ctx = ImageRequestContext(prompt: "替换Logo", references: [logo(), uniform], taskKind: "edit", qualityTier: "high",
            requestedCount: nil, aspectRatio: "4:3", renderIntent: "flat_artwork",
            structured: ["preserve_assets": [["reference_index": 2, "box": ["x": 0.1, "y": 0.1, "width": 0.2, "height": 0.2], "kind": "logo"]]], layerDecomposition: false)
        let plan = try XCTUnwrap(PreservedAssetWorkflow.plan(ctx)); var paidCalls = 0
        do { _ = try await PreservedAssetWorkflow.generate(plan: plan) { _ in paidCalls += 1; return self.logo() }; XCTFail("must reject ambiguous asset") }
        catch { XCTAssertTrue(error is BrandAssetCutout.Failure) }
        XCTAssertEqual(paidCalls, 0)
    }
    func testCutoutComposesOnDarkPosterWithoutWhiteRectangle() async throws {
        let original = logo()
        let ctx = ImageRequestContext(prompt: "替换Logo", references: [original, original], taskKind: "edit", qualityTier: "high",
            requestedCount: nil, aspectRatio: "4:3", renderIntent: "flat_artwork",
            structured: ["preserve_assets": [["reference_index": 2, "box": ["x": 0.1, "y": 0.1, "width": 0.7, "height": 0.4], "kind": "logo"]]], layerDecomposition: false)
        let plan = try XCTUnwrap(PreservedAssetWorkflow.plan(ctx))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let dark = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 120), format: format).image { c in
            UIColor.black.setFill(); c.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
        }.pngData()!
        let result = try await PreservedAssetWorkflow.generate(plan: plan) { _ in dark }
        let attachment = XCTAttachment(image: UIImage(data: result)!); attachment.name = "logo-cutout-dark-poster-composition"; attachment.lifetime = .keepAlways; add(attachment)
        let (w, _, p) = try pixels(result)
        let index = (15 * w + 18) * 4
        XCTAssertLessThan(p[index], 20); XCTAssertLessThan(p[index + 1], 20); XCTAssertLessThan(p[index + 2], 20)
    }
}
