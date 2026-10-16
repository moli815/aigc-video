import XCTest
@testable import BossAI

// ============================================================================
// P0-46 云端化落地测试：版本比较 + 图片压缩云端覆盖。
// 锁定两个不变量：①版本号比较正确（格式异常不打扰用户）②云端参数覆盖与复位正确。
// ============================================================================

final class CloudConfigTests: XCTestCase {

    override func tearDown() {
        // 静态覆盖状态会影响其它测试（ImageCompressorTests 依赖默认 1024），必须复位
        ImageCompressor.resetCloudConfig()
        super.tearDown()
    }

    // MARK: - 版本比较

    func testVersionComparison() {
        XCTAssertTrue(AppConfig.isVersion("v1.2.0", lowerThan: "v1.3.0"))
        XCTAssertFalse(AppConfig.isVersion("v1.2.0", lowerThan: "v1.2.0"))
        XCTAssertFalse(AppConfig.isVersion("v1.2.0", lowerThan: "v1.1.9"))
        XCTAssertTrue(AppConfig.isVersion("v1.2.0", lowerThan: "v2.0.0"))
        // 主版本大、次版本小的情况
        XCTAssertFalse(AppConfig.isVersion("v2.1.0", lowerThan: "v1.9.9"))
    }

    func testVersionFormatTolerance() {
        XCTAssertTrue(AppConfig.isVersion("1.0", lowerThan: "1.2.0"), "缺省补 0 的三元组比较")
        // 格式异常 → 返回 false（不打扰用户、不误报升级）
        XCTAssertFalse(AppConfig.isVersion("dev", lowerThan: "1.0.0"))
        XCTAssertFalse(AppConfig.isVersion("v1.2.0", lowerThan: "latest"))
        XCTAssertFalse(AppConfig.isVersion("", lowerThan: "1.0.0"))
    }

    func testVersionComponentsParsing() {
        XCTAssertEqual(AppConfig.versionComponents("v1.2.0")?.0, 1)
        XCTAssertEqual(AppConfig.versionComponents("v1.2.0")?.1, 2)
        XCTAssertEqual(AppConfig.versionComponents("v1.2.0")?.2, 0)
        XCTAssertNil(AppConfig.versionComponents("abc"))
    }

    // MARK: - 图片压缩云端覆盖

    func testImageCompressorCloudOverride() {
        ImageCompressor.applyCloudConfig(edge: 800, quality: 0.6)
        XCTAssertEqual(ImageCompressor.effectiveMaxEdge, 800)
        XCTAssertEqual(ImageCompressor.effectiveQuality, 0.6)
    }

    func testImageCompressorDefaultWhenNoOverride() {
        XCTAssertEqual(ImageCompressor.effectiveMaxEdge, ImageCompressor.maxEdge)
        XCTAssertEqual(ImageCompressor.effectiveQuality, ImageCompressor.quality)
    }

    func testImageCompressorNilDoesNotOverride() {
        ImageCompressor.applyCloudConfig(edge: 700, quality: nil)
        XCTAssertEqual(ImageCompressor.effectiveMaxEdge, 700)
        XCTAssertEqual(ImageCompressor.effectiveQuality, ImageCompressor.quality, "nil 质量不覆盖默认")

        ImageCompressor.resetCloudConfig()
        XCTAssertEqual(ImageCompressor.effectiveMaxEdge, ImageCompressor.maxEdge, "复位后回到默认")
    }
}
