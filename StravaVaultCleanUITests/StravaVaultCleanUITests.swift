import XCTest

/// Exercise the redesigned app through public controls, with synthetic data only.
@MainActor
final class StravaVaultCleanUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testVisualTourLight() throws { try visualTour(appearance: "light") }
    func testVisualTourDark() throws { try visualTour(appearance: "dark") }

    func testLibraryOpenFailureCanRetry() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-seed-demo", "--ui-test-storage-failure"]
        app.launch()
        XCTAssertTrue(app.buttons["library-retry-open"].waitForExistence(timeout: 10))
        capture("library-storage-recovery", app)
        tap(app.buttons["library-retry-open"])
        XCTAssertTrue(app.buttons["route-row-4001"].waitForExistence(timeout: 15))
    }

    func testSearchAndNavigationPreserveLibrary() throws {
        let app = launch()
        let search = app.textFields["route-library-search"]
        tap(search)
        search.typeText("Presidio")
        XCTAssertTrue(app.buttons["route-row-4002"].waitForExistence(timeout: 8))
        XCTAssertTrue(waitUntil { !app.buttons["route-row-4001"].exists })
        capture("search-filtered", app)
        tap(app.buttons["Clear search"])
        app.swipeDown()
        tapTab("Activities", app)
        tapTab("Routes", app)
        XCTAssertTrue(app.buttons["route-row-4001"].waitForExistence(timeout: 8))
        tap(search)
        search.typeText("NoSuchRouteAnywhere")
        XCTAssertTrue(app.staticTexts["No matching routes"].waitForExistence(timeout: 8))
        capture("search-empty", app)
    }

    func testCreateListAndCancelDeletion() throws {
        let app = launch()
        tapTab("Lists", app)
        tap(app.buttons["lists-create"])
        let input = app.alerts.textFields.firstMatch
        tap(input)
        input.typeText("Autumn Adventures")
        tap(app.alerts.buttons["Create"])
        XCTAssertTrue(app.buttons["route-list-row-autumn-adventures"].waitForExistence(timeout: 8))
        capture("list-created", app)
        app.buttons["route-list-row-autumn-adventures"].swipeLeft()
        tap(app.buttons["Delete"])
        capture("list-delete-confirmation", app)
        tap(app.buttons["Cancel"])
        tap(app.buttons["route-list-row-autumn-adventures"])
        XCTAssertTrue(app.staticTexts["Autumn Adventures"].waitForExistence(timeout: 8))
        capture("list-empty-detail", app)
        tapTab("Routes", app)
        XCTAssertTrue(app.buttons["route-row-4001"].waitForExistence(timeout: 8))
    }

    func testTrackingAndMapTools() throws {
        let app = launch()
        addUIInterruptionMonitor(withDescription: "Location permission") { alert in
            let allow = alert.buttons["Allow While Using App"]
            if allow.exists { allow.tap(); return true }
            return false
        }
        openRoute(app)
        tap(app.buttons["route-editor-start-activity"])
        app.tap()
        XCTAssertTrue(app.buttons["route-tracking-close"].waitForExistence(timeout: 12))
        capture("tracking-live", app)
        tap(app.buttons["route-tracking-battery-saver"])
        capture("tracking-continuous-gps", app)
        if app.buttons["route-tracking-continuous-gps-not-now"].exists {
            tap(app.buttons["route-tracking-continuous-gps-not-now"])
        }
        tap(app.buttons["route-tracking-close"])
        if app.buttons["route-tracking-confirm-end"].waitForExistence(timeout: 3) {
            capture("tracking-end-confirmation", app)
            tap(app.buttons["route-tracking-confirm-end"])
        }
        XCTAssertTrue(app.buttons["route-row-4001"].waitForExistence(timeout: 12))
        tapTab("Explore", app)
        tap(app.buttons["Open map full screen"])
        capture("explore-fullscreen", app)
        tap(app.buttons["Close"])
        tap(app.buttons["Search for a place"])
        capture("explore-place-search", app)
    }

    func testRouteMapSharingAndListDeletion() throws {
        let app = launch()
        openRoute(app)
        tap(app.buttons["Open full screen map"])
        capture("route-fullscreen-map", app)
        tap(app.buttons["Recenter route"])
        tap(app.buttons["Close full screen map"])
        tap(app.buttons["Done"])
        tapTab("Lists", app)
        tap(app.buttons["route-list-row-training-block"])
        tap(app.buttons["route-list-settings-button"])
        tap(app.buttons["Sharing & Collaboration"])
        capture("list-sharing", app)
        app.swipeUp()
        capture("list-collaboration", app)
        tap(app.buttons["Close"])
        tap(app.buttons["route-list-settings-button"])
        tap(app.buttons["Delete List"])
        tap(app.alerts.buttons["Delete List"])
        XCTAssertTrue(app.buttons["route-list-row-weekend-hits"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["route-list-row-training-block"].exists)
        tapTab("Routes", app)
        XCTAssertTrue(app.buttons["route-row-4002"].waitForExistence(timeout: 8))
        openRoute(app)
        capture("route-preserved-after-list-deletion", app)
    }

    func testOfflineGPXDownload() throws {
        let app = launch()
        openRoute(app)
        tap(app.buttons["route-editor-open-offline-download"])
        capture("offline-options", app)
        tap(app.buttons["route-offline-download-confirm"])
        XCTAssertTrue(waitUntil(timeout: 35) { !app.buttons["route-offline-download-confirm"].exists })
        tap(app.buttons["Done"])
        openSettings(app)
        tap(app.buttons["route-library-open-offline-center"])
        XCTAssertTrue(app.buttons["offline-center-remove-saved"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["offline-center-remove-saved"].isEnabled)
        capture("offline-saved", app)
    }

    func testRouteDeletedFromListCanBeRestoredForSync() throws {
        let app = launch()
        tapTab("Lists", app)
        tap(app.buttons["route-list-row-weekend-hits"])
        openRoute(app)
        let delete = app.buttons["Delete Route"]
        for _ in 0..<8 {
            if delete.isHittable { break }
            app.swipeUp()
        }
        tap(delete)
        capture("route-delete-confirmation", app)
        tap(app.alerts.buttons["Delete Route"])
        XCTAssertTrue(waitUntil { !app.buttons["route-editor-start-activity"].exists })
        tapTab("Routes", app)
        XCTAssertFalse(app.buttons["route-row-4001"].exists)
        openSettings(app)
        tap(app.buttons["route-library-open-deleted-routes"])
        XCTAssertTrue(app.buttons["Undelete"].waitForExistence(timeout: 8))
        capture("deleted-route-recovery", app)
        tap(app.buttons["Undelete"])
        XCTAssertTrue(app.staticTexts["No Deleted Routes"].waitForExistence(timeout: 8))
    }

    func testWelcomeAndLocalLibrary() throws {
        let app = launch(seed: false)
        XCTAssertTrue(app.buttons["welcome-continue-local"].waitForExistence(timeout: 8))
        capture("welcome", app)
        tap(app.buttons["welcome-continue-local"])
        XCTAssertTrue(app.buttons["route-library-import-gpx"].waitForExistence(timeout: 8))
        capture("local-empty-library", app)
        tapTab("Activities", app)
        tap(app.buttons["activities-settings-button"])
        XCTAssertTrue(app.buttons["Import GPX Activity"].waitForExistence(timeout: 8))
        capture("local-activity-import", app)
    }

    func testLargeTextAndLandscape() throws {
        let app = launch(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        capture("accessibility-library", app)
        openRoute(app)
        XCTAssertTrue(app.buttons["route-editor-start-activity"].isHittable)
        capture("accessibility-detail", app)
        tap(app.buttons["Done"])
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitUntil { app.frame.width > app.frame.height })
        capture("landscape-library", app)
        tapTab("Explore", app)
        capture("landscape-explore", app)
        XCUIDevice.shared.orientation = .portrait
        tapTab("Activities", app)
        capture("accessibility-activities", app)
    }

    private func visualTour(appearance: String) throws {
        let app = launch(appearance: appearance)
        capture("\(appearance)-01-routes", app)
        tap(app.buttons["route-library-sort-button"])
        capture("\(appearance)-02-sort", app)
        tap(app.buttons["Close"])
        tap(app.buttons["route-library-filters-button"])
        capture("\(appearance)-03-filters", app)
        app.swipeUp()
        capture("\(appearance)-04-filter-areas-lists", app)
        tap(app.buttons["Close"])
        openRoute(app)
        capture("\(appearance)-05-route-overview", app)
        app.swipeUp()
        capture("\(appearance)-06-route-weather", app)
        app.swipeUp()
        capture("\(appearance)-07-route-organization", app)
        app.swipeUp()
        capture("\(appearance)-08-route-tools", app)
        tap(app.buttons["Done"])
        tapTab("Explore", app)
        XCTAssertTrue(app.buttons["map-browse-filters-button"].waitForExistence(timeout: 8))
        capture("\(appearance)-09-explore", app)
        tapTab("Lists", app)
        capture("\(appearance)-10-lists", app)
        tap(app.buttons["route-list-row-weekend-hits"])
        capture("\(appearance)-11-list-detail", app)
        tapTab("Activities", app)
        capture("\(appearance)-12-activities", app)
        tap(app.buttons["activities-sort-button"])
        capture("\(appearance)-13-activity-sort", app)
        tap(app.buttons["Close"])
        tap(app.buttons["activities-filters-button"])
        capture("\(appearance)-14-activity-filters", app)
        tap(app.buttons["Close"])
        tap(app.buttons["activity-row-ui-activity-headlands-tempo"])
        XCTAssertTrue(app.otherElements["activity-detail-screen-ui-activity-headlands-tempo"].waitForExistence(timeout: 8)
                      || app.scrollViews["activity-detail-screen-ui-activity-headlands-tempo"].exists)
        capture("\(appearance)-15-activity-detail", app)
        app.swipeUp()
        capture("\(appearance)-16-activity-analysis", app)
        app.swipeUp()
        capture("\(appearance)-17-activity-terrain", app)
        tapTab("Routes", app)
        openSettings(app)
        capture("\(appearance)-18-settings", app)
        tap(app.buttons["route-library-open-offline-center"])
        capture("\(appearance)-19-offline", app)
        tap(app.buttons["Close"])
        openSettings(app)
        tap(app.buttons["route-library-open-export-data"])
        capture("\(appearance)-20-export", app)
        tap(app.buttons["Done"])
        openSettings(app)
        tap(app.buttons["Manage Account"])
        capture("\(appearance)-21-account", app)
        tap(app.buttons["Done"])
        openSettings(app)
        tap(app.buttons["route-library-send-feedback"])
        capture("\(appearance)-22-feedback", app)
    }

    private func launch(appearance: String = "light", seed: Bool = true, extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-disable-animations", "--ui-appearance=\(appearance)"] + extra
        if seed { app.launchArguments.append("--ui-testing-seed-demo") }
        app.launch()
        if seed { XCTAssertTrue(app.buttons["route-library-import-gpx"].waitForExistence(timeout: 15)) }
        return app
    }
    private func openRoute(_ app: XCUIApplication) {
        let route = app.buttons["route-row-4001"]
        for _ in 0..<10 {
            if route.exists && route.isHittable { break }
            app.swipeUp()
        }
        tap(route)
        let opened = app.buttons["route-editor-start-activity"].waitForExistence(timeout: 10)
        if !opened { capture("failure-opening-route", app) }
        XCTAssertTrue(opened)
    }
    private func openSettings(_ app: XCUIApplication) { tap(app.buttons["route-library-settings-button"]) }
    private func tapTab(_ title: String, _ app: XCUIApplication) { tap(app.tabBars.buttons[title]) }
    private func tap(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let exists = element.waitForExistence(timeout: 10)
        if !exists { capture("failure-missing-control", XCUIApplication()) }
        XCTAssertTrue(exists, file: file, line: line)
        element.tap()
    }
    private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func waitUntil(timeout: TimeInterval = 8, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return condition()
    }
}
