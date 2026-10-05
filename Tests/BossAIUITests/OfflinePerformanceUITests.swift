import XCTest

final class OfflinePerformanceUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }
    func testOfflineLaunchPerformance() {
        let app = XCUIApplication()
        app.launchArguments = ["--performance-fixture", "--fixture-count=200"]
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTApplicationLaunchMetric()], options: options) {
            app.launch()
            app.terminate()
        }
    }
    func testOfflineScrollClockAndMemory() {
        let app = XCUIApplication()
        app.launchArguments = ["--performance-fixture", "--fixture-count=200"]
        app.launch()
        XCTAssertTrue(app.scrollViews["fixture-scroll"].waitForExistence(timeout: 10))
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric(application: app)], options: options) {
            app.scrollViews["fixture-scroll"].swipeUp()
            app.scrollViews["fixture-scroll"].swipeUp()
            app.scrollViews["fixture-scroll"].swipeDown()
        }
        app.terminate()
    }
}
