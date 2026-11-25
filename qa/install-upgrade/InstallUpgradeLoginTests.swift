import XCTest

final class InstallUpgradeLoginTests: XCTestCase {
    func testNormalLaunchOpensMemberLogin() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["hosted-login"].waitForExistence(timeout: 20))
    }
}
