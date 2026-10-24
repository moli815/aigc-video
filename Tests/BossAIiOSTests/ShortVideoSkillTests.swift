import XCTest
@testable import BossAI

// ============================================================================
// ShortVideoSkillTests —— 10-24 新增「短视频脚本」专家的契约测试
//
// 为什么要单独锁一份测试：
//   专家有两份配置源（Models/Expert.swift 的本地目录 + ExpertSkills.json 的能力档案），
//   历史上出过"只改一份"的事故（工具没挂上、模型只能说做不到）。
//   这里把「两份 ID 集合一致 + 契约字段 + 工具许可 + 与相邻专家的职责边界」钉死。
//
// 声明边界：本文件不测脚本写得好不好（那需要真实模型调用与人工评审，
//   见 docs/routing-eval-cases.md 的评测集），只测配置与权限的结构正确性。
// ============================================================================

final class ShortVideoSkillTests: XCTestCase {

    /// 两份配置源必须完全对齐：缺一个专家、多一个专家都要在这里挂掉
    func testCatalogAndSkillProfilesMatch() throws {
        let catalogIDs = Set(ExpertCatalog.bundledAll.map(\.id))
        let profileIDs = Set(try ExpertCapabilityCatalog.configuration.get().keys)
        XCTAssertEqual(catalogIDs, profileIDs,
                       "本地专家目录与 ExpertSkills.json 的 ID 集合不一致，会出现「专家可见但能力档案缺失」")
        XCTAssertTrue(catalogIDs.contains("short_video"), "缺少短视频脚本专家")
    }

    /// 能力档案的契约字段
    func testShortVideoProfileContract() throws {
        let p = try ExpertCapabilityCatalog.profile("short_video")
        XCTAssertEqual(p.name, "短视频脚本")
        XCTAssertEqual(p.documentFormats, ["word", "pdf"], "只允许导出 Word/PDF，不默认出 PPT")
        XCTAssertEqual(p.calculators, ["speech_duration"], "时长估算必须用已有的 speech_duration")
        XCTAssertTrue(p.allowSearch, "最新政策/价格需要联网核实")
        XCTAssertTrue(p.allowImages, "用户明确要封面/分镜图时需要生图能力")
        XCTAssertEqual(p.knowledge.count, 3)
        XCTAssertTrue(p.workflow.contains { $0.contains("3 个") }, "缺少「3 个差异化角度/钩子」的强制步骤")
        XCTAssertTrue(p.workflow.contains { $0.contains("speech_duration") }, "缺少口播时长核算步骤")
    }

    /// 合规边界必须写在能力档案里（不是只写在提示词里靠模型记）
    func testComplianceBoundaries() throws {
        let p = try ExpertCapabilityCatalog.profile("short_video")
        let joined = p.boundaries.joined()
        XCTAssertTrue(joined.contains("不保证播放量"), "必须明确不承诺爆款/涨粉/转化")
        XCTAssertTrue(joined.contains("不具备视频下载"), "必须写明没有视频解析能力，避免假装分析链接")
        XCTAssertTrue(joined.contains("分开标识"), "用户数据/计算结果/假设/联网事实必须分开标注")
    }

    /// 工具许可：该给的要给，未知工具一律拒绝
    func testToolPermissions() throws {
        let p = try ExpertCapabilityCatalog.profile("short_video")
        XCTAssertTrue(ExpertSkillRuntime.permits("web_search", profile: p))
        XCTAssertTrue(ExpertSkillRuntime.permits("image_generate", profile: p))
        XCTAssertTrue(ExpertSkillRuntime.permits("create_document", profile: p))
        XCTAssertTrue(ExpertSkillRuntime.permits("expert_skill", profile: p))
        XCTAssertFalse(ExpertSkillRuntime.permits("shell_exec", profile: p), "未知工具默认拒绝")
        // 云端裁剪成「只要文字」时，生图能力必须随之关闭（纯脚本请求不自动生图）
        XCTAssertFalse(ExpertSkillRuntime.permits("image_generate", profile: p, allowedTools: ["search", "word"]))
        XCTAssertFalse(ExpertSkillRuntime.permits("web_search", profile: p, allowedTools: ["word"]),
                       "用户说不要联网时，搜索必须真的关掉")
    }

    /// 目录里的专家本体：名称、工具、开场白
    func testExpertEntryAndStarters() {
        let expert = ExpertCatalog.find("short_video")
        XCTAssertEqual(expert.id, "short_video", "find 回退到了 general，说明目录里没有这个专家")
        XCTAssertEqual(expert.name, "短视频脚本")
        XCTAssertTrue(expert.skill.tools.contains(.search))
        XCTAssertTrue(expert.skill.tools.contains(.image))
        XCTAssertEqual(expert.skill.deliverable, DocumentFormat.word)
        XCTAssertEqual(ExpertCatalog.starters(for: expert).count, 3, "开场白应给三个真实入口")
        XCTAssertTrue(expert.systemPrompt.contains("分镜"), "技能包没进 system prompt")
    }

    /// 职责边界：不能把所有「内容」请求都路由到短视频
    func testBoundariesWithNeighbourExperts() {
        let role = ExpertCatalog.find("short_video").role
        XCTAssertTrue(role.contains("老板IP"), "缺少与老板IP的分工说明")
        XCTAssertTrue(role.contains("流量策划"), "缺少与流量策划的分工说明")
        XCTAssertTrue(role.contains("营销策划"), "缺少与营销策划的分工说明")
        XCTAssertTrue(role.contains("顶级演讲"), "缺少与演讲专家的分工说明")
        // 反向：老板IP 仍然存在且没有被短视频取代
        XCTAssertEqual(ExpertCatalog.find("boss_ip").id, "boss_ip")
    }

    /// 文档结构校验：章节缺失要能报出来（沿用既有 validateDocument 契约）
    func testDocumentValidationCatchesMissingSections() throws {
        let p = try ExpertCapabilityCatalog.profile("short_video")
        let draft = """
        # 创作策略
        面向制造业老板，用「买了工具但流程没变」的反差切入。

        # 标题与开头钩子
        1. 企业买了 AI，为什么员工还是没提效？

        # 分镜脚本
        | 时间 | 口播 | 画面 | 字幕 |
        |---|---|---|---|
        | 0-3s | 企业买了 AI，为什么员工反而更忙？ | 真人正面口播 | 买了 AI，为什么更忙？ |

        # 发布配套
        配文与话题建议。

        # 事实与质量自检
        未使用未经核实的行业数字；目标 30 秒，需实际试读复核。
        """
        XCTAssertTrue(try ExpertSkillRuntime.validateDocument(draft, format: "word", profile: p).structurePassed)
        let incomplete = "# 创作策略\n只有这一段，没有分镜也没有自检。"
        let result = try ExpertSkillRuntime.validateDocument(incomplete, format: "word", profile: p)
        XCTAssertFalse(result.structurePassed)
        XCTAssertTrue(result.missingSections.contains("分镜脚本"))
    }
}
