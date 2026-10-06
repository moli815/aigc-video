import XCTest

final class WorkbenchUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }
    private func launch(_ mode: String = "workbench", theme: String = "blue") -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["--render-fixture", "--render-mode=" + mode, "--fixture-theme=" + theme]; app.launch()
        return app
    }
    private func evidence(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
        let tree = XCTAttachment(string: app.debugDescription); tree.name = name + "-accessibility"; tree.lifetime = .keepAlways; add(tree)
    }
    func testWorkbenchCardCreatesDraftWithoutSendingAndModesAreSelectable() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch(); let card = app.buttons["task-research"]
        XCTAssertTrue(card.waitForExistence(timeout: 15)); evidence(app, "workbench-portrait")
        card.tap()
        let input = app.textFields["task-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10)); XCTAssertTrue((input.value as? String ?? "").contains("主题："))
        XCTAssertFalse(app.buttons["停止输出"].exists)
        app.buttons["research-mode"].tap(); app.buttons["仅用现有资料"].tap()
        XCTAssertTrue(app.buttons["research-mode"].label.contains("仅用现有资料"))
        app.buttons["answer-style"].tap(); app.buttons["详细分析"].tap()
        XCTAssertTrue(app.buttons["answer-style"].label.contains("详细分析"))
        evidence(app, "task-draft-controls"); app.terminate()
    }
    func testExpertStarterFillsUsefulContextAndTaskButtonsRemainReachable() {
        let app = launch()
        let expert = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'workbench-expert-'")).firstMatch
        XCTAssertTrue(expert.waitForExistence(timeout: 15)); if !expert.isHittable { app.scrollViews["workbench"].swipeUp() }; expert.tap()
        let starter = app.buttons["expert-starter"]
        XCTAssertTrue(starter.waitForExistence(timeout: 10)); if !starter.isHittable { app.scrollViews["chat-scroll"].swipeUp() }; starter.tap()
        let input = app.textFields["task-input"]
        XCTAssertTrue((input.value as? String ?? "").contains("预算")); XCTAssertTrue((input.value as? String ?? "").contains("目标"))
        XCTAssertTrue(app.buttons["research-mode"].isHittable); app.terminate()
    }
    func testGoldWorkbenchSupportsLandscapeAndUsesProductionLayout() {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launch(theme: "gold")
        XCTAssertTrue(app.buttons["task-research"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["task-documents"].isHittable)
        evidence(app, "workbench-gold-landscape"); app.terminate(); XCUIDevice.shared.orientation = .portrait
    }
    func testFullAnswerCanBeCopiedWithoutFoldingOrHidingSources() {
        let app = launch("sources", theme: "graphite")
        let copy = app.buttons["copy-answer"]
        XCTAssertTrue(copy.waitForExistence(timeout: 15)); copy.tap(); XCTAssertEqual(copy.label, "已复制")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "citation-7").firstMatch.exists)
        evidence(app, "answer-copy-graphite"); app.terminate()
    }
}
