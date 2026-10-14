import XCTest
@testable import BossAI

/// ChatGPT 式分池额度：对话（默认 ¥100/月）与生图（默认 ¥40/月）独立计费、独立限额。
final class BudgetTrackerTests: XCTestCase {
    private let chatLimitKey = "bossai.monthly_limit_chat_cny"
    private let imageLimitKey = "bossai.monthly_limit_image_cny"
    private let chatMonthKey = "bossai.budget_month_chat"
    private let chatSpentKey = "bossai.spent_chat_cny"
    private let imageMonthKey = "bossai.budget_month_image"
    private let imageSpentKey = "bossai.spent_image_cny"

    private var currentMonth: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM"; return f.string(from: Date())
    }

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: chatLimitKey)
        UserDefaults.standard.removeObject(forKey: imageLimitKey)
        UserDefaults.standard.set(currentMonth, forKey: chatMonthKey)
        UserDefaults.standard.set(90.0, forKey: chatSpentKey)
        UserDefaults.standard.set(currentMonth, forKey: imageMonthKey)
        UserDefaults.standard.set(39.0, forKey: imageSpentKey)
    }

    override func tearDown() {
        for key in [chatMonthKey, chatSpentKey, imageMonthKey, imageSpentKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    func testDefaultsAreChat100Image40() {
        XCTAssertEqual(BudgetTracker.chatLimit(), 100)
        XCTAssertEqual(BudgetTracker.imageLimit(), 40)
    }

    func testChatPoolExceededDoesNotAffectImagePool() {
        UserDefaults.standard.set(100.0, forKey: chatLimitKey)
        // volc 输入 0.8 元/百万 token：+15M 输入 token ≈ 12 元 → 90+12 ≥ 100
        BudgetTracker.add(promptTokens: 15_000_000, completionTokens: 0, providerId: "volc")
        XCTAssertTrue(BudgetTracker.chatExceeded)
        XCTAssertFalse(BudgetTracker.imageExceeded, "对话超支不应影响生图池")
    }

    func testImagePoolExceededDoesNotAffectChatPool() {
        UserDefaults.standard.set(40.0, forKey: imageLimitKey)
        BudgetTracker.addImageGeneration(10) // 0.1 元/张 × 10 = 1 元 → 39+1 = 40
        XCTAssertTrue(BudgetTracker.imageExceeded)
        XCTAssertFalse(BudgetTracker.chatExceeded)
    }

    func testZeroLimitMeansUnlimited() {
        UserDefaults.standard.set(0.0, forKey: chatLimitKey)
        BudgetTracker.add(promptTokens: 1_000_000_000, completionTokens: 0, providerId: "volc")
        XCTAssertFalse(BudgetTracker.chatExceeded)
    }

    func testDocumentBillingGoesToChatPoolOnly() {
        let beforeChat = BudgetTracker.chatSpent()
        BudgetTracker.addDocument(String(repeating: "字", count: 3_000_000))
        XCTAssertGreaterThan(BudgetTracker.chatSpent(), beforeChat)
        XCTAssertEqual(BudgetTracker.imageSpent(), 39.0, accuracy: 0.001)
    }
}
