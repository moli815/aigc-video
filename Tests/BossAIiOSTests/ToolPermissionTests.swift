import XCTest
@testable import BossAI

// ============================================================================
// P0-40 工具权限解析测试：**今天核心 bug 的回归锚点**。
// 历史缺陷：工具挂载用本地 ExpertSkills.json 的 allowImages 判定，与云端下发的专家
//   工具列表形成"两套配置"。云端给消防专家开了生图、本地档案仍是 false →
//   工具没挂上 → 模型如实回答"我无法生成图片"（客户投诉原话）。
// 修复原则（本测试锁定）：云端工具列表是单一数据源，云端开什么、客户端就挂什么。
// ============================================================================

final class ToolPermissionTests: XCTestCase {

    /// 回归：云端给专家配了生图工具 → 必须生效（即使本地档案是 false）
    func testCloudImageToolOverridesLocalDeny() throws {
        // fire_safety（消防专家）在本地档案中的 allowImages = false（历史遗留）
        let perms = try ChatService.resolveToolPermissions(expertID: "fire_safety", expertTools: [.search, .image, .word])
        XCTAssertTrue(perms.canImage, "云端开放的生图工具必须生效——修复前这里会因本地档案为 false 而失败")
        XCTAssertTrue(perms.canSearch)
    }

    /// 云端未配置某工具 → 不挂载（尊重云端裁剪）
    func testCloudToolsTrimAllowedSet() throws {
        let perms = try ChatService.resolveToolPermissions(expertID: "general", expertTools: [.word])
        XCTAssertFalse(perms.canImage, "云端未开生图时不挂生图工具")
        XCTAssertFalse(perms.canSearch, "云端未开搜索时不挂搜索工具")
        XCTAssertEqual(perms.docFormats, ["word"], "只挂云端配置的文档格式")
    }

    /// expertTools 为 nil（旧链路/自定义专家）→ 回退本地能力档案
    func testNilExpertToolsFallsBackToCapability() throws {
        let perms = try ChatService.resolveToolPermissions(expertID: "general", expertTools: nil)
        // general 的本地档案：allowSearch = true（内置通用助手必然可搜索）
        XCTAssertTrue(perms.canSearch)
    }

    /// 文档格式映射：四种文档工具全部授权时，格式枚举齐全且无重复
    func testDocumentFormatsMapping() throws {
        let perms = try ChatService.resolveToolPermissions(
            expertID: "general", expertTools: [.word, .ppt, .excel, .pdf])
        XCTAssertEqual(Set(perms.docFormats), Set(["word", "ppt", "excel", "pdf"]))
        XCTAssertEqual(perms.docFormats.count, 4, "无重复格式")
    }

    /// 云端空工具列表（明确禁用一切）→ 搜索/生图/文档全部不挂
    func testEmptyCloudToolsDisablesEverything() throws {
        let perms = try ChatService.resolveToolPermissions(expertID: "general", expertTools: [])
        XCTAssertFalse(perms.canSearch)
        XCTAssertFalse(perms.canImage)
        XCTAssertTrue(perms.docFormats.isEmpty)
    }
}
