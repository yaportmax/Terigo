import XCTest

@MainActor
final class StravaVaultCleanLaunchPerformanceTests: XCTestCase {
    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    func testLaunchPerformance() throws {
        guard ProcessInfo.processInfo.environment["ENABLE_LAUNCH_PERFORMANCE_TESTS"] == "1" else {
            throw XCTSkip("Launch performance measurements are opt-in because simulator automation noise makes them unreliable in the default functional test sweep.")
        }

        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = XCUIApplication()
            app.launchArguments += [
                "--ui-testing",
                "--ui-testing-seed-demo",
                "--ui-testing-disable-animations"
            ]
            app.launch()
            XCTAssertTrue(
                app.otherElements["route-library-screen"].waitForExistence(timeout: 8)
                || app.scrollViews["route-library-screen"].waitForExistence(timeout: 8)
                || app.buttons["route-row-4001"].waitForExistence(timeout: 8)
                || app.buttons["route-library-sort-button"].waitForExistence(timeout: 8)
                || app.buttons["route-library-filters-button"].waitForExistence(timeout: 8)
                || app.buttons["route-library-open-map"].waitForExistence(timeout: 8)
            )
            app.terminate()
        }
    }
}
