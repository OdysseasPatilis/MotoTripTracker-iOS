import XCTest

final class MotoTripTrackerUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testHistoryOpensFromOptionsMenu() throws {
        let app = XCUIApplication()
        app.launch()

        let options = app.buttons["Options"]
        XCTAssertTrue(options.waitForExistence(timeout: 8), "Dashboard should appear after splash")
        options.tap()
        app.buttons["Ride History"].tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 4))
    }

    @MainActor
    func testDestinationSearchSheetOpens() throws {
        let app = XCUIApplication()
        app.launch()

        let setDestination = app.buttons["Set destination"]
        XCTAssertTrue(setDestination.waitForExistence(timeout: 8), "Dashboard should appear after splash")
        setDestination.tap()
        XCTAssertTrue(app.navigationBars["Set destination"].waitForExistence(timeout: 4))
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
