import XCTest
@testable import BossAISearchCore
@testable import BossAIExpertCore

// ─────────────────────────────────────────────────────────────────────────────
// 检索质量回归测试（P0 检索质量主线）。
// 覆盖：标题重合率、日期解析、结果过滤/去重/同域限流、时效降权评分、
//       format 注入上限与防谎报文案。全部纯逻辑，不发起任何网络请求。
// ─────────────────────────────────────────────────────────────────────────────

final class SearchQualityTests: XCTestCase {

    // MARK: - titleOverlap 标题重合率

    func testTitleOverlapIdentical() {
        XCTAssertEqual(WebSearchService.titleOverlap("iPhone 17 价格公布", "iPhone 17 价格公布"), 1.0, accuracy: 0.001)
    }

    func testTitleOverlapDisjoint() {
        XCTAssertEqual(WebSearchService.titleOverlap("苹果发布会", "红烧肉做法大全"), 0.0, accuracy: 0.001)
    }

    func testTitleOverlapHighSimilarity() {
        // 同一篇稿子的两个转载标题：短串字符基本都被长串覆盖 → ≥0.6 触发合并
        let overlap = WebSearchService.titleOverlap("iPhone17ProMax正式发布售价8999元起",
                                                    "iPhone 17 Pro Max 正式发布，售价 8999 元起")
        XCTAssertGreaterThanOrEqual(overlap, 0.6, "近重复标题应被识别为同一篇")
    }

    func testTitleOverlapIgnoresWhitespaceAndPunctuation() {
        XCTAssertEqual(WebSearchService.titleOverlap("售价，4999元", "售价4999元"), 1.0, accuracy: 0.001)
    }

    func testTitleOverlapEmptySafe() {
        XCTAssertEqual(WebSearchService.titleOverlap("", "任意"), 0.0)
        XCTAssertEqual(WebSearchService.titleOverlap("", ""), 0.0)
    }

    // MARK: - parseDateTokenPublic 日期解析

    func testParseDateISOFormat() {
        XCTAssertNotNil(WebSearchService.parseDateTokenPublic("2026-10-14"))
        XCTAssertNotNil(WebSearchService.parseDateTokenPublic("2026年10月14日"))
    }

    func testParseDateRelativeTokens() {
        XCTAssertNotNil(WebSearchService.parseDateTokenPublic("3天前"))
        XCTAssertNotNil(WebSearchService.parseDateTokenPublic("昨天"))
    }

    func testParseDateGarbageReturnsNil() {
        XCTAssertNil(WebSearchService.parseDateTokenPublic(""))
        XCTAssertNil(WebSearchService.parseDateTokenPublic("完全不是日期的文字"))
    }

    // MARK: - rankRelevant 结果过滤

    private func hit(_ title: String, url: String, snippet: String = "iPhone 17 价格 相关内容", date: String = "") -> SearchHit {
        SearchHit(title: title, url: url, snippet: snippet, publishedAt: date)
    }

    func testRankRelevantDropsNoiseTitles() {
        // 推荐流/站点导航类标题与查询无相关 → 应被 ResearchIntent.relevance>0 过滤
        let result = WebSearchService.rankRelevant(
            query: "iPhone 17 价格",
            hits: [
                hit("iPhone 17 官方价格公布", url: "https://www.apple.com/newsroom/price"),
                hit("相关推荐", url: "https://feed.example.com/rec"),
                hit("百度为您找到相关结果", url: "https://www.baidu.com/s?wd=1"),
            ],
            count: 8)
        XCTAssertFalse(result.contains { $0.title == "相关推荐" })
        XCTAssertFalse(result.contains { $0.title.contains("百度为您找到") })
        XCTAssertTrue(result.contains { $0.title.contains("iPhone 17 官方价格") })
    }

    func testRankRelevantMergesNearDuplicates() {
        let result = WebSearchService.rankRelevant(
            query: "iPhone 17 价格",
            hits: [
                hit("iPhone17ProMax正式发布售价8999元起", url: "https://news-a.com/p1"),
                hit("iPhone 17 Pro Max 正式发布，售价 8999 元起", url: "https://news-b.com/p2"),
            ],
            count: 8)
        XCTAssertEqual(result.count, 1, "标题重合率≥0.6 的同稿转载只保留一条")
    }

    func testRankRelevantSameDomainCap() {
        var hits: [SearchHit] = []
        for i in 1...5 {
            hits.append(hit("iPhone 17 价格解读第\(i)篇完全不同的角度分析\(i)", url: "https://same.com/p\(i)"))
        }
        let result = WebSearchService.rankRelevant(query: "iPhone 17 价格", hits: hits, count: 8)
        let sameDomain = result.filter { URL(string: $0.url)?.host == "same.com" }
        XCTAssertLessThanOrEqual(sameDomain.count, 2, "同域名最多保留 2 条，防单一站点刷屏")
    }

    func testRankRelevantRespectsCount() {
        var hits: [SearchHit] = []
        for i in 1...10 {
            hits.append(hit("iPhone 17 价格资讯第\(i)批独家完整报告", url: "https://site\(i).com/p"))
        }
        let result = WebSearchService.rankRelevant(query: "iPhone 17 价格", hits: hits, count: 3)
        XCTAssertEqual(result.count, 3)
    }

    func testRankRelevantDeduplicatesCanonicalURL() {
        let result = WebSearchService.rankRelevant(
            query: "iPhone 17 价格",
            hits: [
                hit("iPhone 17 价格公布第一手消息", url: "https://example.com/page"),
                hit("iPhone 17 价格公布另一角度独家报道", url: "https://example.com/page?utm_source=x"),
            ],
            count: 8)
        // URL 带 utm 参数视为同一 canonical 地址 → 去重
        XCTAssertLessThanOrEqual(result.count, 2)
    }

    // MARK: - EvidenceRanking 新鲜度降权（P0 检索质量核心）

    func testRecencyPenaltyForMissingDate() {
        let base = "iPhone 17 价格"
        let noDate = EvidenceRanking.score(query: base, title: "iPhone 17 价格公布", url: "https://a.com", snippet: "价格 内容", publishedAt: "", recency: .week)
        let withAny = EvidenceRanking.score(query: base, title: "iPhone 17 价格公布", url: "https://a.com", snippet: "价格 内容", publishedAt: "", recency: .any)
        XCTAssertEqual(withAny - noDate, 6, "时效查询中无日期结果应被 -6 轻惩罚")
    }

    func testRecencyPenaltyForExpiredDate() {
        let base = "iPhone 17 价格"
        let old = EvidenceRanking.score(query: base, title: "iPhone 17 价格公布", url: "https://a.com", snippet: "价格 内容", publishedAt: "2023-01-01", recency: .week)
        let fresh = EvidenceRanking.score(query: base, title: "iPhone 17 价格公布", url: "https://a.com", snippet: "价格 内容", publishedAt: "2026-10-13", recency: .week)
        XCTAssertGreaterThan(fresh, old, "时效查询中新鲜结果应排在过期结果前面")
        XCTAssertEqual(fresh - old, 14, "同为有日期结果，仅新鲜度差值应恰好为 14")
    }

    func testNoRecencyPenaltyWhenAny() {
        let old = EvidenceRanking.score(query: "iPhone 17 价格", title: "iPhone 17 价格公布", url: "https://a.com", snippet: "价格 内容", publishedAt: "2023-01-01", recency: .any)
        let noDate = EvidenceRanking.score(query: "iPhone 17 价格", title: "iPhone 17 价格公布", url: "https://a.com", snippet: "价格 内容", publishedAt: "", recency: .any)
        XCTAssertEqual(old - noDate, 1, "不限时效时，仅保留有日期 +1 的普通加分，无额外降权")
    }

    // MARK: - SearchRecency 推断

    func testRecencyInference() {
        XCTAssertEqual(SearchRecency.inferred(from: "今天金价多少"), .day)
        XCTAssertEqual(SearchRecency.inferred(from: "本周油价"), .week)
        XCTAssertEqual(SearchRecency.inferred(from: "本月销量榜"), .month)
        // "最新在售"是有效状态而非时间戳，不得推断为 month
        XCTAssertEqual(SearchRecency.inferred(from: "最新在售机型"), .any)
    }

    // MARK: - format 注入上限与防谎报文案

    func testFormatCapsInjectionAtEight() {
        var hits: [SearchHit] = []
        for i in 1...12 {
            hits.append(SearchHit(title: "iPhone 17 价格资讯第\(i)批独家完整报告标题", url: "https://s\(i).com/p", snippet: "iPhone 17 价格 摘要\(i)", publishedAt: "2026-09-\(i < 10 ? "0\(i)" : String(i))"))
        }
        let out = WebSearchService.format(hits: hits, pages: [])
        XCTAssertTrue(out.contains("取前 8 条注入"), "注入说明应声明上限 8 条")
        XCTAssertFalse(out.contains("\n12. iPhone 17 价格资讯第12批"), "第 9 条起不得注入")
        // 防谎报三要素
        XCTAssertTrue(out.contains("外部证据边界"))
        XCTAssertTrue(out.contains("未核实"))
        XCTAssertTrue(out.contains("严禁"))
    }

    func testFormatUndatedMarkedUnverified() {
        let out = WebSearchService.format(hits: [hit("iPhone 17 价格报道", url: "https://a.com")], pages: [])
        XCTAssertTrue(out.contains("发布时间未核实"), "无日期结果必须标注「发布时间未核实」")
    }
}
