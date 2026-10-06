import XCTest
@testable import BossAIExpertCore

final class ResearchCoreTests: XCTestCase {
    func testLatestAvailableIsNotLimitedToLastThirtyDays() {
        XCTAssertEqual(SearchRecency.inferred(from: "最新在售旗舰手机价格"), .any)
        XCTAssertEqual(SearchRecency.inferred(from: "本月发布的产品"), .month)
        XCTAssertEqual(SearchRecency.inferred(from: "今天新闻"), .day)
    }
    func testQueryDeduplicationNormalizesWhitespaceAndCase() {
        let a = ResearchIntent.fingerprint("  IPHONE   Pro ", recency: "any")
        XCTAssertEqual(a, ResearchIntent.fingerprint("iphone pro", recency: "any"))
        XCTAssertNotEqual(a, ResearchIntent.fingerprint("iphone pro", recency: "month"))
    }
    func testRelevantEvidenceOutranksUnrelatedDatedAuthorityPage() {
        let good = EvidenceRanking.score(query: "iPhone battery", title: "iPhone battery specs", url: "https://support.apple.com/a", snippet: "iPhone battery official specifications", publishedAt: "")
        let bad = EvidenceRanking.score(query: "iPhone battery", title: "Other report", url: "https://example.gov/report", snippet: "unrelated topic", publishedAt: "2026-10-06")
        XCTAssertGreaterThan(good, bad)
    }
    func testAuthorityDomainCannotBeSpoofedAndRumorIsPenalized() {
        XCTAssertTrue(EvidenceRanking.isAuthority("https://support.apple.com/a"))
        XCTAssertFalse(EvidenceRanking.isAuthority("https://apple.com.evil.example/a"))
        XCTAssertFalse(EvidenceRanking.isAuthority("https://fakeapple.com/a"))
        let rumor = EvidenceRanking.score(query: "iPhone", title: "iPhone rumor", url: "https://news.example/a", snippet: "", publishedAt: "")
        let fact = EvidenceRanking.score(query: "iPhone", title: "iPhone specs", url: "https://news.example/a", snippet: "", publishedAt: "")
        XCTAssertLessThan(rumor, fact)
    }
    func testEvidenceBudgetStopsDuplicateAndExcessWorkAndMarksTruncation() {
        var budget = ResearchBudget(searchLimit: 2, characterLimit: 10)
        XCTAssertTrue(budget.reserve("a")); XCTAssertFalse(budget.reserve("a"))
        XCTAssertTrue(budget.reserve("b")); XCTAssertFalse(budget.reserve("c"))
        let value = budget.evidence("123456789012345")
        XCTAssertTrue(value.hasPrefix("1234567890")); XCTAssertTrue(value.contains("后续文本未注入"))
        XCTAssertEqual(budget.evidenceCharacters, 10)
        XCTAssertFalse(budget.reserve("d"))
    }
    func testModesHaveDifferentEvidenceContractsAndNeverDeleteRequestedFields() {
        XCTAssertTrue(ResearchMode.local.prompt.contains("禁止联网"))
        XCTAssertTrue(AnswerStyle.concise.prompt.contains("不删用户要求的对象和字段"))
        XCTAssertTrue(ResearchIntent.needsLiveEvidence("核实现行政策"))
        XCTAssertFalse(ResearchIntent.needsLiveEvidence("解释单位经济模型"))
    }
}
