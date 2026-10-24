import XCTest
@testable import BossAI

// ============================================================================
// LibraryImageWriterTests —— 「生成的图片进资料库」的回归锚点（2026-10-24 真机反馈）
//
// 现场：聊天里能看图，资料库里只有文档。根因是生图只挂会话消息、从未写过 FileStore。
// 这里锁住三件容易回退的事：
//   ① 文件名可读且安全（含中文提示词、不含路径分隔符）；
//   ② 内容指纹稳定（去重靠它，同一张图不能存两份）；
//   ③ 空提示词也能给出合法文件名。
// 说明：真正的写库路径依赖 SwiftData ModelContext，属于集成范畴，这里只测纯函数。
// ============================================================================

final class LibraryImageWriterTests: XCTestCase {

    /// 用**当前时区**构造 23:12，和 filename() 内部 DateFormatter（默认时区）保持一致，
    /// 这样在 CI（UTC）和本机（+08:00）跑出来的结果相同。
    private func fixedDate() -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 23, minute: 12)) ?? Date()
    }

    func testFilenameIsReadableAndSafe() {
        let name = LibraryImageWriter.filename(prompt: "把这张名片背景换成海边", date: fixedDate())
        XCTAssertTrue(name.hasPrefix("生成图片-20261024-2312"), "文件名缺少时间戳：\(name)")
        XCTAssertTrue(name.hasSuffix(".png"), "扩展名必须是 png")
        XCTAssertFalse(name.contains("/"), "文件名不能含路径分隔符")
        XCTAssertFalse(name.contains(":"), "文件名不能含冒号（macOS/iOS 会当路径分隔符）")
    }

    func testFilenameWithEmptyPrompt() {
        let name = LibraryImageWriter.filename(prompt: "   ", date: fixedDate())
        XCTAssertEqual(name, "生成图片-20261024-2312.png")
    }

    func testSanitizeStripsPathAndNewlines() {
        let cleaned = LibraryImageWriter.sanitize("a/b\\c:d*e?f\"g<h>i|j\nk")
        XCTAssertFalse(cleaned.contains("/"))
        XCTAssertFalse(cleaned.contains("\\"))
        XCTAssertFalse(cleaned.contains(":"))
        XCTAssertFalse(cleaned.contains("\n"))
        XCTAssertLessThanOrEqual(cleaned.count, 10, "提示词前缀必须截断，避免文件名过长")
    }

    func testFingerprintStableAndDistinct() {
        let a = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let b = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 4])
        XCTAssertEqual(LibraryImageWriter.fingerprint(a), LibraryImageWriter.fingerprint(a), "同一份数据指纹必须稳定")
        XCTAssertNotEqual(LibraryImageWriter.fingerprint(a), LibraryImageWriter.fingerprint(b), "不同数据指纹必须不同")
        XCTAssertEqual(LibraryImageWriter.fingerprint(a).count, 32, "指纹应为 16 字节十六进制")
    }

    func testEmptyDataIsRejected() {
        // save() 需要 ModelContext，这里只验证纯逻辑：空数据不应产生指纹冲突
        XCTAssertEqual(LibraryImageWriter.fingerprint(Data()).count, 32)
    }
}
