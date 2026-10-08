import XCTest
@testable import BossAIExpertCore

/// 检索规划与证据排序的回归测试。
/// 场景来自 2026-10-08 真机翻车截图：指令被字面拿去搜索、假日期加分、UGC 站点霸榜。
final class SearchPlanningTests: XCTestCase {

    // MARK: - SearchPlan.parse

    func testParsePlainJSON() throws {
        let json = #"{"intent":"multi","entities":["iPhone 18","华为 Mate90","小米 18"],"queries":[{"q":"iPhone 18 官方 售价","recency":"any"},{"q":"华为 Mate90 官方 参数","recency":"any"}]}"#
        let plan = try XCTUnwrap(SearchPlan.parse(json))
        XCTAssertEqual(plan.intent, "multi")
        XCTAssertEqual(plan.entities.count, 3)
        XCTAssertEqual(plan.queries.count, 2)
        XCTAssertEqual(plan.queries[0].query, "iPhone 18 官方 售价")
        XCTAssertEqual(plan.queries[0].recency, .any)
    }

    func testParseWithFenceAndPrefixText() throws {
        // 模型常无视"只输出 JSON"的指令，输出围栏或解释文字
        let fenced = """
        好的，以下是检索计划：
        ```json
        {"intent":"single","entities":[],"queries":[{"q":"iPhone 18 Pro 屏幕 电池 售价 官方","recency":"month"}]}
        ```
        """
        let plan = try XCTUnwrap(SearchPlan.parse(fenced))
        XCTAssertEqual(plan.intent, "single")
        XCTAssertEqual(plan.queries.count, 1)
        XCTAssertTrue(plan.queries[0].query.contains("iPhone 18 Pro"))
    }

    func testParseNoneIntentSkipsSearch() throws {
        // 翻车场景："做成一张统计图"是操作指令，不应再联网搜索
        let plan = try XCTUnwrap(SearchPlan.parse(#"{"intent":"none","entities":[],"queries":[]}"#))
        XCTAssertEqual(plan.intent, "none")
        XCTAssertTrue(plan.queries.isEmpty)
    }

    func testParseInvalidReturnsNil() {
        XCTAssertNil(SearchPlan.parse("这不是 JSON"))
        XCTAssertNil(SearchPlan.parse(#"{"intent":"single","entities":[],"queries":[]}"#)) // 无查询
        XCTAssertNil(SearchPlan.parse(#"{"intent":"single","queries":[{"q":"a","recency":"any"}]}"#)) // 查询太短
    }

    func testParseCapsQueriesAndStripsLongOnes() throws {
        let longQuery = String(repeating: "旗舰", count: 100)
        let json = #"{"intent":"multi","entities":[],"queries":[{"q":"\#(longQuery)","recency":"any"},{"q":"iPhone 18 售价","recency":"any"},{"q":"华为 Mate90 售价","recency":"any"},{"q":"小米 18 售价","recency":"any"},{"q":"vivo X500 售价","recency":"any"}]}"#
        let plan = try XCTUnwrap(SearchPlan.parse(json))
        XCTAssertEqual(plan.queries.count, 4) // 上限 4
        XCTAssertLessThanOrEqual(plan.queries[0].query.count, 120)
    }

    func testParseUnknownRecencyFallsBackToAny() throws {
        let plan = try XCTUnwrap(SearchPlan.parse(#"{"intent":"single","entities":[],"queries":[{"q":"iPhone 18 售价","recency":"Fortnight"}]}"#))
        XCTAssertEqual(plan.queries[0].recency, .any)
    }

    // MARK: - EvidenceRanking：UGC 降权

    func testUGCDomainDemoted() {
        let official = EvidenceRanking.score(query: "旗舰手机 售价",
                                             title: "苹果官网 iPhone 18 售价",
                                             url: "https://www.apple.com.cn/iphone-18",
                                             snippet: "官方售价 6999 元起",
                                             publishedAt: "")
        let video = EvidenceRanking.score(query: "旗舰手机 售价",
                                          title: "iPhone 18 售价爆料视频",
                                          url: "https://www.bilibili.com/video/BVxxx",
                                          snippet: "up 主整理的价格表",
                                          publishedAt: "")
        XCTAssertGreaterThan(official, video, "官方页必须排在 B 站视频之前")
    }

    // MARK: - EvidenceRanking：假日期不再加分

    func testUnverifiedPageDateScoresNoBonus() {
        let withFakeDate = EvidenceRanking.score(query: "旗舰手机",
                                                 title: "某聚合页",
                                                 url: "https://www.example.com/a",
                                                 snippet: "内容",
                                                 publishedAt: "页面日期 2021-05-25（未核实）")
        let noDate = EvidenceRanking.score(query: "旗舰手机",
                                           title: "某聚合页",
                                           url: "https://www.example.com/a",
                                           snippet: "内容",
                                           publishedAt: "")
        XCTAssertEqual(withFakeDate, noDate, "页面抓出来的假日期不应获得排序加分")
    }

    func testRumorPenaltyStillApplies() {
        let rumor = EvidenceRanking.score(query: "旗舰手机",
                                          title: "旗舰手机爆料汇总",
                                          url: "https://www.example.com/r",
                                          snippet: "内容",
                                          publishedAt: "")
        let plain = EvidenceRanking.score(query: "旗舰手机",
                                          title: "旗舰手机发布",
                                          url: "https://www.example.com/p",
                                          snippet: "内容",
                                          publishedAt: "")
        XCTAssertLessThan(rumor, plain)
    }

    // MARK: - ResearchIntent：泛主题 seed

    func testSearchSeedExtractsTopicNotInstructions() {
        let task = "请核实以下最新信息。主题：各大厂商旗舰手机 截至日期：今天 需要的字段：官方售价"
        XCTAssertEqual(ResearchIntent.searchSeed(from: task), "各大厂商旗舰手机")
    }

    func testNeedsLiveEvidence() {
        XCTAssertTrue(ResearchIntent.needsLiveEvidence("2026 旗舰手机最新售价"))
        XCTAssertFalse(ResearchIntent.needsLiveEvidence("做成一张统计图"))
    }
}
