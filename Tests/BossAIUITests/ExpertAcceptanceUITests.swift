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
        app.buttons["计算"].tap()
        XCTAssertTrue(app.staticTexts["盈亏平衡销量"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["25.00"].exists)
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
