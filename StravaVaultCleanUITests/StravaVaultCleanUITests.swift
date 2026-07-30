import XCTest

@MainActor
final class StravaVaultCleanUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testRouteLibraryCoreFlows() throws {
        let app = launchSeededApp()

        waitForLibraryReady(in: app)

        app.buttons["route-library-sort-button"].waitAndTap()
        XCTAssertTrue(firstExistingElement([
            app.scrollViews["route-sort-screen"],
            app.otherElements["route-sort-screen"],
            app.buttons["Close"]
        ]).exists)
        app.buttons["Close"].waitAndTap()

        app.buttons["route-library-filters-button"].waitAndTap()
        XCTAssertTrue(firstExistingElement([
            app.scrollViews["route-filters-screen"],
            app.otherElements["route-filters-screen"],
            app.buttons["Close"]
        ]).exists)
        app.buttons["Close"].waitAndTap()

        tapElement(firstExistingElement([
            app.buttons["route-row-4001"],
            app.staticTexts["Morning Marin Headlands 🌉"]
        ]))

        XCTAssertTrue(firstExistingElement([
            app.buttons["Done"],
            app.staticTexts["Morning Marin Headlands 🌉"]
        ]).exists)
        app.buttons["Done"].waitAndTap()
        waitForLibraryReady(in: app)
    }

    func testMapBrowseOpensAndCloses() throws {
        let app = launchSeededApp()

        app.buttons["route-library-open-map"].waitAndTap()
        XCTAssertTrue(firstExistingElement([
            app.otherElements["map-browse-screen"],
            app.scrollViews["map-browse-screen"],
            app.staticTexts["Map"]
        ], timeout: 8).exists)
        navigateBackToRouteLibrary(in: app)
        waitForLibraryReady(in: app)
    }

    func testManageListsFlow() throws {
        let app = launchSeededApp()

        waitForLibraryReady(in: app)
        app.buttons["route-library-open-lists"].waitAndTap()

        XCTAssertTrue(firstExistingElement([
            app.buttons["route-list-row-weekend-hits"],
            app.buttons["route-list-row-training-block"],
            app.buttons["Add"]
        ]).exists)

        tapElement(firstExistingElement([
            app.buttons["route-list-row-weekend-hits"],
            app.staticTexts["Weekend Hits"]
        ]))

        XCTAssertTrue(firstExistingElement([
            app.otherElements["route-list-detail-screen-weekend-hits"],
            app.staticTexts["Weekend Hits"]
        ]).exists)

        tapElement(firstExistingElement([
            app.buttons["route-row-4001"],
            app.staticTexts["Morning Marin Headlands 🌉"]
        ]))

        XCTAssertTrue(firstExistingElement([
            app.otherElements["route-editor-screen-4001"],
            app.staticTexts["Morning Marin Headlands 🌉"],
            app.buttons["Done"]
        ], timeout: 8).exists)
    }

    func testDeletedRoutesScreenOpens() throws {
        let app = launchSeededApp()

        openSettingsMenu(in: app)
        tapMenuItem(
            in: app,
            identifiers: ["route-library-open-deleted-routes"],
            labels: ["Deleted Routes"]
        )

        XCTAssertTrue(firstExistingElement([
            app.staticTexts["Deleted Routes"],
            app.buttons["Close"]
        ]).exists)
    }

    func testOfflineCenterAndExportScreensOpen() throws {
        let app = launchSeededApp()

        openSettingsMenu(in: app)
        tapMenuItem(
            in: app,
            identifiers: ["route-library-open-offline-center"],
            labels: ["Offline"]
        )
        XCTAssertTrue(firstExistingElement([
            app.staticTexts["Offline Center"],
            app.buttons["Close"]
        ]).exists)
        app.buttons["Close"].waitAndTap()

        openSettingsMenu(in: app)
        tapMenuItem(
            in: app,
            identifiers: ["route-library-open-export-data"],
            labels: ["Export Data"]
        )
        XCTAssertTrue(firstExistingElement([
            app.staticTexts["Export Data"],
            app.buttons["Export"]
        ]).exists)
    }

    func testRouteEditorOfflineDownloadAndRemoveFlow() throws {
        let app = launchSeededApp()

        openRouteEditor(in: app, routeID: 4001, routeName: "Morning Marin Headlands 🌉")

        revealRouteEditorAction(in: app, routeID: 4001, identifier: "route-editor-open-offline-download")
        app.buttons["route-editor-open-offline-download"].waitAndTap(timeout: 8)
        XCTAssertTrue(firstExistingElement([
            app.otherElements["route-offline-download-screen-4001"],
            app.navigationBars["Offline Download"],
            app.buttons["route-offline-download-confirm"]
        ], timeout: 8).exists)

        app.buttons["route-offline-download-confirm"].waitAndTap(timeout: 8)
        waitForRouteEditorOfflineDownloadCompletion(in: app, routeID: 4001)

        app.buttons["route-editor-remove-offline-download"].waitAndTap(timeout: 8)
        revealRouteEditorAction(in: app, routeID: 4001, identifier: "route-editor-open-offline-download")
        XCTAssertFalse(app.buttons["route-editor-remove-offline-download"].exists)
        XCTAssertFalse(app.buttons["route-editor-share-saved-gpx"].exists)
    }

    func testRouteLibrarySwipeOfflineDownloadFlow() throws {
        let app = launchSeededApp()

        waitForLibraryReady(in: app)
        revealRouteLibrarySwipeDownload(in: app, routeID: 4001)
        tapElement(firstExistingElement([
            app.buttons["route-library-swipe-download-4001"],
            matchingButton(in: app, label: "Download")
        ], timeout: 8))

        openOfflineCenter(in: app)
        XCTAssertTrue(matchingStaticText(in: app, label: "Routes With Offline Files, 1").waitForExistence(timeout: 40))
        XCTAssertTrue(app.buttons["offline-center-download-missing"].isEnabled)
        XCTAssertTrue(app.buttons["offline-center-remove-saved"].isEnabled)
    }

    func testOfflineCenterBatchDownloadAndRemoveFlow() throws {
        let app = launchSeededApp()

        openOfflineCenter(in: app)
        app.buttons["offline-center-download-missing"].waitAndTap(timeout: 8)

        XCTAssertTrue(matchingStaticText(in: app, label: "Routes With Offline Files, 3").waitForExistence(timeout: 60))
        XCTAssertFalse(app.buttons["offline-center-download-missing"].isEnabled)
        XCTAssertTrue(app.buttons["offline-center-remove-saved"].isEnabled)

        app.buttons["offline-center-remove-saved"].waitAndTap(timeout: 8)
        XCTAssertTrue(matchingStaticText(in: app, label: "Routes With Offline Files, 0").waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["offline-center-download-missing"].exists)
        XCTAssertTrue(app.buttons["offline-center-download-missing"].isEnabled)
    }

    func testListFullOfflineDownloadFlow() throws {
        let app = launchSeededApp()

        downloadGPXOnlyRoute(in: app, routeID: 4001, routeName: "Morning Marin Headlands 🌉")
        downloadGPXOnlyRoute(in: app, routeID: 4002, routeName: "Presidio Tempo Loop")

        waitForLibraryReady(in: app)
        app.buttons["route-library-open-lists"].waitAndTap()
        firstExistingElement([
            app.buttons["route-list-row-weekend-hits"],
            app.staticTexts["Weekend Hits"]
        ], timeout: 8).tap()

        XCTAssertTrue(firstExistingElement([
            app.otherElements["route-list-detail-screen-weekend-hits"],
            app.staticTexts["Weekend Hits"]
        ], timeout: 8).exists)

        tapElement(firstExistingElement([
            app.buttons["route-list-settings-button"],
            matchingButton(in: app, label: "List settings"),
            app.otherElements["route-list-settings-button"],
            matchingOtherElement(in: app, label: "List settings"),
            app.navigationBars.buttons.element(boundBy: 1),
            app.navigationBars.buttons.element(boundBy: 0)
        ], timeout: 8))
        tapElement(firstExistingElement([
            app.buttons["route-list-download-full-offline"],
            matchingButton(in: app, label: "Refresh Full List Offline Files"),
            matchingButton(in: app, label: "Download Full List Offline Files")
        ], timeout: 8))

        XCTAssertTrue(
            matchingStaticText(in: app, label: "Saved offline files for 2 routes in this list.").waitForExistence(timeout: 25)
        )
    }

    func testRouteTrackingStartAndEndFlow() throws {
        let app = launchSeededApp()

        openRouteEditor(in: app, routeID: 4001, routeName: "Morning Marin Headlands 🌉")
        revealRouteEditorAction(in: app, routeID: 4001, identifier: "route-editor-start-activity")
        app.buttons["route-editor-start-activity"].waitAndTap(timeout: 8)

        XCTAssertTrue(firstExistingElement([
            app.otherElements["route-tracking-screen-4001"],
            app.buttons["route-tracking-close"]
        ], timeout: 12).exists)

        tapTrackingBatterySaver(in: app)
        dismissTrackingContinuousGPSPromptIfPresent(in: app)

        tapTrackingClose(in: app)
        if app.buttons["route-tracking-confirm-end"].waitForExistence(timeout: 5) {
            app.buttons["route-tracking-confirm-end"].tap()
        }

        XCTAssertTrue(firstExistingElement([
            app.otherElements["route-editor-screen-4001"],
            app.buttons["route-library-sort-button"]
        ], timeout: 12).exists)
    }

    func testActivitiesListAndActivityDetailFlow() throws {
        let app = launchSeededApp()

        openActivitiesScreen(in: app)

        XCTAssertTrue(firstExistingElement([
            app.buttons["activities-settings-button"],
            app.buttons["activity-row-ui-activity-headlands-tempo"],
            app.staticTexts["Sunrise Headlands Tempo 🌁"],
            app.navigationBars["Activities"]
        ], timeout: 8).exists)

        tapElement(firstExistingElement([
            app.buttons["activity-row-ui-activity-headlands-tempo"],
            app.staticTexts["Sunrise Headlands Tempo 🌁"]
        ]))

        XCTAssertTrue(firstExistingElement([
            app.otherElements["activity-detail-screen-ui-activity-headlands-tempo"],
            app.staticTexts["Sunrise Headlands Tempo 🌁"],
            app.navigationBars["Sunrise Headlands Tempo 🌁"]
        ], timeout: 8).exists)
    }

    func testActivitiesSortAndFiltersFlow() throws {
        let app = launchSeededApp()

        openActivitiesScreen(in: app)

        XCTAssertTrue(firstExistingElement([
            app.buttons["activities-sort-button"],
            app.buttons["activities-filters-button"]
        ], timeout: 8).exists)

        app.buttons["activities-sort-button"].waitAndTap()
        XCTAssertTrue(firstExistingElement([
            app.scrollViews["activities-sort-screen"],
            app.otherElements["activities-sort-screen"],
            app.buttons["Reset"]
        ], timeout: 8).exists)
        app.buttons["Close"].waitAndTap()

        app.buttons["activities-filters-button"].waitAndTap()
        XCTAssertTrue(firstExistingElement([
            app.scrollViews["activities-filters-screen"],
            app.otherElements["activities-filters-screen"],
            app.staticTexts["Source"]
        ], timeout: 8).exists)

        tapElement(firstExistingElement([
            app.buttons["Run"],
            app.staticTexts["Run"]
        ]))

        XCTAssertTrue(firstExistingElement([
            app.staticTexts["Distance"],
            app.staticTexts["Privacy"]
        ], timeout: 8).exists)
        app.buttons["Close"].waitAndTap()
    }

    func testActivitiesSettingsMenuShowsCoreActions() throws {
        let app = launchSeededApp()
        openActivitiesScreen(in: app)
        app.buttons["activities-settings-button"].waitAndTap(timeout: 8)

        XCTAssertTrue(firstExistingElement([
            app.staticTexts["Activity View"],
            app.buttons["Import GPX Activity"]
        ], timeout: 8).exists)
        XCTAssertTrue(firstExistingElement([
            app.buttons["Sync Activities"],
            app.buttons["Disconnect"],
            app.buttons["Reconnect Strava"]
        ], timeout: 8).exists)
    }

    private func launchSeededApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-testing",
            "--ui-testing-seed-demo",
            "--ui-testing-disable-animations"
        ]
        app.launch()
        return app
    }

    private func openActivitiesScreen(in app: XCUIApplication) {
        openSettingsMenu(in: app)
        tapMenuItem(
            in: app,
            identifiers: ["route-library-open-activities"],
            labels: ["Activities"]
        )

        XCTAssertTrue(firstExistingElement([
            app.buttons["activities-settings-button"],
            app.buttons["activities-sort-button"],
            app.buttons["activities-filters-button"],
            app.buttons["activity-row-ui-activity-headlands-tempo"],
            app.navigationBars["Activities"]
        ], timeout: 8).exists)
    }

    private func openRouteEditor(in app: XCUIApplication, routeID: Int, routeName: String) {
        waitForLibraryReady(in: app)
        tapElement(firstExistingElement([
            app.buttons["route-row-\(routeID)"],
            app.staticTexts[routeName]
        ], timeout: 8))

        XCTAssertTrue(firstExistingElement([
            app.otherElements["route-editor-screen-\(routeID)"],
            app.buttons["route-editor-start-activity"],
            app.buttons["route-editor-open-offline-download"],
            app.buttons["Done"],
            app.navigationBars[routeName]
        ], timeout: 8).exists)
    }

    private func openOfflineCenter(in app: XCUIApplication) {
        openSettingsMenu(in: app)
        tapMenuItem(
            in: app,
            identifiers: ["route-library-open-offline-center"],
            labels: ["Offline"]
        )
        XCTAssertTrue(firstExistingElement([
            app.otherElements["offline-center-screen"],
            app.staticTexts["Offline Center"],
            app.buttons["Close"]
        ], timeout: 8).exists)
    }

    private func downloadGPXOnlyRoute(in app: XCUIApplication, routeID: Int, routeName: String) {
        openRouteEditor(in: app, routeID: routeID, routeName: routeName)

        if !app.buttons["route-editor-share-saved-gpx"].exists {
            revealRouteEditorAction(in: app, routeID: routeID, identifier: "route-editor-open-offline-download")
            app.buttons["route-editor-open-offline-download"].waitAndTap(timeout: 8)
            XCTAssertTrue(firstExistingElement([
                app.otherElements["route-offline-download-screen-\(routeID)"],
                app.navigationBars["Offline Download"],
                app.buttons["route-offline-download-confirm"]
            ], timeout: 8).exists)
            app.buttons["route-offline-download-confirm"].waitAndTap(timeout: 8)
            waitForRouteEditorOfflineDownloadCompletion(in: app, routeID: routeID)
        }

        app.buttons["Done"].waitAndTap(timeout: 8)
        waitForLibraryReady(in: app)
    }

    private func waitForRouteEditorOfflineDownloadCompletion(in app: XCUIApplication, routeID: Int) {
        XCTAssertTrue(
            waitForRouteEditorAction(in: app, identifier: "route-editor-remove-offline-download", timeout: 60),
            "Timed out waiting for the saved offline controls to appear for route \(routeID)."
        )
        XCTAssertTrue(
            waitForRouteEditorAction(in: app, identifier: "route-editor-share-saved-gpx", timeout: 10),
            "Timed out waiting for the saved GPX share action to appear for route \(routeID)."
        )
    }

    private func revealRouteEditorAction(in app: XCUIApplication, routeID: Int, identifier: String) {
        let button = app.buttons[identifier]

        for _ in 0..<5 where !button.exists {
            swipeUpInsideBottomSheet(in: app)
        }
        XCTAssertTrue(button.waitForExistence(timeout: 5))
    }

    private func waitForRouteEditorAction(
        in app: XCUIApplication,
        identifier: String,
        timeout: TimeInterval
    ) -> Bool {
        let button = app.buttons[identifier]
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            if button.exists {
                return true
            }

            swipeUpInsideBottomSheet(in: app)
            RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        } while Date() < deadline

        return button.exists
    }

    private func revealRouteLibrarySwipeDownload(in app: XCUIApplication, routeID: Int) {
        let routeRow = firstExistingElement([
            app.buttons["route-row-\(routeID)"],
            app.staticTexts["Morning Marin Headlands 🌉"]
        ], timeout: 8)

        let swipeActionButton = app.buttons["route-library-swipe-download-\(routeID)"]
        let labeledDownloadButton = matchingButton(in: app, label: "Download")

        for _ in 0..<4 where !swipeActionButton.exists && !labeledDownloadButton.exists {
            let start = routeRow.coordinate(withNormalizedOffset: CGVector(dx: 0.14, dy: 0.5))
            let end = routeRow.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
            start.press(forDuration: 0.02, thenDragTo: end)
            RunLoop.current.run(until: Date().addingTimeInterval(0.35))

            if app.buttons["Done"].exists {
                app.buttons["Done"].tap()
                waitForLibraryReady(in: app)
            }
        }
    }

    private func swipeUpInsideBottomSheet(in app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.58))
        start.press(forDuration: 0.01, thenDragTo: end)
    }

    private func tapTrackingBatterySaver(in app: XCUIApplication) {
        let button = app.buttons["route-tracking-battery-saver"]
        if button.waitForExistence(timeout: 3) {
            button.tap()
            return
        }

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.79, dy: 0.91)).tap()
    }

    private func dismissTrackingContinuousGPSPromptIfPresent(in app: XCUIApplication) {
        let dismissButtons = [
            "route-tracking-continuous-gps-not-now",
            "route-tracking-continuous-gps-keep",
            "route-tracking-battery-saver-not-now"
        ]

        for identifier in dismissButtons {
            let button = app.buttons[identifier]
            if button.waitForExistence(timeout: 2) {
                button.tap()
                return
            }
        }
    }

    private func tapTrackingClose(in app: XCUIApplication) {
        let button = app.buttons["route-tracking-close"]
        if button.waitForExistence(timeout: 3) {
            button.tap()
            return
        }

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.08)).tap()
    }

    private func navigateBackToRouteLibrary(in app: XCUIApplication) {
        tapElement(firstExistingElement([
            app.buttons["Terigo"],
            app.navigationBars.buttons.element(boundBy: 0)
        ], timeout: 8))
    }

    private func openSettingsMenu(in app: XCUIApplication) {
        tapElement(firstExistingElement([
            app.buttons["route-library-settings-button"],
            app.buttons["Route library settings"]
        ]))
    }

    private func waitForLibraryReady(in app: XCUIApplication, timeout: TimeInterval = 8) {
        XCTAssertTrue(firstExistingElement([
            app.buttons["route-library-sort-button"],
            app.buttons["route-library-filters-button"],
            app.buttons["route-library-open-map"]
        ], timeout: timeout).exists)
    }

    private func tapMenuItem(
        in app: XCUIApplication,
        identifiers: [String],
        labels: [String]
    ) {
        var candidates = identifiers.map { app.buttons[$0] }
        candidates.append(contentsOf: labels.map { app.buttons[$0] })
        candidates.append(contentsOf: labels.map { app.staticTexts[$0] })
        tapElement(firstExistingElement(candidates))
    }

    private func tapElement(
        _ element: XCUIElement,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), file: file, line: line)

        if element.isHittable {
            element.tap()
            return
        }

        let coordinate = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        coordinate.tap()
    }

    private func firstExistingElement(
        _ elements: [XCUIElement],
        timeout: TimeInterval = 5
    ) -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            for element in elements where element.exists {
                return element
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        for element in elements where element.exists {
            return element
        }

        XCTFail("None of the expected elements appeared: \(elements.map { $0.debugDescription }.joined(separator: ", "))")
        return elements[0]
    }

    private func matchingButton(in app: XCUIApplication, label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func matchingStaticText(in app: XCUIApplication, label: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func matchingOtherElement(in app: XCUIApplication, label: String) -> XCUIElement {
        app.otherElements.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func waitForButtonEnabled(_ button: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == true AND enabled == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: button)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}

private extension XCUIElement {
    func waitAndTap(timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(waitForExistence(timeout: timeout), file: file, line: line)
        tap()
    }
}
