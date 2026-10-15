import XCTest
@testable import BossAI

// ============================================================================
// P0-43 远程专家目录映射测试：SaaS 化的安全红线。
// 云端目录可能被误改（缺字段/未知工具/空名）——映射层的职责是"坏配置最多让个别专家降级，
//   绝不让 App 崩溃、绝不让列表变空"。这些测试锁定该契约。
// ============================================================================

final class RemoteCatalogMappingTests: XCTestCase {

    /// 完整云端条目 → 映射正确（工具/emoji/交付物全保留）
    func testFullDTOMapping() {
        let dto = RemoteCatalogService.ExpertDTO(
            id: "fire_safety", name: "消防专家·云端版", subtitle: "新的副标题", symbol: "flame.fill",
            role: "云端角色", framework: "云端框架", steps: ["步骤A", "步骤B"],
            deliverable: "excel", tools: ["search", "image", "excel"], checklist: ["检查1"],
            freshnessCue: "云端时效", emoji: "🚒"
        )
        let mapped = RemoteCatalogService.mapExperts([dto], bundled: ExpertCatalog.bundledAll)
        XCTAssertEqual(mapped.count, 1)
        let e = mapped[0]
        XCTAssertEqual(e.name, "消防专家·云端版")
        XCTAssertEqual(e.emoji, "🚒")
        XCTAssertEqual(e.skill.deliverable, .excel)
        XCTAssertEqual(e.skill.tools, [.search, .image, .excel])
        XCTAssertEqual(e.skill.steps, ["步骤A", "步骤B"])
    }

    /// 缺字段 → 从内置同 id 专家兜底（改名不改能力）
    func testPartialDTOFallsBackToBundled() {
        let dto = RemoteCatalogService.ExpertDTO(
            id: "fire_safety", name: "消防专家", subtitle: nil, symbol: nil, role: nil,
            framework: nil, steps: nil, deliverable: nil, tools: nil, checklist: nil,
            freshnessCue: nil, emoji: nil
        )
        let mapped = RemoteCatalogService.mapExperts([dto], bundled: ExpertCatalog.bundledAll)
        XCTAssertEqual(mapped.count, 1)
        let e = mapped[0]
        // 内置消防专家必有角色与工具（兜底生效）
        XCTAssertFalse(e.role.isEmpty, "缺字段时必须回退内置专家而非产生空角色")
        XCTAssertFalse(e.skill.tools.isEmpty, "缺工具字段时回退内置工具集")
        XCTAssertEqual(e.emoji, "🧯", "emoji 缺省时回退内置")
    }

    /// 未知工具字符串被忽略（不崩溃、不产生非法枚举）
    func testUnknownToolsIgnored() {
        let dto = RemoteCatalogService.ExpertDTO(
            id: "general", name: "通用对话", subtitle: nil, symbol: nil, role: nil,
            framework: nil, steps: nil, deliverable: nil,
            tools: ["search", "teleport", "image"], checklist: nil, freshnessCue: nil, emoji: nil
        )
        let mapped = RemoteCatalogService.mapExperts([dto], bundled: ExpertCatalog.bundledAll)
        XCTAssertEqual(mapped.first?.skill.tools, [.search, .image], "未知工具 teleport 必须被忽略")
    }

    /// 未知交付物 → 回退 word
    func testUnknownDeliverableFallsBackToWord() {
        let dto = RemoteCatalogService.ExpertDTO(
            id: "general", name: "通用对话", subtitle: nil, symbol: nil, role: nil,
            framework: nil, steps: nil, deliverable: "hologram", tools: ["search"],
            checklist: nil, freshnessCue: nil, emoji: nil
        )
        let mapped = RemoteCatalogService.mapExperts([dto], bundled: ExpertCatalog.bundledAll)
        XCTAssertEqual(mapped.first?.skill.deliverable, .word)
    }

    /// 空 id / 空 name 条目被丢弃；全部非法 → 映射为空（调用方据此回退内置目录）
    func testInvalidEntriesDropped() {
        let bad1 = RemoteCatalogService.ExpertDTO(
            id: "", name: "无名", subtitle: nil, symbol: nil, role: nil, framework: nil,
            steps: nil, deliverable: nil, tools: nil, checklist: nil, freshnessCue: nil, emoji: nil)
        let bad2 = RemoteCatalogService.ExpertDTO(
            id: "x", name: "", subtitle: nil, symbol: nil, role: nil, framework: nil,
            steps: nil, deliverable: nil, tools: nil, checklist: nil, freshnessCue: nil, emoji: nil)
        XCTAssertTrue(RemoteCatalogService.mapExperts([bad1, bad2], bundled: ExpertCatalog.bundledAll).isEmpty)
    }

    /// 云端新增专家（内置中不存在）→ 正常入列，走最保守默认值
    func testNewExpertFromCloud() {
        let dto = RemoteCatalogService.ExpertDTO(
            id: "brand_new", name: "全新专家", subtitle: "云端新增", symbol: nil, role: "角色",
            framework: nil, steps: ["第一步"], deliverable: nil, tools: ["search"],
            checklist: nil, freshnessCue: nil, emoji: "🆕"
        )
        let mapped = RemoteCatalogService.mapExperts([dto], bundled: ExpertCatalog.bundledAll)
        XCTAssertEqual(mapped.count, 1)
        XCTAssertEqual(mapped[0].id, "brand_new")
        XCTAssertEqual(mapped[0].emoji, "🆕")
    }
}
