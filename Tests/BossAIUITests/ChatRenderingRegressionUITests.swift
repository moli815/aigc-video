import XCTest

final class ChatRenderingRegressionUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }
    private func launch(_ mode: String) -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["--render-fixture", "--render-mode=" + mode]
        app.launch()
        XCTAssertTrue(app.scrollViews["chat-scroll"].waitForExistence(timeout: 15))
        return app
    }
    private func evidence(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        let tree = XCTAttachment(string: app.debugDescription); tree.name = name + "-accessibility"; tree.lifetime = .keepAlways; add(tree)
    }
    func testWrappedTableRowsDoNotOverlapAndLastColumnCanBeReached() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch("table")
        let first = app.staticTexts["table-0-cell-1-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        let second = app.staticTexts["table-0-cell-2-1"]
        XCTAssertTrue(second.exists)
        XCTAssertGreaterThan(first.frame.height, 40, "长标题必须实际换行")
        XCTAssertGreaterThanOrEqual(second.frame.minY, first.frame.maxY, "换行不得覆盖下一行")
        let table = app.scrollViews["table-0-scroll"]
        XCTAssertLessThanOrEqual(table.frame.maxX, app.frame.maxX + 1)
        table.swipeLeft()
        let last = app.staticTexts["table-0-cell-1-4"]
        XCTAssertTrue(last.isHittable, "右侧列可通过横向滑动到达")
        XCTAssertFalse(app.buttons["回到最新"].exists, "横向查看表格不应禁用跟随输出")
        evidence(app, name: "production-table-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = NSPredicate { _, _ in app.frame.width > app.frame.height }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: landscape, object: app)], timeout: 10), .completed)
        XCTAssertGreaterThanOrEqual(second.frame.minY, first.frame.maxY)
        evidence(app, name: "production-table-landscape")
        app.terminate(); XCUIDevice.shared.orientation = .portrait
    }
    func testAnswersStartExpandedAndOnlyUserCanCollapseThem() {
        let app = launch("long")
        let end = app.staticTexts["完整答案末尾标记"]
        XCTAssertTrue(end.waitForExistence(timeout: 10), "末尾默认存在，无需先点击展开")
        let collapse = app.buttons["answer-collapse"]
        XCTAssertTrue(collapse.exists); XCTAssertEqual(collapse.label, "收起回答")
        collapse.tap()
        XCTAssertFalse(end.exists)
        XCTAssertEqual(app.buttons["answer-collapse"].label, "展开完整回答")
        app.buttons["answer-collapse"].tap()
        XCTAssertTrue(end.waitForExistence(timeout: 5))
        app.terminate()
    }
    func testAllSixtyTableRowsRemainInAnswer() {
        let app = launch("rows")
        let last = app.staticTexts["table-0-cell-60-1"]
        XCTAssertTrue(last.waitForExistence(timeout: 10)); XCTAssertEqual(last.label, "第60行完整数据")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS '展开全部'")).firstMatch.exists)
        evidence(app, name: "production-table-all-rows")
        app.terminate()
    }
    func testOnlyReferencedSourceHasTitleAndAllSearchRecordsRemainAccessible() {
        let app = launch("sources")
        let actual = app.descendants(matching: .any).matching(identifier: "citation-7").firstMatch
        XCTAssertTrue(actual.waitForExistence(timeout: 10)); XCTAssertTrue(actual.label.contains("测试来源标题7"))
        XCTAssertFalse(app.links["citation-1"].exists); XCTAssertFalse(app.buttons["citation-1"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '发布时间未核实'")).firstMatch.exists)
        evidence(app, name: "production-citation-title")
        app.buttons["search-records"].tap()
        XCTAssertTrue(app.navigationBars["本轮检索记录"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.links["citation-1"].exists || app.buttons["citation-1"].exists)
        app.terminate()
    }
}
