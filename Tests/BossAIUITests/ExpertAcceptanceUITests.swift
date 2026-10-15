import XCTest

final class ExpertAcceptanceUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }
    func testModelExpertWorkbenchCalculation() {
        let app = XCUIApplication(); app.launchArguments = ["--acceptance-fixture"]; app.launch()
        let expert = app.buttons["expert-model"]
        XCTAssertTrue(expert.waitForExistence(timeout: 10)); expert.tap()
        let fields = ["单价": "100", "单位变动成本": "60", "期间固定成本": "1000", "销量": "50"]
        for (label, value) in fields {
            let field = app.textFields[label]
            XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(value)
        }
        // 输入完成后收起键盘：Form 的"计算"按钮可能被键盘遮挡，
        // 直接 tap 会点到键盘上导致计算从未执行（CI 上表现为结果行永不出现）
        if app.keyboards.count > 0 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.22)).tap()
        }
        let calcButton = app.buttons["计算"]
        XCTAssertTrue(calcButton.waitForExistence(timeout: 5))
        calcButton.tap()
        // 结果校验：SwiftUI LabeledContent 会组合出「标签, 值」的可访问文本
        // （实测 CI 输出："盈亏平衡销量, 25.00"）；其 accessibilityIdentifier 在元素查询层
        // 不生效（2026-10-15 CI 诊断确认），故按可访问文本断言，不依赖 identifier。
        let resultPredicate = NSPredicate(format: "label CONTAINS '盈亏平衡销量' AND label CONTAINS '25'")
        let result = app.staticTexts.matching(resultPredicate).firstMatch
        if !result.waitForExistence(timeout: 15) {
            // 诊断增强：失败时把当前页面可见文本全部打进日志，便于在 CI 上定位
            // （是表单报错、键盘遮挡，还是结果标识变化，一眼可辨）
            let visible = app.staticTexts.allElementsBoundByIndex.prefix(30).map(\.label).joined(separator: " ｜ ")
            let att = XCTAttachment(string: app.debugDescription); att.lifetime = .keepAlways; add(att)
            XCTFail("未找到盈亏平衡结果行（应为 25.00）。当前可见文本：\(visible.prefix(800))")
        }
        app.terminate()
    }
    func testLandscapeExpertNavigation() {
        let app = XCUIApplication(); app.launchArguments = ["--acceptance-fixture"]; app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.navigationBars["离线功能验收"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.lifetime = .keepAlways; add(screenshot)
        XCUIDevice.shared.orientation = .portrait; app.terminate()
    }
}
