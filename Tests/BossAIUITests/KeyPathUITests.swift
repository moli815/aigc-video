import XCTest

/// P0 关键路径 UI 自动化（离线 fixture 驱动：确定性、零 API 消耗，可进 CI）。
/// 重点守护两个曾反复出问题的路径：①键盘弹出/收起后布局不崩 ②来源列表可折叠。
final class KeyPathUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--render-fixture"]
        app.launch()
        return app
    }

    /// 1) 对话滚动区正常渲染
    func testChatScrollRenders() throws {
        let app = launchFixture()
        XCTAssertTrue(app.scrollViews["chat-scroll"].waitForExistence(timeout: 15), "对话滚动区未渲染")
    }

    /// 2) 键盘关键路径（历史 bug 回归守护）：
    ///    聚焦输入 → 键入 → 键盘弹出后，滚动区与输入框都必须仍然存在（此前的"顶空/消失"症状）
    func testKeyboardKeepsLayoutAlive() throws {
        let app = launchFixture()
        let field = app.textFields["task-input"].exists
            ? app.textFields["task-input"]
            : app.textViews["task-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 15), "输入框不存在")
        field.tap()
        field.typeText("键盘回归")
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 8), "键盘未弹出")
        XCTAssertTrue(app.scrollViews["chat-scroll"].exists, "键盘弹出后滚动区消失（历史空白 bug 回归）")
        XCTAssertTrue(field.exists, "键盘弹出后输入框消失")
        XCTAssertTrue(app.buttons["send-button"].exists, "键盘弹出后发送按钮消失")
    }

    /// 3) 发送按钮与输入框可用（基础可交互性）
    func testComposerControlsExist() throws {
        let app = launchFixture()
        XCTAssertTrue(app.buttons["send-button"].waitForExistence(timeout: 15), "发送按钮不存在")
        XCTAssertTrue(app.textFields["task-input"].exists || app.textViews["task-input"].exists, "输入控件不存在")
    }

    /// 4) 来源列表：若有引用来源，则最多默认展示 5 条 + 折叠控件（数量多时）
    func testSourceListCollapsedByDefault() throws {
        let app = launchFixture()
        let citations = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'citation-'"))
        guard citations.firstMatch.waitForExistence(timeout: 12) else {
            // fixture 未包含引用来源时不判失败（该渲染路径由单元测试覆盖）
            return
        }
        let count = citations.count
        XCTAssertTrue(count <= 5 || app.buttons["toggle-sources"].exists,
                      "来源超过 5 条时应出现折叠按钮（当前 \(count) 条）")
    }
}
